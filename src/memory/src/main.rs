//! nova-memory-pressure: the kernel's memory reserve is the full one while
//! memory is short, and the lean one at rest.
//!
//! nova-memory-reserve sizes vm.watermark_scale_factor at boot so that a big
//! machine keeps 100 MiB between its min and low watermarks and not 1.25% of
//! itself: at rest the larger gap is a gigabyte and more that nothing may use,
//! shown as memory in use. Under pressure the larger gap earns its keep: with
//! a 32 GB machine's zones, eight CPUs and bursts asked for by eight
//! processes at once, the 1.25% gap had a frame's lateness at 3.6 ms at the
//! 99th percentile where 100 MiB had 7.2, and 2228 direct-reclaim stalls
//! where it had 3073 (docs/ARCHITECTURE.md, Memory).
//!
//! The reserve is only ever used while the kernel is reclaiming, and the
//! kernel says when it is: a trigger on /proc/pressure/memory wakes this
//! program in any second in which tasks stood stalled on memory for a tenth
//! of it (Documentation/accounting/psi.rst). It then writes the full 1.25%,
//! and puts the boot's value back once five minutes have passed without such
//! a second. Asleep on that one descriptor otherwise: no timer, no polling.
//! In the same test, started lean with this running, the minute that takes
//! in the raising itself came to 4.4 ms and 2812 stalls; after it the
//! setting is the full one.
//!
//! It leaves the setting alone, and ends, where there is nothing to do: on a
//! computer whose boot value is the full one already (8 GB and less), and
//! where the value in force is not the one nova-memory-reserve wrote, which
//! means an administrator set their own.
//!
//! NOVA_PROC and NOVA_RUN point it at a fixture for the tests.

use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::process;
use std::time::{Duration, Instant};

/// 1.25%: Nova's share on a small machine, and everyone's under pressure.
const FULL: u32 = 125;
/// Tasks stalled on memory for 100 ms of a second.
const TRIGGER: &[u8] = b"some 100000 1000000\0";
/// How long after the last such second the full reserve stays.
const HOLD: Duration = Duration::from_secs(300);

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

const POLLPRI: i16 = 0x002;
const POLLERR: i16 = 0x008;

extern "C" {
    fn poll(fds: *mut PollFd, count: u64, timeout: i32) -> i32;
}

/// What is in force, and what the next wake does to it.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Reserve {
    Lean,
    Full { until: Instant },
}

#[derive(Debug, PartialEq)]
enum Wake {
    /// A second with memory short.
    Pressure,
    /// The wait ran out with none.
    Quiet,
}

/// The factor to write, if any, and the state after a wake.
fn step(reserve: Reserve, wake: Wake, now: Instant, lean: u32) -> (Reserve, Option<u32>) {
    match (reserve, wake) {
        (Reserve::Lean, Wake::Pressure) => (Reserve::Full { until: now + HOLD }, Some(FULL)),
        (Reserve::Full { .. }, Wake::Pressure) => (Reserve::Full { until: now + HOLD }, None),
        (Reserve::Full { until }, Wake::Quiet) if now >= until => (Reserve::Lean, Some(lean)),
        (state, Wake::Quiet) => (state, None),
    }
}

/// The boot's factor if it is Nova's to manage: the one nova-memory-reserve
/// wrote, in force, and under the full one. None otherwise.
fn lean_factor(in_force: &str, written: &str) -> Option<u32> {
    let in_force = in_force.trim().parse::<u32>().ok()?;
    let written = written
        .lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .find_map(|line| line.split_once('=').filter(|(key, _)| key.trim() == "vm.watermark_scale_factor"))
        .and_then(|(_, value)| value.trim().parse::<u32>().ok())?;
    (in_force == written && in_force < FULL).then_some(in_force)
}

fn say(message: &str) {
    eprintln!("nova-memory-pressure: {message}");
}

fn set(setting: &PathBuf, factor: u32) -> io::Result<()> {
    fs::write(setting, format!("{factor}\n"))
}

