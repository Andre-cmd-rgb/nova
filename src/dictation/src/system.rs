//! What the daemon asks of the computer: its cores, whether it runs on its
//! battery, memory running short, a sleep coming, and the CPU's clock held
//! up for a moment.

use std::cell::Cell;
use std::fs;
use std::io::Write;
use std::os::fd::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use nova_sd::{Bus, Slot, Value};

/// Cores, not threads: Parakeet is no faster on a core's second thread. Up
/// to 8, as a P1 Gen 4i hears no faster on 16 threads than on 6.
pub fn cores() -> usize {
    let mut siblings: Vec<String> = fs::read_dir("/sys/devices/system/cpu")
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            name.starts_with("cpu")
                && name[3..].chars().all(|c| c.is_ascii_digit())
                && name.len() > 3
        })
        .filter_map(|e| fs::read_to_string(e.path().join("topology/thread_siblings_list")).ok())
        .collect();
    siblings.sort();
    siblings.dedup();
    let allowed = std::thread::available_parallelism().map_or(1, |n| n.get());
    let cores = if siblings.is_empty() {
        allowed
    } else {
        siblings.len().min(allowed)
    };
    cores.clamp(1, 8)
}

/// Whether the computer runs on its battery: it has one, and no charger is in.
pub fn on_battery(supplies: &Path) -> bool {
    let read = |p: PathBuf| {
        fs::read_to_string(p)
            .map(|s| s.trim().to_owned())
            .unwrap_or_default()
    };
    let mut battery = false;
    for supply in fs::read_dir(supplies).into_iter().flatten().flatten() {
        let path = supply.path();
        match read(path.join("type")).as_str() {
            "Battery" => battery = true,
            "Mains" | "USB" if read(path.join("online")) == "1" => return false,
            _ => {}
        }
    }
    battery
}

/// The kernel's word that memory is running short: a stall of 150 ms in two
/// seconds, which poll() says as POLLPRI. None where the kernel will not
/// give one to a user (before Linux 6.5, or without PSI).
pub struct Pressure(fs::File);

impl Pressure {
    pub fn watch() -> Option<Pressure> {
        let mut file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open("/proc/pressure/memory")
            .ok()?;
        file.write_all(b"some 150000 2000000\0").ok()?;
        Some(Pressure(file))
    }

    pub fn fd(&self) -> RawFd {
        self.0.as_raw_fd()
    }
}

/// The system bus, for logind's word of a sleep and power-profiles-daemon's
/// hold.
pub struct System {
    pub bus: Bus,
    sleeping: Rc<Cell<bool>>,
    _sleep: Slot,
}

const PROFILES: &str = "org.freedesktop.UPower.PowerProfiles";
const PROFILES_PATH: &str = "/org/freedesktop/UPower/PowerProfiles";

impl System {
    /// The system bus, watched for a sleep.
    pub fn connect() -> Result<System, String> {
        System::on(Bus::system().map_err(|e| e.to_string())?)
    }

    /// <bus> as the system bus: a private one, for tests.
    pub fn on(bus: Bus) -> Result<System, String> {
        let sleeping = Rc::new(Cell::new(false));
        let heard = sleeping.clone();
        let sleep = bus
            .match_signal(
                Some("org.freedesktop.login1"),
                Some("/org/freedesktop/login1"),
                Some("org.freedesktop.login1.Manager"),
                Some("PrepareForSleep"),
                move |m| {
                    if let Some(going) = m
                        .args()
                        .ok()
                        .and_then(|a| a.first().and_then(Value::as_bool))
                    {
                        heard.set(heard.get() || going);
                    }
                },
            )
            .map_err(|e| e.to_string())?;
        Ok(System {
            bus,
            sleeping,
            _sleep: sleep,
        })
    }

    /// Whether logind said the computer is about to sleep, since this started.
    pub fn sleep_coming(&self) -> bool {
        self.sleeping.get()
    }

