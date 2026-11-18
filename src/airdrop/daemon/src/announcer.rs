//! The one part of AirDrop that keeps any of the system's power: a process of
//! its own that announces over Bluetooth what wakes an iPhone's AirDrop
//! (wake.rs), and does nothing else.
//!
//! Binding Bluetooth's management socket takes CAP_NET_ADMIN, and the kernel
//! decides at binding what the socket may do: whoever holds it may tell the
//! controller anything, not only this announcement. The daemon hears whoever
//! is in radio range, so it does not hold it. At its start, before anything
//! else is open, it forks the announcer, which closes everything but its end
//! of a socket pair, binds the management socket, gives up every capability,
//! says `ready` (or `no` and why not), and from then on does what two requests
//! over the pair say:
//!
//!   announce <number>   the announcement, which it makes itself (wake.rs)
//!   quiet <number>      none
//!
//! each answered `<number> ok`, or `<number>` and why not, in a sentence for
//! the user; anything else is not understood. It reads and lets go of the
//! socket's events as they come, so that their queue never fills. It ignores
//! the signals that end the daemon, and ends, quiet, when the pair closes,
//! which is when the daemon has ended, however it did. The daemon gives up its
//! own capabilities as soon as it has its socket on the radio, before it runs
//! anything (openssl).

use std::ffi::{c_int, c_void};
use std::io::{self, ErrorKind};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::time::{Duration, Instant};

use crate::mgmt;
use crate::wake::Wake;

extern "C" {
    fn socketpair(domain: c_int, kind: c_int, protocol: c_int, fds: *mut c_int) -> c_int;
    fn fork() -> c_int;
    fn close(fd: c_int) -> c_int;
    fn _exit(status: c_int) -> !;
    fn recv(fd: c_int, buffer: *mut c_void, length: usize, flags: c_int) -> isize;
    fn send(fd: c_int, buffer: *const c_void, length: usize, flags: c_int) -> isize;
    fn signal(signal: c_int, handler: usize) -> usize;
}

const AF_UNIX: c_int = 1;
const SOCK_SEQPACKET: c_int = 5;
const SOCK_CLOEXEC: c_int = 0o2000000;
const MSG_DONTWAIT: c_int = 0x40;
const MSG_NOSIGNAL: c_int = 0x4000;
const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;
const SIG_IGN: usize = 1;

/// How often the announcement is given again: a little more often than it lasts (wake.rs).
pub const AGAIN_AFTER: Duration = Duration::from_secs(8);
/// How long an answer may take: the kernel is given three seconds for each of the four questions
/// an announcement can take.
const ANSWER_WITHIN: Duration = Duration::from_secs(13);
/// The longest thing either side says.
const LONGEST: usize = 512;

const GONE: &str = "Bluetooth could not be used to wake the iPhone's AirDrop.";
const SLOW: &str = "Bluetooth did not answer in time to wake the iPhone's AirDrop.";

/// What the announcer does with Bluetooth: Wake, or a test's.
pub trait Bluetooth {
    fn announce(&mut self) -> Result<(), String>;
    fn quiet(&mut self);
    /// The descriptor its events come on, if it has one.
    fn events(&self) -> Option<RawFd>;
    /// Reads and lets go of the events that came: how many.
    fn drain(&mut self) -> usize;
}

impl Bluetooth for Wake {
    fn announce(&mut self) -> Result<(), String> {
        Wake::announce(self)
    }

    fn quiet(&mut self) {
        Wake::quiet(self);
    }

    fn events(&self) -> Option<RawFd> {
        Some(Wake::events(self))
    }

    fn drain(&mut self) -> usize {
        Wake::drain(self)
    }
}

/// Says one thing over the pair; false if it could not.
fn say(pair: RawFd, words: &[u8]) -> bool {
    let words = &words[..words.len().min(LONGEST)];
    // SAFETY: as long as said; a peer that is gone is an error, not a signal.
    unsafe { send(pair, words.as_ptr().cast(), words.len(), MSG_NOSIGNAL) == words.len() as isize }
}

/// One thing said over the pair, within the time: Err(why) when the other end has gone, or said
/// nothing in time.
fn receive(pair: RawFd, within: Duration) -> Result<String, &'static str> {
    let until = Instant::now() + within;
    let mut buffer = [0u8; LONGEST];
    loop {
        let left = until.checked_duration_since(Instant::now()).ok_or(SLOW)?;
        mgmt::wait(&[pair], left);
        // SAFETY: the buffer is as long as said.
        let got = unsafe { recv(pair, buffer.as_mut_ptr().cast(), LONGEST, MSG_DONTWAIT) };
        match got {
            0 => return Err(GONE),
            got if got > 0 => {
                return Ok(String::from_utf8_lossy(&buffer[..got as usize]).into_owned())
            }
            _ => match io::Error::last_os_error().kind() {
                ErrorKind::WouldBlock | ErrorKind::Interrupted => {}
                _ => return Err(GONE),
            },
        }
    }
}

