// ---------------------------------------------------------------- governor

use std::io::Write;
use std::time::Instant;

use crate::config::Config;
use crate::firmware::Firmware;
use crate::modes::{IGpu, Saving};
use crate::paths::{PSTATE_MAX, PSTATE_MIN, PSTATE_NO_TURBO, RAPL};
use crate::sysfs::{read_u64, say, Writer};

// PL1 is an average over this window. Plugged in, the PL1 it averages to is
// never reached for long (the package's heat comes first), so this is only
// Intel's own figure for the part.
const AC_WINDOW_US: u64 = 28_000_000;

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum Mode {
    Ac,
    Battery(usize),
}

pub(crate) struct Governor {
    pub(crate) cfg: Config,
    mode: Mode,
    // How long the load has been above climb / below fall. Only one of these
    // is ever running: they are two views of the same continuous stretch.
    pub(crate) above_since: Option<Instant>,
    pub(crate) below_since: Option<Instant>,
    pub(crate) applied: Option<(u64, u64, u64, bool)>,
    throttled: bool,
    // The battery's mode at the last step on battery, so a change of mode is
    // seen as one.
    saving: Option<Saving>,
}

impl Governor {
    pub(crate) fn new(cfg: Config) -> Self {
        Governor {
            cfg,
            mode: Mode::Ac,
            above_since: None,
            below_since: None,
            applied: None,
            throttled: false,
            saving: None,
        }
    }

    // The state machine, and the reason this is a daemon rather than a udev
    // rule. A spike does not climb: it has to hold above the threshold for
    // climb_after, which is longer than any interaction. Falling takes longer
    // still, so the gaps between files in a build do not cost a re-ramp.
    pub(crate) fn step(
        &mut self,
        ac: bool,
        saving: Saving,
        boost: bool,
        busy: f64,
        temp: Option<f64>,
        now: Instant,
    ) -> Mode {
        if ac {
            self.above_since = None;
            self.below_since = None;
            return Mode::Ac;
        }
        // A boost is the user saying "I know what this is, leave it alone".
        // When it ends, the ladder starts again at the mode's floor, as after
        // an unplug: kept, its turbo was clamped into balanced's and
        // performance's range and stayed for as long as the load sat between
        // busy_fall and busy_climb.
        if boost {
            self.above_since = None;
            self.below_since = None;
            self.saving = None;
            return Mode::Battery(self.cfg.tiers.len() - 1);
        }
        let (floor, top) = saving.range(self.cfg.tiers.len() - 1);
        let mut tier = match self.mode {
            Mode::Battery(t) if self.saving == Some(saving) => t.clamp(floor, top),
            // Coming off AC always starts at the mode's bottom. Anything else
            // would hand a full tier to whatever happened to be running at
            // unplug.
            //
            // So does a change of mode. Plugged in the profile is always
            // performance, so at an unplug, and at a boot on battery while
            // power-profiles-daemon still has the profile it saved plugged in,
            // the first reading is performance, whose floor is mid, until the
            // shell puts the battery's mode back a second or two later.
            // Clamping mid into the new mode's range kept it there for as long
            // as the load stayed above busy_fall (fact 52).
            Mode::Battery(_) | Mode::Ac => {
                self.above_since = None;
                self.below_since = None;
                floor
            }
        };
        self.saving = Some(saving);

        if busy >= self.cfg.busy_climb {
            self.below_since = None;
            let since = *self.above_since.get_or_insert(now);
            // Each rung costs more than the one below it, so "prolonged" means
            // something: 8 s to leave light, 16 s more to reach full, 24 s more
            // to reach turbo — about a minute of unbroken load for the top,
            // which nothing but real work will ever produce.
            let dwell = saving.climb_after(self.cfg.climb_after) * (tier as u32 + 1);
            if now.duration_since(since) >= dwell && tier < top {
                tier += 1;
                self.above_since = Some(now);
                say!(
                    "climbing to {} after {}s of load",
                    self.cfg.tiers[tier].name,
                    dwell.as_secs()
                );
            }
        } else if busy <= self.cfg.busy_fall {
            self.above_since = None;
            let since = *self.below_since.get_or_insert(now);
            if now.duration_since(since) >= self.cfg.fall_after && tier > floor {
                tier -= 1;
                self.below_since = Some(now);
            }
        } else {
            // Between the two thresholds nothing moves. That band is what
            // stops a load hovering near the line from oscillating tiers.
            self.above_since = None;
            self.below_since = None;
        }

        // Temperature outranks load, and the mode's floor. A tier that cannot
        // be cooled is not a tier that was earned, whatever the CPU is busy
        // doing.
        if let Some(t) = temp {
            if t >= self.cfg.temp_throttle && tier > 0 {
                if !self.throttled {
                    say!("package at {t:.0} C — stepping down from tier {tier}");
                }
                self.throttled = true;
                tier -= 1;
                self.above_since = None;
            } else if t < self.cfg.temp_throttle - 5.0 {
                self.throttled = false;
            }
        }
        Mode::Battery(tier)
    }

