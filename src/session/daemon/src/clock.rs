//! Tells the shell when the wall clock moved in a way a timer cannot see.
//!
//! A timer in the shell runs on the monotonic clock, which stands still while
//! the computer sleeps and does not follow a clock that is set or a new time
//! zone: what waits on one comes back as it went. Rather than look at the
//! wall clock every few seconds, the shell watches $XDG_RUNTIME_DIR/nova/clock
//! (Wake.qml), which this writes whole, one line, the reason and the wall
//! clock's seconds, each time one of these happens:
//!
//!   woke   the computer woke from a sleep: logind's PrepareForSleep(false),
//!          heard by the sleep-lock duty (sleep.rs)
//!   set    the wall clock was set or jumped: a timerfd that the kernel
//!          cancels when the real-time clock changes other than by ticking
//!          (TFD_TIMER_CANCEL_ON_SET), which a resume does as well
//!   zone   /etc/localtime was replaced: a new time zone
//!
//! The clock-watch duty waits for the last two in poll(), and does nothing
//! between them.

use std::ffi::c_int;
use std::fs;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use nova_sd::poll::{poll, PollFd, POLLIN};

use crate::common::{
    write_atomically, Context, FolderWatch, IN_CLOSE_WRITE, IN_CREATE, IN_DELETE, IN_MOVED_TO,
};
use crate::say;

pub const DUTY: &str = "clock-watch";

/// The file the shell watches, in the runtime folder.
pub const STAMP: &str = "clock";

/// The time zone's file, in its folder: replaced, not written in place, by
/// timedated (timedatectl set-timezone) and by hand alike.
const ZONE: &str = "localtime";

/// Writes the stamp: <why> and the wall clock's seconds.
pub fn moved(ctx: &Context, why: &str) {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let written = ctx
        .runtime_dir()
        .and_then(|dir| write_atomically(&dir.join(STAMP), &format!("{why} {seconds}\n")));
    if let Err(e) = written {
        say!(
            DUTY,
            "could not tell the shell the clock moved ({why}): {e}"
        );
    }
}

#[repr(C)]
struct TimeSpec {
    tv_sec: i64,
    tv_nsec: i64,
}

#[repr(C)]
struct ITimerSpec {
    it_interval: TimeSpec,
    it_value: TimeSpec,
}

extern "C" {
    fn timerfd_create(clock: c_int, flags: c_int) -> c_int;
    fn timerfd_settime(
        fd: c_int,
        flags: c_int,
        new: *const ITimerSpec,
        old: *mut ITimerSpec,
    ) -> c_int;
}

const CLOCK_REALTIME: c_int = 0;
const TFD_NONBLOCK: c_int = 0o4000;
const TFD_CLOEXEC: c_int = 0o2000000;
const TFD_TIMER_ABSTIME: c_int = 1;
const TFD_TIMER_CANCEL_ON_SET: c_int = 2;
const ECANCELED: i32 = 125;
/// Far off, but within what the kernel takes (KTIME_SEC_MAX, in 2262): the
/// timer is there to be cancelled, not to go off.
const NEVER: i64 = 8_000_000_000;

/// A timer on the real-time clock that never goes off and is cancelled
/// whenever the clock is set.
pub struct ClockSet {
    file: fs::File,
}