/// The answer to one request: `announce <number>` or `quiet <number>`, and nothing else.
fn answer(request: &[u8], bluetooth: &mut impl Bluetooth) -> String {
    let asked = std::str::from_utf8(request)
        .ok()
        .and_then(|words| words.split_once(' '))
        .filter(|(_, number)| {
            (1..=10).contains(&number.len()) && number.bytes().all(|b| b.is_ascii_digit())
        })
        .and_then(|(word, number)| Some((word, number.parse::<u32>().ok()?)));
    let Some((word, number)) = asked else {
        return "0 not understood".into();
    };
    match word {
        "announce" => match bluetooth.announce() {
            Ok(()) => format!("{number} ok"),
            Err(why) => format!("{number} {why}"),
        },
        "quiet" => {
            bluetooth.quiet();
            format!("{number} ok")
        }
        _ => format!("{number} not understood"),
    }
}

/// The announcer's work: the requests that come over `pair`, until it closes; then quiet.
pub fn serve(pair: RawFd, bluetooth: &mut impl Bluetooth) {
    let mut buffer = [0u8; LONGEST];
    loop {
        let mut fds = vec![pair];
        fds.extend(bluetooth.events());
        mgmt::wait(&fds, Duration::from_secs(60));
        let drained = bluetooth.drain();
        // SAFETY: the buffer is as long as said.
        let got = unsafe { recv(pair, buffer.as_mut_ptr().cast(), LONGEST, MSG_DONTWAIT) };
        if got == 0 {
            break;
        }
        if got < 0 {
            match io::Error::last_os_error().kind() {
                // Woken for nothing either side can read: not round again at once.
                ErrorKind::WouldBlock if drained == 0 => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                ErrorKind::WouldBlock | ErrorKind::Interrupted => {}
                _ => break,
            }
            continue;
        }
        let answer = answer(&buffer[..got as usize], bluetooth);
        if !say(pair, answer.as_bytes()) {
            break;
        }
    }
    bluetooth.quiet();
}

/// Closes every descriptor but these.
fn close_all_but(keep: &[RawFd]) {
    let open: Vec<RawFd> = std::fs::read_dir("/proc/self/fd")
        .map(|folder| {
            folder
                .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok())
                .collect()
        })
        .unwrap_or_default();
    for fd in open.into_iter().filter(|fd| !keep.contains(fd)) {
        // SAFETY: no pointers; nothing in this process uses these from now on.
        unsafe { close(fd) };
    }
}

/// The announcer itself, in the process forked for it.
fn announcer(pair: OwnedFd) -> ! {
    let fd = pair.as_raw_fd();
    close_all_but(&[0, 1, 2, fd]);
    // The daemon's end is this one's: when the pair closes, not at the signals that end it.
    // SAFETY: no pointers; ignoring is a disposition, not a handler.
    unsafe {
        signal(SIGTERM, SIG_IGN);
        signal(SIGINT, SIG_IGN);
    }
    let mut wake = match Wake::open() {
        Ok(wake) => wake,
        Err(why) => {
            say(fd, format!("no {why}").as_bytes());
            // SAFETY: no pointers; it does not return.
            unsafe { _exit(0) }
        }
    };
    if let Err(error) = mgmt::give_up_capabilities() {
        say(fd, format!("no Bluetooth: {error}").as_bytes());
        // SAFETY: as above.
        unsafe { _exit(1) }
    }
    say(fd, b"ready");
    serve(fd, &mut wake);
    // SAFETY: as above; the daemon's buffers and handlers are not this process's to run.
    unsafe { _exit(0) }
}

/// The daemon's side: what it asks of the announcer.
pub struct Announcer {
    pair: OwnedFd,
    number: u32,
    /// When it was last told to announce, and did, while it does.
    said: Option<Instant>,
    within: Duration,
}