fn main() {
    let proc_root = PathBuf::from(env::var_os("NOVA_PROC").unwrap_or_else(|| "/proc".into()));
    let run_root = PathBuf::from(env::var_os("NOVA_RUN").unwrap_or_else(|| "/run".into()));
    let setting = proc_root.join("sys/vm/watermark_scale_factor");
    let in_force = fs::read_to_string(&setting).unwrap_or_default();
    let written = fs::read_to_string(run_root.join("sysctl.d/90-nova-memory-reserve.conf")).unwrap_or_default();
    let Some(lean) = lean_factor(&in_force, &written) else {
        // The full reserve already, or somebody's own setting: nothing to do.
        return;
    };

    let pressure: File = match OpenOptions::new().read(true).write(true).open(proc_root.join("pressure/memory")) {
        Ok(file) => file,
        Err(error) => {
            say(&format!("no memory pressure to wait on ({error}); the reserve stays at {lean}"));
            return;
        }
    };
    if let Err(error) = (&pressure).write_all(TRIGGER) {
        say(&format!("the kernel took no trigger ({error}); the reserve stays at {lean}"));
        return;
    }

    let mut reserve = Reserve::Lean;
    loop {
        let timeout = match reserve {
            Reserve::Lean => -1,
            Reserve::Full { until } => until.saturating_duration_since(Instant::now()).as_millis().min(i32::MAX as u128) as i32 + 1,
        };
        let mut fd = PollFd { fd: pressure.as_raw_fd(), events: POLLPRI, revents: 0 };
        let ready = unsafe { poll(&mut fd, 1, timeout) };
        if ready < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            say("could not wait on the memory pressure");
            process::exit(1);
        }
        if fd.revents & POLLERR != 0 {
            say("the kernel's memory pressure is gone");
            process::exit(1);
        }
        let wake = if ready > 0 && fd.revents & POLLPRI != 0 { Wake::Pressure } else { Wake::Quiet };
        let (next, write) = step(reserve, wake, Instant::now(), lean);
        if let Some(factor) = write {
            match set(&setting, factor) {
                Ok(()) if factor == FULL => say(&format!("memory is short: the full reserve ({FULL})")),
                Ok(()) => say(&format!("five minutes without pressure: the reserve is {factor} again")),
                Err(error) => say(&format!("could not set the reserve to {factor}: {error}")),
            }
        }
        reserve = next;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_boot_value_is_managed_only_when_it_is_novas_and_lean() {
        let written = "# Written at boot by /usr/lib/nova/nova-memory-reserve for 31792 MiB of memory:\n# background reclaim starts 98 MiB before a program would stall.\nvm.watermark_scale_factor = 31\n";
        assert_eq!(lean_factor("31\n", written), Some(31));
        // An administrator's own value in /etc/sysctl.d won over the file.
        assert_eq!(lean_factor("200\n", written), None);
        assert_eq!(lean_factor("10\n", written), None);
        // 8 GB and less: the boot value is the full one.
        assert_eq!(lean_factor("125\n", "vm.watermark_scale_factor = 125\n"), None);
        // No file (the helper did not run), or not a number.
        assert_eq!(lean_factor("31\n", ""), None);
        assert_eq!(lean_factor("", written), None);
        assert_eq!(lean_factor("31\n", "vm.swappiness = 31\n"), None);
    }

    #[test]
    fn pressure_brings_the_full_reserve_and_five_quiet_minutes_take_it_back() {
        let start = Instant::now();
        // At rest nothing is written, however long.
        assert_eq!(step(Reserve::Lean, Wake::Quiet, start, 31), (Reserve::Lean, None));
        // The first second of pressure: the full reserve, once.
        let (full, write) = step(Reserve::Lean, Wake::Pressure, start, 31);
        assert_eq!((full, write), (Reserve::Full { until: start + HOLD }, Some(FULL)));
        // More pressure moves the five minutes on, and writes nothing.
        let later = start + Duration::from_secs(200);
        let (full, write) = step(full, Wake::Pressure, later, 31);
        assert_eq!((full, write), (Reserve::Full { until: later + HOLD }, None));
        // A wake before the five minutes are up changes nothing.
        let early = later + Duration::from_secs(299);
        assert_eq!(step(full, Wake::Quiet, early, 31), (full, None));
        // When they are, the boot's value is back.
        let done = later + HOLD;
        assert_eq!(step(full, Wake::Quiet, done, 31), (Reserve::Lean, Some(31)));
    }

    #[test]
    fn the_trigger_is_a_tenth_of_a_second_in_one() {
        assert_eq!(TRIGGER, b"some 100000 1000000\0");
    }
}