impl ClockSet {
    pub fn new() -> io::Result<ClockSet> {
        // SAFETY: no pointers; a new descriptor or -1.
        let fd = unsafe { timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a descriptor just made, and ours alone.
        let timer = ClockSet {
            file: fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) }),
        };
        timer.arm()?;
        Ok(timer)
    }

    /// Set again, as a cancelled timer stays cancelled until it is.
    fn arm(&self) -> io::Result<()> {
        let when = ITimerSpec {
            it_interval: TimeSpec {
                tv_sec: 0,
                tv_nsec: 0,
            },
            it_value: TimeSpec {
                tv_sec: NEVER,
                tv_nsec: 0,
            },
        };
        // SAFETY: a live timerfd and a valid itimerspec; the old one is not asked for.
        let set = unsafe {
            timerfd_settime(
                self.file.as_raw_fd(),
                TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET,
                &when,
                std::ptr::null_mut(),
            )
        };
        if set != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    pub fn fd(&self) -> RawFd {
        self.file.as_raw_fd()
    }

    /// Whether the clock was set since the last look; the timer is set
    /// again if it was.
    pub fn was_set(&self) -> io::Result<bool> {
        let mut expirations = [0u8; 8];
        match io::Read::read(&mut &self.file, &mut expirations) {
            Err(e) if e.raw_os_error() == Some(ECANCELED) => {
                self.arm()?;
                Ok(true)
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(false),
            Err(e) => Err(e),
            // Gone off, in 2223: as good as set.
            Ok(_) => {
                self.arm()?;
                Ok(true)
            }
        }
    }
}

/// Watches the clock, and <zone> (the folder of the time zone's file), until
/// a wait fails.
pub fn watch(ctx: &Context, zone: &Path) -> Result<(), String> {
    let clock = ClockSet::new().map_err(|e| format!("could not watch the clock: {e}"))?;
    let zones = FolderWatch::new(zone, IN_CREATE | IN_MOVED_TO | IN_CLOSE_WRITE | IN_DELETE)
        .map_err(|e| format!("could not watch {}: {e}", zone.display()))?;
    loop {
        let mut fds = [
            PollFd::new(clock.fd(), POLLIN),
            PollFd::new(zones.fd(), POLLIN),
        ];
        poll(&mut fds, None).map_err(|e| format!("could not wait: {e}"))?;
        // A new zone is said over a clock set at the same moment: the zone
        // is the one the shell must hear of.
        let set = fds[0].ready()
            && clock
                .was_set()
                .map_err(|e| format!("could not read the clock's timer: {e}"))?;
        let zoned = fds[1].ready() && zones.names().iter().any(|n| n == ZONE);
        if zoned {
            moved(ctx, "zone");
        } else if set {
            moved(ctx, "set");
        }
    }
}

pub fn run(ctx: &Context) -> Result<(), String> {
    watch(ctx, Path::new("/etc"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{context, wait_until};
    use nova_sd::testing::scratch;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;

    fn stamp(ctx: &Context) -> String {
        fs::read_to_string(ctx.runtime.join(STAMP)).unwrap_or_default()
    }

    #[test]
    fn the_stamp_is_the_reason_and_the_wall_clock_in_seconds_written_whole() {
        let dir = scratch("clock");
        let ctx = context(&dir);
        fs::remove_dir_all(&ctx.runtime).unwrap();
        moved(&ctx, "woke");
        let line = stamp(&ctx);
        let (why, seconds) = line.trim_end().split_once(' ').unwrap();
        assert_eq!(why, "woke");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(now.abs_diff(seconds.parse::<u64>().unwrap()) < 5, "{line}");
        assert!(line.ends_with('\n'));
        // The folder made, and nothing left beside the stamp.
        let names: Vec<String> = fs::read_dir(&ctx.runtime)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec![STAMP]);
    }

    #[test]
    fn a_clock_left_alone_is_not_said_to_be_set() {
        let timer = ClockSet::new().unwrap();
        let mut fds = [PollFd::new(timer.fd(), POLLIN)];
        poll(&mut fds, Some(std::time::Duration::from_millis(50))).unwrap();
        assert!(!fds[0].ready());
        assert!(!timer.was_set().unwrap());
    }

    #[test]
    fn a_new_time_zone_is_said_and_other_files_beside_it_are_not() {
        let dir = scratch("clock");
        let ctx = context(&dir);
        let etc: PathBuf = dir.join("etc");
        fs::create_dir_all(&etc).unwrap();
        symlink("/usr/share/zoneinfo/Europe/Rome", etc.join(ZONE)).unwrap();
        let watcher = ctx.clone();
        let zone = etc.clone();
        std::thread::spawn(move || watch(&watcher, &zone));
        // Once it watches: a file of its own beside the zone's says nothing.
        std::thread::sleep(std::time::Duration::from_millis(100));
        fs::write(etc.join("hostname"), "nova\n").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));
        assert_eq!(stamp(&ctx), "");
        // timedated's way: a new link made beside it, moved over it.
        symlink(
            "/usr/share/zoneinfo/America/Santiago",
            etc.join(".#localtime"),
        )
        .unwrap();
        fs::rename(etc.join(".#localtime"), etc.join(ZONE)).unwrap();
        wait_until("the new zone", || stamp(&ctx).starts_with("zone "));
        fs::remove_file(ctx.runtime.join(STAMP)).unwrap();
        // By hand: removed, and made again.
        fs::remove_file(etc.join(ZONE)).unwrap();
        symlink("/usr/share/zoneinfo/Asia/Tokyo", etc.join(ZONE)).unwrap();
        wait_until("the zone made again", || stamp(&ctx).starts_with("zone "));
    }
}
