// ---------------------------------------------------------------- firmware

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::modes::IGpu;
use crate::paths::{
    BASH_PCT_STATE, BASH_RAPL_STATE, FIRMWARE, PSTATE_MAX, PSTATE_NO_TURBO, RAPL, RAPL_MMIO,
};
use crate::sysfs::{read_trim, read_u64, say, Writer};

// What the registers held before this daemon existed, so AC can put back the
// real values rather than the last thing we happened to write. Captured once
// and kept in /run, because a restart with the caps already applied would
// otherwise record 12 W as "what the firmware wanted" and there would be no
// route back short of a reboot.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Firmware {
    pub(crate) pl1_uw: u64,
    pub(crate) pl1_window_us: u64,
    pub(crate) pl2_uw: u64,
    pub(crate) max_pct: u64,
    pub(crate) no_turbo: u64,
    pub(crate) gpu_max_mhz: u64,
    pub(crate) gpu_boost_mhz: u64,
}

impl Firmware {
    pub(crate) fn capture_or_load(igpu: Option<&IGpu>) -> Option<Firmware> {
        if let Some(text) = read_trim(FIRMWARE) {
            let v: Vec<u64> = text
                .split_whitespace()
                .filter_map(|f| f.parse().ok())
                .collect();
            if v.len() >= 4 {
                return Some(Firmware {
                    pl1_uw: v[0],
                    pl1_window_us: v[1],
                    pl2_uw: v[2],
                    max_pct: v[3],
                    no_turbo: v.get(4).copied().unwrap_or(0),
                    gpu_max_mhz: v.get(5).copied().unwrap_or(0),
                    gpu_boost_mhz: v.get(6).copied().unwrap_or(0),
                });
            }
        }
        // The bash half may already have capped these, and reading them now
        // would record its 30 W as what the firmware wanted — after which AC
        // "restores" to the cap and there is no way back short of a reboot.
        // It saves the real values on its way to battery, in exactly the same
        // /run files it uses to restore them, so those come first. Measured
        // the hard way: the first run of this daemon captured PL1 as 30 W on a
        // machine whose firmware value is 109 W.
        let handover = read_trim(BASH_RAPL_STATE).map(|t| {
            t.split_whitespace()
                .filter_map(|f| f.parse::<u64>().ok())
                .collect::<Vec<u64>>()
        });
        let (h_pl1, h_win, h_pl2) = match handover.as_deref() {
            Some([a, b, c, ..]) => (Some(*a), Some(*b), Some(*c)),
            Some([a, b]) => (Some(*a), Some(*b), None),
            _ => (None, None, None),
        };
        let h_pct = read_u64(BASH_PCT_STATE);
        if h_pl1.is_some() || h_pct.is_some() {
            say!("taking the firmware values from nova-power's own saved state");
        }
        let fw = Firmware {
            pl1_uw: h_pl1.or_else(|| read_u64(format!("{RAPL}/constraint_0_power_limit_uw")))?,
            pl1_window_us: h_win
                .or_else(|| read_u64(format!("{RAPL}/constraint_0_time_window_us")))
                .unwrap_or(28_000_000),
            pl2_uw: h_pl2
                .or_else(|| read_u64(format!("{RAPL}/constraint_1_power_limit_uw")))
                .unwrap_or(0),
            max_pct: h_pct.or_else(|| read_u64(PSTATE_MAX)).unwrap_or(100),
            // Never taken from the handover: the bash half has no turbo knob,
            // so whatever is live now is the firmware's own answer.
            no_turbo: read_u64(PSTATE_NO_TURBO).unwrap_or(0),
            gpu_max_mhz: igpu.and_then(|g| read_u64(&g.max)).unwrap_or(0),
            gpu_boost_mhz: igpu.and_then(|g| read_u64(&g.boost)).unwrap_or(0),
        };
        let _ = fs::write(
            FIRMWARE,
            format!(
                "{} {} {} {} {} {} {}\n",
                fw.pl1_uw,
                fw.pl1_window_us,
                fw.pl2_uw,
                fw.max_pct,
                fw.no_turbo,
                fw.gpu_max_mhz,
                fw.gpu_boost_mhz
            ),
        );
        Some(fw)
    }
}

// ---------------------------------------------------------------- the second copy

// On AC this machine's firmware lowers the MMIO copy of PL1 to 30 W after
// about a minute of heavy load, and keeps it there for minutes after the load
// has gone, whatever the MSR copy says. Measured on 2026-11-03, 16 threads on
// AC: 83 W falling to 47 W at the package's 96 °C, then 28 W and 2.7 GHz once
// the copy dropped. The package still guards itself at its TCC temperature,
// so on AC the copy is held at the AC PL1, the firmware's own boot value
// here. On battery the MSR tiers sit below it, and it is left alone; at a stop
// there is nothing to put back, as what it holds is the firmware's number.
pub(crate) struct MmioPl1 {
    path: PathBuf,
    raised: u32,
    said_at: Option<Instant>,
}

impl MmioPl1 {
    pub(crate) fn find() -> Option<MmioPl1> {
        let path = Path::new(RAPL_MMIO).join("constraint_0_power_limit_uw");
        path.exists().then_some(MmioPl1 {
            path,
            raised: 0,
            said_at: None,
        })
    }

    // Read once a poll, written only when lowered. A line the first time and
    // then at most every ten minutes, with the count, so a long build that
    // the firmware keeps lowering does not fill the journal.
    pub(crate) fn hold(&mut self, w: &mut Writer, pl1_uw: u64, now: Instant) {
        let found = read_u64(&self.path);
        if !lowered(found, pl1_uw) || !w.write(&self.path, &pl1_uw.to_string()) {
            return;
        }
        self.raised += 1;
        if self
            .said_at
            .is_none_or(|t| now.duration_since(t) >= Duration::from_secs(600))
        {
            say!(
                "ac: the firmware lowered the MMIO PL1 to {} W; back to {} W ({} since the last line)",
                found.unwrap_or(0) / 1_000_000,
                pl1_uw / 1_000_000,
                self.raised
            );
            self.said_at = Some(now);
            self.raised = 0;
        }
    }
}

// A copy below the firmware's PL1. One the firmware raised above it is left
// as it is, and one that cannot be read is no reason to write.
fn lowered(found: Option<u64>, pl1_uw: u64) -> bool {
    found.is_some_and(|uw| uw < pl1_uw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_copy_below_the_firmware_pl1_is_raised() {
        assert!(lowered(Some(30_000_000), 109_000_000));
        assert!(!lowered(Some(109_000_000), 109_000_000));
        assert!(!lowered(Some(120_000_000), 109_000_000));
        assert!(!lowered(None, 109_000_000));
    }
}
