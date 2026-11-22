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
//! The three in one sitting, turn and turn about (medians of three): the
//! full gap 2.5 ms and 2381 stalls, the fixed 100 MiB 5.0 ms and 3232, and
//! 100 MiB with this running 3.6 ms and 2565, the seconds before the raise
//! included. In seven such runs the factor read 125 between 0.05 and 0.42 s
//! after the first program stalled in direct reclaim.
//!
//! It leaves the setting alone, and ends, where there is nothing to do: on a
//! computer whose boot value is the full one already (8 GB and less, where
//! the unit does not start), and where the value in force is not the one
//! nova-memory-reserve wrote, which means an administrator set their own in
//! /etc/sysctl.d. Running, it does the same the first time it finds a value
//! that is neither the boot's nor its own raise (`sysctl -w`, a file applied
//! by hand): it says so once and ends, the value left as it is.
//!
//! What can go wrong, and what then holds:
//!
//! - It is not running (masked, failed, a kernel without pressure
//!   information): the reserve stays the lean one under pressure too, the
//!   fixed 100 MiB above, which is still ahead of the kernel's own default
//!   (9.2 ms and 4641 stalls beside the first sitting's 7.2 and 3073).
//! - It ends while the full reserve is in force: the full reserve stays,
//!   the safe side. systemd starts it again (Restart=on-failure), and it
//!   takes the setting up where it was: the mark it leaves in its runtime
//!   directory while its raise is in force, and only then, says the 125 is
//!   its own, not an administrator's.
//! - Something puts the boot's value back while memory is short (pacman's
//!   hook runs systemd-sysctl when a package brings a sysctl file): the
//!   value in force is read at every wake, and raised again with the next
//!   second of pressure.
//! - A value of somebody else's while it runs, above the full one or under
//!   it: never raised or lowered; it ends there, until the next boot.
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

/// What a wake leads to.
#[derive(Debug, PartialEq)]
enum Next {
    /// On, in this state, with the factor to write first, if any.
    On(Reserve, Option<u32>),
    /// The value in force is somebody else's: left as it is, and the end.
    Theirs(u32),
}

/// What a wake leads to, given the factor in force (None if it could not be
/// read). The setting is this program's while the value in force is the
/// boot's or, while it has raised it, the full one: any other is somebody
/// else's. Pressure raises the boot's value, also one something put back
/// meanwhile (systemd-sysctl run again by a package's hook); the quiet five
/// minutes take back only the full reserve this program set.
fn step(reserve: Reserve, wake: Wake, now: Instant, lean: u32, in_force: Option<u32>) -> Next {
    let raised = matches!(reserve, Reserve::Full { .. });
    match in_force {
        Some(factor) if factor != lean && !(raised && factor == FULL) => {
            return Next::Theirs(factor)
        }
        _ => {}
    }
    match (reserve, wake) {
        (_, Wake::Pressure) => Next::On(
            Reserve::Full { until: now + HOLD },
            in_force.is_none_or(|factor| factor < FULL).then_some(FULL),
        ),
        (Reserve::Full { until }, Wake::Quiet) if now >= until => {
            Next::On(Reserve::Lean, (in_force == Some(FULL)).then_some(lean))
        }
        (state, Wake::Quiet) => Next::On(state, None),
    }
}

/// Whether the mark is to be there once <next> is in force: only while the
/// full reserve this program set is, so that a start finds a 125 its own
/// only when it was (written before the raise, taken away before the
/// lowering and when the setting is somebody else's).
fn marked(next: &Next) -> bool {
    matches!(next, Next::On(Reserve::Full { .. }, _))
}

/// How long the next wait may last, in poll's milliseconds: none while the
/// reserve is the lean one, until a little after the full one's end
/// otherwise, never more than poll can take.
fn timeout(reserve: Reserve, now: Instant) -> i32 {
    match reserve {
        Reserve::Lean => -1,
        Reserve::Full { until } => {
            (until
                .saturating_duration_since(now)
                .as_millis()
                .min(i32::MAX as u128 - 1) as i32)
                + 1
        }
    }
}