    pub(crate) fn apply(&mut self, w: &mut Writer, mode: Mode, fw: Firmware, igpu: Option<&IGpu>) {
        let (pl1_uw, pl1_win, pl2_uw, max_pct, no_turbo, label) = match mode {
            // Plugged in: everything, turbo and the whole range, to the
            // limits that are Nova's for AC.
            Mode::Ac => (
                self.cfg.ac_pl1_w * 1_000_000,
                AC_WINDOW_US,
                self.cfg.ac_pl2_w * 1_000_000,
                100,
                false,
                "ac",
            ),
            Mode::Battery(t) => {
                let tier = self.cfg.tiers[t];
                // A short window is half the knob: PL1 is an average, and the
                // firmware's 56 s here lets a burst most of a minute long
                // escape the cap entirely.
                (
                    tier.pl1_w * 1_000_000,
                    10_000_000,
                    tier.pl2_w * 1_000_000,
                    tier.max_pct,
                    tier.no_turbo,
                    tier.name,
                )
            }
        };
        let want = (pl1_uw, pl2_uw, max_pct, no_turbo);
        if self.applied == Some(want) && self.mode == mode {
            return;
        }
        w.write(
            format!("{RAPL}/constraint_0_power_limit_uw"),
            &pl1_uw.to_string(),
        );
        w.write(
            format!("{RAPL}/constraint_0_time_window_us"),
            &pl1_win.to_string(),
        );
        if pl2_uw > 0 {
            w.write(
                format!("{RAPL}/constraint_1_power_limit_uw"),
                &pl2_uw.to_string(),
            );
        }
        // max_perf_pct below min_perf_pct is rejected outright by the driver,
        // so a low tier on a machine with a high floor would silently do
        // nothing at all.
        let floor = read_u64(PSTATE_MIN).unwrap_or(0);
        // Turbo off before the ceiling comes down and back on after it goes up,
        // so there is never a moment where the driver is allowed a P-state the
        // tier we are leaving did not permit.
        if no_turbo {
            w.write(PSTATE_NO_TURBO, "1");
        }
        w.write(PSTATE_MAX, &max_pct.max(floor).to_string());
        if !no_turbo {
            w.write(PSTATE_NO_TURBO, "0");
        }

        // The iGPU spends out of the same package budget, and waitboost will
        // take it to RP0 for a stalled buffer unless the boost target says
        // otherwise. 0 means "leave it to the driver", which is what the top
        // two tiers and AC do.
        if let Some(g) = igpu {
            let want = match mode {
                Mode::Ac => fw.gpu_max_mhz,
                Mode::Battery(t) => {
                    let m = self.cfg.tiers[t].gpu_mhz;
                    if m == 0 {
                        fw.gpu_max_mhz
                    } else {
                        m
                    }
                }
            };
            if want > 0 {
                g.set(w, want);
            }
            // The boost target is the one that actually causes the spikes, so
            // on AC it goes back to whatever it was rather than to the ceiling.
            if matches!(mode, Mode::Ac) && fw.gpu_boost_mhz > 0 {
                w.write(&g.boost, &fw.gpu_boost_mhz.to_string());
            }
        }

        say!(
            "{label}: PL1 {} W over {} s, PL2 {} W, ceiling {}%{}",
            pl1_uw / 1_000_000,
            pl1_win / 1_000_000,
            pl2_uw / 1_000_000,
            max_pct,
            if no_turbo { ", turbo off" } else { "" }
        );
        self.applied = Some(want);
        self.mode = mode;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    // A governor stepped once a second for <secs> at <busy> percent, cool.
    fn run(gov: &mut Governor, saving: Saving, busy: f64, secs: u64, from: Instant) -> Mode {
        let mut mode = gov.mode;
        for i in 0..secs {
            mode = gov.step(
                false,
                saving,
                false,
                busy,
                Some(60.0),
                from + Duration::from_secs(i),
            );
            gov.mode = mode;
        }
        mode
    }

    #[test]
    fn saver_stays_light_under_any_load() {
        let mut gov = Governor::new(Config::default());
        assert_eq!(
            run(&mut gov, Saving::Saver, 100.0, 300, Instant::now()),
            Mode::Battery(0)
        );
    }

    #[test]
    fn balanced_climbs_the_whole_ladder_in_about_a_minute() {
        let mut gov = Governor::new(Config::default());
        let now = Instant::now();
        assert_eq!(
            run(&mut gov, Saving::Balanced, 100.0, 40, now),
            Mode::Battery(2)
        );
        assert_eq!(
            run(
                &mut gov,
                Saving::Balanced,
                100.0,
                40,
                now + Duration::from_secs(40)
            ),
            Mode::Battery(3)
        );
    }

    #[test]
    fn performance_starts_a_rung_up_and_climbs_four_times_as_fast() {
        let mut gov = Governor::new(Config::default());
        let now = Instant::now();
        assert_eq!(
            run(&mut gov, Saving::Performance, 0.0, 120, now),
            Mode::Battery(1)
        );
        // 4 s to full and 6 s more to turbo, against 16 and 24.
        assert_eq!(
            run(
                &mut gov,
                Saving::Performance,
                100.0,
                12,
                now + Duration::from_secs(120)
            ),
            Mode::Battery(3)
        );
    }

    // Fact 52: unplugged, the profile reads performance (the one kept plugged
    // in) until the shell puts the battery's back, and that must not leave
    // performance's floor behind.
    #[test]
    fn a_change_of_mode_starts_at_the_new_mode_s_floor() {
        let mut gov = Governor::new(Config::default());
        let now = Instant::now();
        assert_eq!(
            run(&mut gov, Saving::Performance, 40.0, 2, now),
            Mode::Battery(1)
        );
        // A load between busy_fall and busy_climb moves nothing: clamped, mid
        // would have stayed for as long as it lasted.
        assert_eq!(
            run(
                &mut gov,
                Saving::Balanced,
                40.0,
                600,
                now + Duration::from_secs(2)
            ),
            Mode::Battery(0)
        );
        assert_eq!(
            run(
                &mut gov,
                Saving::Performance,
                40.0,
                1,
                now + Duration::from_secs(602)
            ),
            Mode::Battery(1)
        );
        assert_eq!(
            run(
                &mut gov,
                Saving::Saver,
                40.0,
                1,
                now + Duration::from_secs(603)
            ),
            Mode::Battery(0)
        );
    }

    #[test]
    fn a_boost_and_ac_outrank_the_mode() {
        let mut gov = Governor::new(Config::default());
        let now = Instant::now();
        assert_eq!(
            gov.step(false, Saving::Saver, true, 0.0, Some(50.0), now),
            Mode::Battery(3)
        );
        assert_eq!(
            gov.step(true, Saving::Saver, false, 0.0, Some(50.0), now),
            Mode::Ac
        );
    }

    #[test]
    fn the_end_of_a_boost_starts_at_the_mode_s_floor() {
        let mut gov = Governor::new(Config::default());
        let now = Instant::now();
        assert_eq!(
            run(&mut gov, Saving::Balanced, 40.0, 2, now),
            Mode::Battery(0)
        );
        assert_eq!(
            gov.step(
                false,
                Saving::Balanced,
                true,
                40.0,
                Some(50.0),
                now + Duration::from_secs(2)
            ),
            Mode::Battery(3)
        );
        // The load between busy_fall and busy_climb moves nothing either way.
        assert_eq!(
            run(
                &mut gov,
                Saving::Balanced,
                40.0,
                600,
                now + Duration::from_secs(3)
            ),
            Mode::Battery(0)
        );
    }
}