impl Announcer {
    /// Forks the announcer (see the top of this file). Before any thread is started, and before
    /// anything is open that the announcer is not to have. Err(why) if it could not bind
    /// Bluetooth's management socket, or not start at all.
    pub fn fork() -> Result<Announcer, String> {
        let mut fds = [-1 as c_int; 2];
        // SAFETY: two descriptors' room, as the call fills.
        if unsafe { socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, fds.as_mut_ptr()) } != 0 {
            return Err(format!("Bluetooth: {}", io::Error::last_os_error()));
        }
        // SAFETY: just made, and nobody else's.
        let (ours, theirs) =
            unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        // SAFETY: no thread has been started, so the child is a whole copy of this process.
        match unsafe { fork() } {
            -1 => Err(format!("Bluetooth: {}", io::Error::last_os_error())),
            0 => {
                drop(ours);
                announcer(theirs)
            }
            _ => {
                drop(theirs);
                Announcer::over(ours, ANSWER_WITHIN)
            }
        }
    }

    /// The daemon's end of a pair that an announcer serves, once it has said whether it could
    /// bind the socket.
    fn over(pair: OwnedFd, within: Duration) -> Result<Announcer, String> {
        let hello = receive(pair.as_raw_fd(), within).map_err(|_| "Bluetooth: no answer")?;
        match hello.strip_prefix("no ") {
            _ if hello == "ready" => Ok(Announcer {
                pair,
                number: 0,
                said: None,
                within,
            }),
            Some(why) => Err(why.to_owned()),
            None => Err("Bluetooth: not understood".into()),
        }
    }

    /// The daemon's side of an announcer that said it was ready and answers nothing after, as one
    /// whose Bluetooth hangs: each request is given up on after `within`. Its other end, kept.
    #[cfg(test)]
    pub fn unanswering(within: Duration) -> (Announcer, OwnedFd) {
        let mut fds = [-1 as c_int; 2];
        // SAFETY: two descriptors' room, as the call fills.
        assert_eq!(
            unsafe { socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, fds.as_mut_ptr()) },
            0
        );
        // SAFETY: just made, and nobody else's.
        let (ours, theirs) =
            unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        assert!(say(theirs.as_raw_fd(), b"ready"));
        (Announcer::over(ours, within).unwrap(), theirs)
    }

    /// Announces, or says again what it announces, if it has not lately; why not, in a sentence
    /// for the user, when it cannot.
    pub fn announce(&mut self) -> Result<(), String> {
        if self.said.is_some_and(|said| said.elapsed() < AGAIN_AFTER) {
            return Ok(());
        }
        let done = self.ask("announce");
        self.said = done.is_ok().then(Instant::now);
        done
    }

    /// Stops announcing.
    pub fn quiet(&mut self) {
        self.said = None;
        let _ = self.ask("quiet");
    }

    fn ask(&mut self, word: &str) -> Result<(), String> {
        self.number = self.number.wrapping_add(1).max(1);
        let pair = self.pair.as_raw_fd();
        if !say(pair, format!("{word} {}", self.number).as_bytes()) {
            return Err(GONE.into());
        }
        let until = Instant::now() + self.within;
        let ours = format!("{} ", self.number);
        loop {
            let left = until.checked_duration_since(Instant::now()).ok_or(SLOW)?;
            let answer = receive(pair, left)?;
            // The answer to an earlier request that took too long is let go.
            if let Some(answer) = answer.strip_prefix(&ours) {
                return match answer {
                    "ok" => Ok(()),
                    why => Err(why.to_owned()),
                };
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;

    const SOCK_DGRAM: c_int = 2;

    fn pair(kind: c_int) -> (OwnedFd, OwnedFd) {
        let mut fds = [-1 as c_int; 2];
        // SAFETY: as in fork.
        assert_eq!(
            unsafe { socketpair(AF_UNIX, kind | SOCK_CLOEXEC, 0, fds.as_mut_ptr()) },
            0
        );
        // SAFETY: just made.
        unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
    }

    /// What a test's Bluetooth was asked to do.
    #[derive(Default)]
    struct Seen {
        announced: AtomicUsize,
        quieted: AtomicUsize,
        drained: AtomicUsize,
        off: AtomicBool,
    }

    struct Fake {
        seen: Arc<Seen>,
        events: OwnedFd,
        slow: Duration,
    }

    impl Bluetooth for Fake {
        fn announce(&mut self) -> Result<(), String> {
            std::thread::sleep(self.slow);
            self.seen.announced.fetch_add(1, Ordering::SeqCst);
            if self.seen.off.load(Ordering::SeqCst) {
                return Err(crate::wake::OFF.into());
            }
            Ok(())
        }

        fn quiet(&mut self) {
            self.seen.quieted.fetch_add(1, Ordering::SeqCst);
        }

        fn events(&self) -> Option<RawFd> {
            Some(self.events.as_raw_fd())
        }

        fn drain(&mut self) -> usize {
            let mut buffer = [0u8; 64];
            let mut drained = 0;
            // SAFETY: as long as said.
            while unsafe {
                recv(
                    self.events.as_raw_fd(),
                    buffer.as_mut_ptr().cast(),
                    64,
                    MSG_DONTWAIT,
                )
            } > 0
            {
                drained += 1;
            }
            self.seen.drained.fetch_add(drained, Ordering::SeqCst);
            drained
        }
    }

    /// An announcer served by a thread, over a pair, with a made-up Bluetooth; and its events'
    /// other end.
    fn served(slow: Duration) -> (Arc<Seen>, OwnedFd, OwnedFd, std::thread::JoinHandle<()>) {
        let seen = Arc::new(Seen::default());
        let (ours, theirs) = pair(SOCK_SEQPACKET);
        let (events, kernel) = pair(SOCK_DGRAM);
        let mut fake = Fake {
            seen: seen.clone(),
            events,
            slow,
        };
        let serving = std::thread::spawn(move || {
            assert!(say(theirs.as_raw_fd(), b"ready"));
            serve(theirs.as_raw_fd(), &mut fake);
        });
        (seen, ours, kernel, serving)
    }

    fn until(what: impl Fn() -> bool) -> bool {
        let began = Instant::now();
        while !what() {
            if began.elapsed() > Duration::from_secs(5) {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        true
    }

    #[test]
    fn the_announcer_does_what_two_requests_say_and_nothing_else() {
        let (seen, ours, _kernel, serving) = served(Duration::ZERO);
        let mut announcer = Announcer::over(ours, Duration::from_secs(5)).unwrap();
        assert_eq!(announcer.announce(), Ok(()));
        // Said again only when it is time to.
        assert_eq!(announcer.announce(), Ok(()));
        assert_eq!(seen.announced.load(Ordering::SeqCst), 1);
        // Anything but the two, with a number of their own, is not understood, and not done.
        let fd = announcer.pair.as_raw_fd();
        for request in [
            &b"announce"[..],
            b"announce 12 13",
            b"announce -1",
            b"announce 99999999999",
            b"announce \xff",
        ] {
            assert!(say(fd, request));
            assert_eq!(
                receive(fd, Duration::from_secs(5)).as_deref(),
                Ok("0 not understood"),
                "{request:?}"
            );
        }
        assert!(say(fd, b"set-power 7"));
        assert_eq!(
            receive(fd, Duration::from_secs(5)).as_deref(),
            Ok("7 not understood")
        );
        assert_eq!(seen.announced.load(Ordering::SeqCst), 1);
        // Why not, as Bluetooth says it.
        seen.off.store(true, Ordering::SeqCst);
        announcer.said = None;
        assert_eq!(announcer.announce(), Err(crate::wake::OFF.into()));
        announcer.quiet();
        assert_eq!(seen.quieted.load(Ordering::SeqCst), 1);
        // The daemon gone, it is quiet, and ends.
        drop(announcer);
        serving.join().unwrap();
        assert_eq!(seen.quieted.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn the_announcer_lets_go_of_the_sockets_events_as_they_come() {
        let (seen, ours, kernel, serving) = served(Duration::ZERO);
        let announcer = Announcer::over(ours, Duration::from_secs(5)).unwrap();
        for _ in 0..500 {
            assert!(say(kernel.as_raw_fd(), b"an event"));
        }
        assert!(until(|| seen.drained.load(Ordering::SeqCst) == 500));
        drop(announcer);
        serving.join().unwrap();
    }

    #[test]
    fn an_answer_that_comes_too_late_is_not_taken_for_the_next() {
        let (seen, ours, _kernel, serving) = served(Duration::from_millis(600));
        let mut announcer = Announcer::over(ours, Duration::from_millis(200)).unwrap();
        assert_eq!(announcer.announce(), Err(SLOW.into()));
        // The quiet's answer is waited for past the announce's.
        announcer.within = Duration::from_secs(5);
        announcer.quiet();
        assert_eq!(seen.quieted.load(Ordering::SeqCst), 1);
        drop(announcer);
        serving.join().unwrap();
    }

    #[test]
    fn an_announcer_that_could_not_bind_the_socket_says_why() {
        let (ours, theirs) = pair(SOCK_SEQPACKET);
        assert!(say(
            theirs.as_raw_fd(),
            b"no Bluetooth: Address family not supported by protocol"
        ));
        assert_eq!(
            Announcer::over(ours, Duration::from_secs(5))
                .err()
                .as_deref(),
            Some("Bluetooth: Address family not supported by protocol")
        );
        let (ours, theirs) = pair(SOCK_SEQPACKET);
        drop(theirs);
        assert!(Announcer::over(ours, Duration::from_secs(5)).is_err());
    }
}