    /// Asks power-profiles-daemon to hold the performance profile, as
    /// `powerprofilesctl launch` did, but without its 0.3 s of Python: the
    /// hold's cookie, until `release`, or until this connection goes.
    pub fn hold_performance(&self) -> Option<u32> {
        let answer = self
            .bus
            .call_timeout(
                PROFILES,
                PROFILES_PATH,
                PROFILES,
                "HoldProfile",
                &[
                    Value::str("performance"),
                    Value::str("Dictation"),
                    Value::str("nova-dictation"),
                ],
                Some(Duration::from_millis(500)),
            )
            .ok()?;
        match answer.first() {
            Some(Value::Uint32(cookie)) => Some(*cookie),
            _ => None,
        }
    }

    pub fn release(&self, cookie: u32) {
        let _ = self.bus.call_timeout(
            PROFILES,
            PROFILES_PATH,
            PROFILES,
            "ReleaseProfile",
            &[Value::Uint32(cookie)],
            Some(Duration::from_millis(500)),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn supply(dir: &Path, name: &str, kind: &str, online: Option<&str>) {
        let path = dir.join(name);
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("type"), format!("{kind}\n")).unwrap();
        if let Some(online) = online {
            fs::write(path.join("online"), format!("{online}\n")).unwrap();
        }
    }

    #[test]
    fn on_battery_with_a_battery_and_no_charger_in() {
        let dir = nova_sd::testing::scratch("supplies");
        assert!(!on_battery(&dir), "a desktop has no battery");
        supply(&dir, "BAT0", "Battery", None);
        supply(&dir, "AC", "Mains", Some("0"));
        assert!(on_battery(&dir));
        supply(&dir, "ucsi-source-psy-USBC000:001", "USB", Some("1"));
        assert!(!on_battery(&dir), "a USB-C charger is a charger");
        supply(&dir, "ucsi-source-psy-USBC000:001", "USB", Some("0"));
        supply(&dir, "AC", "Mains", Some("1"));
        assert!(!on_battery(&dir));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn cores_are_one_to_eight() {
        let n = cores();
        assert!((1..=8).contains(&n));
    }

    // A power-profiles-daemon of the test's own, on a private bus: the hold
    // is asked for as powerprofilesctl asked for it, and given back.
    #[test]
    fn the_performance_profile_is_held_and_given_back() {
        let Some(private) = nova_sd::testing::PrivateBus::start() else {
            return;
        };
        let daemon = Bus::connect(&private.address).unwrap();
        daemon.request_name(PROFILES, 0).unwrap();
        let calls = Rc::new(std::cell::RefCell::new(Vec::new()));
        let seen = calls.clone();
        let _object = daemon
            .export(
                PROFILES_PATH,
                vec![nova_sd::Interface::new(PROFILES)
                    .method("HoldProfile", "sss", "u")
                    .method("ReleaseProfile", "u", "")],
                move |call: &nova_sd::Message, args: Vec<Value>| {
                    seen.borrow_mut()
                        .push((call.member().unwrap_or("").to_owned(), args));
                    Ok(if call.member() == Some("HoldProfile") {
                        vec![Value::Uint32(7)]
                    } else {
                        vec![]
                    })
                },
            )
            .unwrap();
        let address = private.address.clone();
        let client = std::thread::spawn(move || {
            let system = System::on(Bus::connect(&address).unwrap()).unwrap();
            let cookie = system.hold_performance();
            if let Some(cookie) = cookie {
                system.release(cookie);
            }
            cookie
        });
        while !client.is_finished() {
            let _ = daemon.wait(Some(Duration::from_millis(20)));
            let _ = daemon.dispatch();
        }
        assert_eq!(client.join().unwrap(), Some(7));
        let calls = calls.borrow();
        assert_eq!(calls[0].0, "HoldProfile");
        assert_eq!(
            calls[0].1,
            vec![
                Value::str("performance"),
                Value::str("Dictation"),
                Value::str("nova-dictation")
            ]
        );
        assert_eq!(
            calls[1],
            ("ReleaseProfile".to_owned(), vec![Value::Uint32(7)])
        );
    }
}
