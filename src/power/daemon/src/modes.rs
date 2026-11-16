// ---------------------------------------------------------------- modes

use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::paths::BOOST;
use crate::sysfs::{read_trim, read_u64, Writer};

// The battery's three modes, as power-profiles-daemon sets them from the menu
// and Settings: the platform profile it writes, or, without one, the CPU's
// energy preference. Plugged in there is one mode, full power, and
// nova-power-profile keeps the profile on performance there.
const PLATFORM_PROFILE: &str = "/sys/firmware/acpi/platform_profile";
const EPP: &str = "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference";

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum Saving {
    Saver,
    Balanced,
    Performance,
}

impl Saving {
    pub(crate) fn read() -> Saving {
        Saving::from_profile(
            read_trim(PLATFORM_PROFILE)
                .or_else(|| read_trim(EPP))
                .as_deref(),
        )
    }

    fn from_profile(profile: Option<&str>) -> Saving {
        match profile {
            Some("low-power" | "quiet" | "cool" | "power") => Saving::Saver,
            Some("performance") => Saving::Performance,
            _ => Saving::Balanced,
        }
    }

    // The tiers the mode climbs between, of tiers 0 to top. Saver stays on the
    // lightest: battery first, and a boost for the job that needs more.
    // Performance starts a rung up and never drops below it.
    pub(crate) fn range(self, top: usize) -> (usize, usize) {
        match self {
            Saving::Saver => (0, 0),
            Saving::Balanced => (0, top),
            Saving::Performance => (1.min(top), top),
        }
    }

    // How long the first rung's load has to last; each rung after takes as
    // long again. Performance believes a load four times as soon.
    pub(crate) fn climb_after(self, base: Duration) -> Duration {
        match self {
            Saving::Performance => base / 4,
            _ => base,
        }
    }
}

// The integrated card's frequency knobs. cardN numbering is not stable across
// boots — the same reason the compositor is pinned through a udev symlink
// rather than a path — so the card is found by driver, not by number.
pub(crate) struct IGpu {
    pub(crate) max: PathBuf,
    pub(crate) boost: PathBuf,
    pub(crate) min_mhz: u64,
    pub(crate) hw_max_mhz: u64,
}

impl IGpu {
    pub(crate) fn find() -> Option<IGpu> {
        let dir = fs::read_dir("/sys/class/drm").ok()?;
        for e in dir.flatten() {
            let p = e.path();
            let name = p.file_name()?.to_string_lossy().to_string();
            // "card1", not "card1-eDP-1".
            if !name.starts_with("card") || name.contains('-') {
                continue;
            }
            let Ok(driver) = fs::read_link(p.join("device/driver")) else {
                continue;
            };
            let Some(driver) = driver.file_name() else {
                continue;
            };
            let driver = driver.to_string_lossy().to_string();
            if driver != "i915" && driver != "xe" {
                continue;
            }
            let max = p.join("gt_max_freq_mhz");
            if !max.exists() {
                continue;
            }
            return Some(IGpu {
                boost: p.join("gt_boost_freq_mhz"),
                min_mhz: read_u64(p.join("gt_RPn_freq_mhz")).unwrap_or(0),
                hw_max_mhz: read_u64(p.join("gt_RP0_freq_mhz")).unwrap_or(0),
                max,
            });
        }
        None
    }

    // Order matters when raising: the boost target cannot exceed the ceiling,
    // so the ceiling goes up first and comes down last.
    pub(crate) fn set(&self, w: &mut Writer, mhz: u64) {
        // Never below the hardware's floor. (A clamp to RP0 here panicked
        // when RP0 could not be read and a tier asked for less than RPn.)
        let want = mhz.max(self.min_mhz);
        let current = read_u64(&self.max).unwrap_or(0);
        if want >= current {
            w.write(&self.max, &want.to_string());
            w.write(&self.boost, &want.to_string());
        } else {
            w.write(&self.boost, &want.to_string());
            w.write(&self.max, &want.to_string());
        }
    }
}

// Whether a charger is in. Reading `online` asks the EC, two of its
// interrupts each time (fact 56), so it is not read every poll: the udev rule
// touches MAINS_MARKER at each plug and unplug, whose time is free to look at
// on tmpfs, and the charger is read when that moves, after a resume, and at
// least every MAINS_FALLBACK for an event that never came. A file rather than
// a signal: it needs no D-Bus call from a udev worker, nothing fails while
// the daemon is stopped, and a daemon started after an event still sees it.
// The supplies that are chargers are looked for again every minute, for one
// that appears later, and whenever there is none.
const MAINS_MARKER: &str = "/run/nova-powerd.mains";
const MAINS_FALLBACK: Duration = Duration::from_secs(30);

fn mains_due(since_read: Option<Duration>, marker_moved: bool) -> bool {
    marker_moved || since_read.is_none_or(|d| d >= MAINS_FALLBACK)
}