/// What a start finds in force, where the setting is Nova's to manage.
#[derive(Debug, PartialEq)]
enum Found {
    /// The boot's lean value, the one nova-memory-reserve wrote.
    Lean(u32),
    /// The full one, set by an earlier run of this program since the boot
    /// (it ended while memory was short); the lean value it will go back to.
    Raised(u32),
}

/// None where there is nothing to manage: the boot's value is the full one
/// (8 GB and less), or the value in force is neither the boot's nor this
/// program's own raise, which makes it an administrator's.
fn found(in_force: &str, written: &str, managed_before: bool) -> Option<Found> {
    let in_force = in_force.trim().parse::<u32>().ok()?;
    let lean = written
        .lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .find_map(|line| {
            line.split_once('=')
                .filter(|(key, _)| key.trim() == "vm.watermark_scale_factor")
        })
        .and_then(|(_, value)| value.trim().parse::<u32>().ok())
        .filter(|lean| *lean < FULL)?;
    if in_force == lean {
        Some(Found::Lean(lean))
    } else if in_force == FULL && managed_before {
        Some(Found::Raised(lean))
    } else {
        None
    }
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
    let written = fs::read_to_string(run_root.join("sysctl.d/90-nova-memory-reserve.conf"))
        .unwrap_or_default();
    // There while a run's own raise is in force (the unit's
    // RuntimeDirectory, kept until the next boot).
    let mark = run_root.join("nova-memory-pressure/managed");
    let (lean, mut reserve) = match found(&in_force, &written, mark.exists()) {
        Some(Found::Lean(lean)) => {
            let _ = fs::remove_file(&mark);
            (lean, Reserve::Lean)
        }
        Some(Found::Raised(lean)) => {
            say(&format!("taken up again with the full reserve in force: {lean} after five minutes without pressure"));
            (
                lean,
                Reserve::Full {
                    until: Instant::now() + HOLD,
                },
            )
        }
        // The full reserve already, or somebody's own setting: nothing to do.
        None => return,
    };

    let pressure: File = match OpenOptions::new()
        .read(true)
        .write(true)
        .open(proc_root.join("pressure/memory"))
    {
        Ok(file) => file,
        Err(error) => {
            say(&format!(
                "no memory pressure to wait on ({error}); the reserve stays at {lean}"
            ));
            return;
        }
    };
    if let Err(error) = (&pressure).write_all(TRIGGER) {
        say(&format!(
            "the kernel took no trigger ({error}); the reserve stays at {lean}"
        ));
        return;
    }

    loop {
        let mut fd = PollFd {
            fd: pressure.as_raw_fd(),
            events: POLLPRI,
            revents: 0,
        };
        let ready = unsafe { poll(&mut fd, 1, timeout(reserve, Instant::now())) };
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
        let wake = if ready > 0 && fd.revents & POLLPRI != 0 {
            Wake::Pressure
        } else {
            Wake::Quiet
        };
        let in_force = fs::read_to_string(&setting)
            .ok()
            .and_then(|text| text.trim().parse::<u32>().ok());
        let next = step(reserve, wake, Instant::now(), lean, in_force);
        // Without the mark a later start finds a raise it cannot tell from
        // an administrator's 125, and leaves it: the full reserve until the
        // next boot, the safe side.
        if marked(&next) {
            if !mark.exists() {
                if let Some(dir) = mark.parent() {
                    let _ = fs::create_dir_all(dir);
                }
                if let Err(error) = fs::write(&mark, b"") {
                    say(&format!("no mark at {} ({error})", mark.display()));
                }
            }
        } else {
            let _ = fs::remove_file(&mark);
        }
        let (next, write) = match next {
            Next::On(next, write) => (next, write),
            Next::Theirs(factor) => {
                say(&format!("the reserve is {factor}, set by somebody else: left as it is, and no longer managed until the next boot"));
                return;
            }
        };
        if let Some(factor) = write {
            match set(&setting, factor) {
                Ok(()) if factor == FULL => {
                    say(&format!("memory is short: the full reserve ({FULL})"))
                }
                Ok(()) => say(&format!(
                    "five minutes without pressure: the reserve is {factor} again"
                )),
                Err(error) => say(&format!("could not set the reserve to {factor}: {error}")),
            }
        }
        reserve = next;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WRITTEN: &str = "# Written at boot by /usr/lib/nova/nova-memory-reserve for 31792 MiB of memory:\n# background reclaim starts 98 MiB before a program would stall.\nvm.watermark_scale_factor = 31\n";

    #[test]
    fn the_boot_value_is_managed_only_when_it_is_novas_and_lean() {
        assert_eq!(found("31\n", WRITTEN, false), Some(Found::Lean(31)));
        // An administrator's own value in /etc/sysctl.d won over the file.
        assert_eq!(found("200\n", WRITTEN, false), None);
        assert_eq!(found("10\n", WRITTEN, false), None);
        // Also when it is 125: nothing says this program raised it.
        assert_eq!(found("125\n", WRITTEN, false), None);
        // 8 GB and less: the boot value is the full one.
        assert_eq!(
            found("125\n", "vm.watermark_scale_factor = 125\n", false),
            None
        );
        assert_eq!(
            found("125\n", "vm.watermark_scale_factor = 125\n", true),
            None
        );
        // No file (the helper did not run), or not a number.
        assert_eq!(found("31\n", "", false), None);
        assert_eq!(found("", WRITTEN, false), None);
        assert_eq!(found("31\n", "vm.swappiness = 31\n", false), None);
    }

    #[test]
    fn a_start_after_its_own_raise_takes_the_setting_up_again() {
        // It ended while memory was short, and left its mark: the 125 is its own.
        assert_eq!(found("125\n", WRITTEN, true), Some(Found::Raised(31)));
        // Started again at rest: as the first time.
        assert_eq!(found("31\n", WRITTEN, true), Some(Found::Lean(31)));
        // A value set by hand since is nobody's raise.
        assert_eq!(found("200\n", WRITTEN, true), None);
    }

    #[test]
    fn pressure_brings_the_full_reserve_and_five_quiet_minutes_take_it_back() {
        let start = Instant::now();
        // At rest nothing is written, however long.
        assert_eq!(
            step(Reserve::Lean, Wake::Quiet, start, 31, Some(31)),
            Next::On(Reserve::Lean, None)
        );
        // The first second of pressure: the full reserve, once.
        let full = Reserve::Full {
            until: start + HOLD,
        };
        assert_eq!(
            step(Reserve::Lean, Wake::Pressure, start, 31, Some(31)),
            Next::On(full, Some(FULL))
        );
        // More pressure moves the five minutes on, and writes nothing.
        let later = start + Duration::from_secs(200);
        let full = Reserve::Full {
            until: later + HOLD,
        };
        assert_eq!(
            step(full, Wake::Pressure, later, 31, Some(FULL)),
            Next::On(full, None)
        );
        // A wake before the five minutes are up changes nothing.
        let early = later + Duration::from_secs(299);
        assert_eq!(
            step(full, Wake::Quiet, early, 31, Some(FULL)),
            Next::On(full, None)
        );
        // When they are, the boot's value is back.
        let done = later + HOLD;
        assert_eq!(
            step(full, Wake::Quiet, done, 31, Some(FULL)),
            Next::On(Reserve::Lean, Some(31))
        );
    }

    #[test]
    fn the_value_in_force_decides_what_is_written() {
        let start = Instant::now();
        let full = Reserve::Full {
            until: start + HOLD,
        };
        // The boot's value put back while memory is short (systemd-sysctl run
        // again by a package's hook): raised with the next second of pressure.
        assert_eq!(
            step(full, Wake::Pressure, start, 31, Some(31)),
            Next::On(full, Some(FULL))
        );
        // Unreadable: written, to be on the safe side.
        assert_eq!(
            step(Reserve::Lean, Wake::Pressure, start, 31, None),
            Next::On(full, Some(FULL))
        );
        // Nor is the boot's value written over one already there.
        assert_eq!(
            step(full, Wake::Quiet, start + HOLD, 31, Some(31)),
            Next::On(Reserve::Lean, None)
        );
    }

    #[test]
    fn a_value_set_by_somebody_else_while_it_runs_ends_the_managing() {
        let start = Instant::now();
        let full = Reserve::Full {
            until: start + HOLD,
        };
        // Under the full one: never raised, then put back to the boot's.
        assert_eq!(
            step(Reserve::Lean, Wake::Pressure, start, 31, Some(50)),
            Next::Theirs(50)
        );
        assert_eq!(
            step(full, Wake::Quiet, start + HOLD, 31, Some(50)),
            Next::Theirs(50)
        );
        // Above it: never lowered.
        assert_eq!(
            step(Reserve::Lean, Wake::Pressure, start, 31, Some(200)),
            Next::Theirs(200)
        );
        assert_eq!(
            step(full, Wake::Quiet, start + HOLD, 31, Some(200)),
            Next::Theirs(200)
        );
        // The full one itself, while it had not raised it: not its own, and
        // the boot's value is not put over it five minutes on.
        assert_eq!(
            step(Reserve::Lean, Wake::Pressure, start, 31, Some(FULL)),
            Next::Theirs(FULL)
        );
        assert_eq!(
            step(Reserve::Lean, Wake::Quiet, start, 31, Some(FULL)),
            Next::Theirs(FULL)
        );
    }

    #[test]
    fn the_mark_is_there_only_while_its_own_raise_is() {
        let start = Instant::now();
        let full = Reserve::Full {
            until: start + HOLD,
        };
        // Raised: marked, before the 125 is written.
        let raise = step(Reserve::Lean, Wake::Pressure, start, 31, Some(31));
        assert_eq!(raise, Next::On(full, Some(FULL)));
        assert!(marked(&raise));
        assert!(marked(&step(full, Wake::Quiet, start, 31, Some(FULL))));
        // Lowered, asleep, or somebody else's: no mark, so that a start
        // after takes an administrator's 125 for theirs.
        assert!(!marked(&step(
            full,
            Wake::Quiet,
            start + HOLD,
            31,
            Some(FULL)
        )));
        assert!(!marked(&step(
            Reserve::Lean,
            Wake::Quiet,
            start,
            31,
            Some(31)
        )));
        assert!(!marked(&step(full, Wake::Quiet, start, 31, Some(200))));
        assert!(!marked(&step(
            Reserve::Lean,
            Wake::Quiet,
            start,
            31,
            Some(FULL)
        )));
    }

    #[test]
    fn the_wait_is_never_more_than_poll_takes() {
        let now = Instant::now();
        assert_eq!(timeout(Reserve::Lean, now), -1);
        assert_eq!(
            timeout(
                Reserve::Full {
                    until: now + Duration::from_millis(1500)
                },
                now
            ),
            1501
        );
        assert_eq!(
            timeout(Reserve::Full { until: now }, now + Duration::from_secs(5)),
            1
        );
        // Far away: as long as poll can wait, not a negative, which waits forever.
        assert_eq!(
            timeout(
                Reserve::Full {
                    until: now + Duration::from_secs(1 << 40)
                },
                now
            ),
            i32::MAX
        );
    }

    #[test]
    fn the_trigger_is_a_tenth_of_a_second_in_one() {
        assert_eq!(TRIGGER, b"some 100000 1000000\0");
    }
}
