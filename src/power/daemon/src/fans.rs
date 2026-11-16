// ---------------------------------------------------------------- fans

use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant};

use crate::paths::FAN;
use crate::sysfs::{read_trim, say, Writer};

// The EC owns the fans unless told otherwise, and it takes them back on its own
// if this process stops refreshing the watchdog. That ordering is the whole
// safety argument: the failure mode of a dead governor is a machine on the
// EC's own curve, not one that cooks.
pub(crate) struct Fans {
    pub(crate) available: bool,
    pub(crate) level: String,
    pub(crate) last_watchdog: Instant,
}

impl Fans {
    pub(crate) fn new() -> Self {
        // fan_control=0 is the default, and without it every level write is
        // rejected. Saying so once at startup is better than a silent no-op
        // that looks like a curve nobody tuned right.
        let available = Path::new(FAN).exists()
            && read_trim("/sys/module/thinkpad_acpi/parameters/fan_control").as_deref()
                == Some("Y");
        Fans {
            available,
            level: String::new(),
            last_watchdog: Instant::now() - Duration::from_secs(3600),
        }
    }

    pub(crate) fn set(&mut self, w: &mut Writer, level: &str, watchdog_secs: u64) {
        if !self.available {
            return;
        }
        // Refresh first, then set. If the level write fails, the watchdog we
        // just armed is what ends up mattering.
        let mut refreshed = false;
        if self.last_watchdog.elapsed() >= Duration::from_secs(watchdog_secs / 3 + 1)
            && w.write(FAN, &format!("watchdog {watchdog_secs}\n"))
        {
            self.last_watchdog = Instant::now();
            refreshed = true;
        }
        // Re-asserted on every refresh rather than only on change, because the
        // EC silently takes the fans back and our cache would never know: a
        // resume resets it, and so does the watchdog firing. A proc write every
        // ten seconds is cheaper than being wrong about it for an hour.
        if (self.level != level || refreshed) && w.write(FAN, &format!("level {level}\n")) {
            if self.level != level {
                say!("fan level {level}");
            }
            self.level = level.to_string();
        }
    }

    // The fans back to the EC: on the way out, and with no temperature to go by.
    pub(crate) fn release(&mut self, w: &mut Writer) {
        if !self.available || self.level == "auto" {
            return;
        }
        if w.write(FAN, "level auto\n") {
            say!("fan level auto (released to the EC)");
            self.level = "auto".to_string();
        }
    }
}

// A fan level as the EC takes it: 0, still, to 7, and full speed, past 7 and
// unregulated, as fast as the fans go.
pub(crate) const FULL: u8 = 8;

pub(crate) fn level_name(level: u8) -> String {
    if level >= FULL {
        "full-speed".to_string()
    } else {
        level.to_string()
    }
}

// Each level from the temperature it starts at. The EC's own curve stops at
// about 3,600-4,000 rpm with the package held at its 96 °C, short of what the
// fans can do (fact 51). Plugged in, there is no battery to spare: the fans
// are still at rest and reach full speed under any load that lasts.
pub(crate) const AC_CURVE: &[(f64, u8)] = &[
    (55.0, 1),
    (62.0, 2),
    (68.0, 3),
    (74.0, 4),
    (79.0, 5),
    (84.0, 7),
    (88.0, FULL),
];

// On battery, still to 70 °C: a warm chassis is cheaper than a spinning fan,
// which is most of a watt itself, and the tiers keep the package cooler.
pub(crate) const BATTERY_CURVE: &[(f64, u8)] =
    &[(70.0, 1), (78.0, 2), (84.0, 4), (88.0, 7), (92.0, FULL)];

fn curve_level(curve: &[(f64, u8)], temp: f64) -> u8 {
    curve
        .iter()
        .take_while(|(at, _)| temp >= *at)
        .last()
        .map_or(0, |(_, level)| *level)
}

// The curve, read from the heat the fans can move rather than from every spike.
// A burst takes the package to 90 °C for a second and the heatsink barely
// notices, so the curve reads an average of the last few seconds (the heatsink
// takes about that long to follow): the fans rise as heat builds, not at each
// spike. They come down a level at a time, 3 °C below where the level starts
// and 12 s later, so a build's pauses do not set them hunting. A package
// at its critical temperature for three polls is not a spike: full speed at
// once.
pub(crate) struct FanCurve {
    pub(crate) level: u8,
    average: Option<f64>,
    hot_polls: u32,
    lower_since: Option<Instant>,
}

impl FanCurve {
    const DOWN_AFTER: Duration = Duration::from_secs(12);
    const DOWN_MARGIN: f64 = 3.0;