pub(crate) struct Mains {
    online: Vec<PathBuf>,
    found_at: Instant,
    ac: bool,
    read_at: Option<Instant>,
    marker_path: PathBuf,
    marker: Option<std::time::SystemTime>,
}

impl Mains {
    pub(crate) fn new() -> Self {
        Mains {
            online: Self::find(),
            found_at: Instant::now(),
            ac: true,
            read_at: None,
            marker_path: PathBuf::from(MAINS_MARKER),
            marker: None,
        }
    }

    // A resume: the charger may have come or gone while asleep.
    pub(crate) fn forget(&mut self) {
        self.read_at = None;
    }

    fn find() -> Vec<PathBuf> {
        let Ok(dir) = fs::read_dir("/sys/class/power_supply") else {
            return Vec::new();
        };
        dir.flatten()
            .map(|e| e.path())
            .filter(|p| read_trim(p.join("type")).as_deref() == Some("Mains"))
            .map(|p| p.join("online"))
            .collect()
    }

    pub(crate) fn on_ac(&mut self, now: Instant) -> bool {
        let marker = fs::metadata(&self.marker_path)
            .and_then(|m| m.modified())
            .ok();
        let moved = marker != self.marker;
        self.marker = marker;
        if !mains_due(self.read_at.map(|t| now.duration_since(t)), moved) {
            return self.ac;
        }
        if self.online.is_empty() || now.duration_since(self.found_at) >= Duration::from_secs(60) {
            self.online = Self::find();
            self.found_at = now;
        }
        self.read_at = Some(now);
        // No charger to ask is a desktop, and a desktop is on AC.
        self.ac = self.online.is_empty()
            || self
                .online
                .iter()
                .any(|p| read_trim(p).as_deref() == Some("1"));
        self.ac
    }
}

/// A boost is on while its marker is there, until the time it holds: its
/// expiry timer may run a moment late after a sleep, and nothing past that time
/// is a boost any more.
pub(crate) fn boosting() -> bool {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    fs::read_to_string(BOOST).is_ok_and(|text| boost_live(&text, now))
}

fn boost_live(marker: &str, now: u64) -> bool {
    marker
        .trim()
        .parse::<u64>()
        .map_or(true, |until| now < until)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::scratch;

    #[test]
    fn a_boost_ends_at_its_time_though_its_marker_is_still_there() {
        assert!(boost_live("1000\n", 999));
        assert!(!boost_live("1000\n", 1000));
        // A marker without a time, as an older nova-power wrote one, is a boost until it goes.
        assert!(boost_live("", u64::MAX));
    }

    #[test]
    fn the_profile_names_the_battery_mode() {
        assert_eq!(Saving::from_profile(Some("low-power")), Saving::Saver);
        assert_eq!(Saving::from_profile(Some("power")), Saving::Saver);
        assert_eq!(Saving::from_profile(Some("balanced")), Saving::Balanced);
        assert_eq!(
            Saving::from_profile(Some("balance_power")),
            Saving::Balanced
        );
        assert_eq!(
            Saving::from_profile(Some("performance")),
            Saving::Performance
        );
        assert_eq!(Saving::from_profile(None), Saving::Balanced);
    }

    #[test]
    fn the_charger_is_read_when_the_marker_moves_and_at_least_every_half_minute() {
        assert!(mains_due(None, false));
        assert!(!mains_due(Some(Duration::from_secs(5)), false));
        assert!(mains_due(Some(Duration::from_secs(5)), true));
        assert!(mains_due(Some(MAINS_FALLBACK), false));
    }

    #[test]
    fn a_plug_event_is_seen_at_the_next_poll() {
        let dir = scratch("mains");
        let online = dir.join("online");
        let marker = dir.join("mains");
        fs::write(&online, "1\n").unwrap();
        let mut mains = Mains {
            online: vec![online.clone()],
            found_at: Instant::now(),
            ac: true,
            read_at: None,
            marker_path: marker.clone(),
            marker: None,
        };
        let now = Instant::now();
        let touch = |secs: u64| {
            fs::File::create(&marker)
                .unwrap()
                .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(secs))
                .unwrap();
        };
        assert!(mains.on_ac(now));
        // Unplugged with no event: the reading stands until the fallback.
        fs::write(&online, "0\n").unwrap();
        assert!(mains.on_ac(now + Duration::from_secs(1)));
        assert!(!mains.on_ac(now + Duration::from_secs(31)));
        // Plugged in, and the udev rule touches the marker.
        fs::write(&online, "1\n").unwrap();
        touch(1000);
        assert!(mains.on_ac(now + Duration::from_secs(32)));
        fs::write(&online, "0\n").unwrap();
        touch(1001);
        assert!(!mains.on_ac(now + Duration::from_secs(33)));
        // Unmoved, it is not read again.
        fs::write(&online, "1\n").unwrap();
        assert!(!mains.on_ac(now + Duration::from_secs(34)));
        // A resume reads it at once.
        mains.forget();
        assert!(mains.on_ac(now + Duration::from_secs(35)));
        let _ = fs::remove_dir_all(dir);
    }
}
