//! Waiting on several file descriptors at once: a bus, a journal, a socket.
//!
//! Each of Nova's watchers sleeps in poll() until one of its descriptors has
//! something, or its next deadline comes, so that an idle one is never woken.

use std::ffi::c_int;
use std::io;
use std::os::fd::RawFd;
use std::time::Duration;

use crate::ffi;

pub const POLLIN: i16 = 0x1;
pub const POLLPRI: i16 = 0x2;
pub const POLLOUT: i16 = 0x4;
pub const POLLERR: i16 = 0x8;
pub const POLLHUP: i16 = 0x10;
pub const POLLNVAL: i16 = 0x20;

/// struct pollfd.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct PollFd {
    pub fd: c_int,
    pub events: i16,
    pub revents: i16,
}

impl PollFd {
    pub fn new(fd: RawFd, events: i16) -> PollFd {
        PollFd {
            fd,
            events,
            revents: 0,
        }
    }

    /// Whether poll() said anything of it: something to read, room to write,
    /// or the other end gone.
    pub fn ready(&self) -> bool {
        self.revents != 0
    }

    /// Whether the other end has gone or the descriptor is broken.
    pub fn broken(&self) -> bool {
        self.revents & (POLLERR | POLLHUP | POLLNVAL) != 0
    }
}

/// Waits until one of <fds> is ready, or <timeout> has passed (never, for
/// none). A signal that cuts the wait short is no error: it returns 0, as for
/// a timeout, and the caller looks again.
pub fn poll(fds: &mut [PollFd], timeout: Option<Duration>) -> io::Result<usize> {
    let milliseconds = match timeout {
        None => -1,
        // Rounded up, so that a deadline 0.4 ms away is not polled for at once again and again.
        Some(t) => c_int::try_from(t.as_micros().div_ceil(1000)).unwrap_or(c_int::MAX),
    };
    for fd in fds.iter_mut() {
        fd.revents = 0;
    }
    // SAFETY: a valid array of pollfd, as long as it is said to be.
    let r = unsafe { ffi::poll(fds.as_mut_ptr(), fds.len() as u64, milliseconds) };
    if r < 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            return Ok(0);
        }
        return Err(error);
    }
    Ok(r as usize)
}

/// The sooner of two timeouts, where none is never.
pub fn sooner(a: Option<Duration>, b: Option<Duration>) -> Option<Duration> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, None) => a,
        (None, b) => b,
    }
}

/// CLOCK_MONOTONIC, in microseconds: the clock sd-bus's and sd-journal's
/// deadlines are on.
pub fn monotonic_usec() -> u64 {
    let mut time = ffi::Timespec {
        seconds: 0,
        nanoseconds: 0,
    };
    // SAFETY: a valid pointer to a timespec, which is all it writes.
    unsafe { ffi::clock_gettime(ffi::CLOCK_MONOTONIC, &mut time) };
    time.seconds as u64 * 1_000_000 + time.nanoseconds as u64 / 1000
}

/// An absolute CLOCK_MONOTONIC deadline in microseconds, as libsystemd gives
/// one (u64::MAX for none), as a timeout from now.
pub(crate) fn until(deadline_usec: u64) -> Option<Duration> {
    if deadline_usec == u64::MAX {
        return None;
    }
    Some(Duration::from_micros(
        deadline_usec.saturating_sub(monotonic_usec()),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sooner_timeout_wins_and_none_is_never() {
        let s = Duration::from_secs;
        assert_eq!(sooner(Some(s(3)), Some(s(1))), Some(s(1)));
        assert_eq!(sooner(None, Some(s(2))), Some(s(2)));
        assert_eq!(sooner(Some(s(2)), None), Some(s(2)));
        assert_eq!(sooner(None, None), None);
    }

    #[test]
    fn a_deadline_is_a_timeout_from_now() {
        assert_eq!(until(u64::MAX), None);
        assert_eq!(until(0), Some(Duration::ZERO));
        let later = until(monotonic_usec() + 5_000_000).unwrap();
        assert!(later <= Duration::from_secs(5) && later > Duration::from_secs(4));
    }
}