    pub(crate) fn new() -> Self {
        FanCurve {
            level: 0,
            average: None,
            hot_polls: 0,
            lower_since: None,
        }
    }

    // A resume, or fans the EC has had: start from the heat there is now.
    pub(crate) fn forget(&mut self) {
        self.level = 0;
        self.average = None;
        self.hot_polls = 0;
        self.lower_since = None;
    }

    pub(crate) fn step(
        &mut self,
        curve: &[(f64, u8)],
        temp: f64,
        critical: f64,
        now: Instant,
    ) -> u8 {
        let average = self.average.map_or(temp, |a| a + (temp - a) * 0.2);
        self.average = Some(average);
        self.hot_polls = if temp >= critical {
            self.hot_polls + 1
        } else {
            0
        };
        if self.hot_polls >= 3 {
            self.level = FULL;
            self.lower_since = None;
            return FULL;
        }
        let want = curve_level(curve, average);
        if want >= self.level || curve_level(curve, average + Self::DOWN_MARGIN) >= self.level {
            self.level = self.level.max(want);
            self.lower_since = None;
            return self.level;
        }
        let since = *self.lower_since.get_or_insert(now);
        if now.duration_since(since) >= Self::DOWN_AFTER {
            // The curve's next level down, or still.
            self.level = curve
                .iter()
                .map(|(_, level)| *level)
                .filter(|level| *level < self.level)
                .max()
                .unwrap_or(0);
            self.lower_since = Some(now);
        }
        self.level
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A curve stepped once a second at each temperature in turn.
    fn heat(curve: &mut FanCurve, shape: &[(f64, u8)], temps: &[f64], from: Instant) -> Vec<u8> {
        temps
            .iter()
            .enumerate()
            .map(|(i, t)| curve.step(shape, *t, 92.0, from + Duration::from_secs(i as u64)))
            .collect()
    }

    #[test]
    fn a_second_long_spike_does_not_spin_the_fans() {
        let mut curve = FanCurve::new();
        let levels = heat(
            &mut curve,
            AC_CURVE,
            &[45.0, 45.0, 90.0, 45.0, 45.0],
            Instant::now(),
        );
        assert_eq!(levels, [0, 0, 0, 0, 0]);
    }

    #[test]
    fn plugged_in_a_load_that_lasts_reaches_full_speed() {
        let mut curve = FanCurve::new();
        // Under critical: the average climbs, in about 17 s to where full
        // speed starts. A package held at its 96 °C gets there in three.
        let temps: Vec<f64> = [45.0].into_iter().chain([89.0; 20]).collect();
        let levels = heat(&mut curve, AC_CURVE, &temps, Instant::now());
        assert_eq!(levels[1], 0);
        assert!(levels.windows(2).all(|w| w[1] >= w[0]), "{levels:?}");
        assert_eq!(*levels.last().unwrap(), FULL);
    }

    #[test]
    fn a_critical_package_for_three_polls_is_full_speed_at_once() {
        let mut curve = FanCurve::new();
        let levels = heat(
            &mut curve,
            BATTERY_CURVE,
            &[40.0, 95.0, 95.0, 95.0],
            Instant::now(),
        );
        assert_eq!(levels, [0, 0, 0, FULL]);
    }

    #[test]
    fn the_fans_come_down_a_level_at_a_time_once_cool_for_twelve_seconds() {
        let mut curve = FanCurve::new();
        let now = Instant::now();
        heat(&mut curve, AC_CURVE, &[95.0; 4], now);
        assert_eq!(curve.level, FULL);
        let levels = heat(
            &mut curve,
            AC_CURVE,
            &[40.0; 40],
            now + Duration::from_secs(4),
        );
        // The average takes a few seconds to fall past full's start, then 12 s
        // a step: 7, then 5.
        assert_eq!(levels[..10], [FULL; 10]);
        assert!(levels.contains(&7) && levels.contains(&5), "{levels:?}");
        assert_eq!(levels.iter().filter(|l| **l == 7).count(), 12);
    }

    #[test]
    fn near_a_level_s_start_the_fans_hold() {
        let mut curve = FanCurve::new();
        let now = Instant::now();
        heat(&mut curve, AC_CURVE, &[75.0; 30], now);
        assert_eq!(curve.level, 4);
        // 2 °C under where level 4 starts, for a minute: within the margin.
        let levels = heat(
            &mut curve,
            AC_CURVE,
            &[72.0; 60],
            now + Duration::from_secs(30),
        );
        assert!(levels.iter().all(|l| *l == 4), "{levels:?}");
    }
}
