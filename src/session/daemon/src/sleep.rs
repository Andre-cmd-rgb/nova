//! Locks the session before the computer sleeps.
//!
//! logind says on the system bus as the machine is about to sleep
//! (PrepareForSleep true) and once it has woken (false). While the machine is
//! awake, this holds a delay inhibitor, so that logind waits, up to
//! InhibitDelayMaxSec, for nova-system-sleep-lock to lock the session; then it
//! lets it go, and the machine sleeps. logind takes a new inhibitor only once
//! it has said the machine woke, and it is taken again then.
//!
//! The inhibitor is a descriptor logind hands over, held in this process and
//! closed on exec, so that no helper run meanwhile keeps it.
//!
//! The wake is the shell's to hear of too: its timers stood still through
//! the sleep, and it learns of the wake from the clock stamp (clock.rs).
//!
//! logind's Lock for this session locks it too: `loginctl lock-session` and
//! `lock-sessions`, and what is built on them (a rule that locks when a key
//! is pulled out, an administrator locking every session). The session is the
//! user's display session, logind's "auto": a user service belongs to none.
//! Its Unlock is not followed, on purpose: any program of the user's may ask
//! logind for one (`loginctl unlock-session`), and the lock opens to the
//! password or the finger alone. The shell tells logind how the lock is
//! (LockedHint: plugins/lock/LockedHint.qml).

use std::cell::RefCell;
use std::collections::VecDeque;
use std::os::fd::OwnedFd;
use std::rc::Rc;
use std::sync::Arc;

use nova_sd::poll::{poll, sooner};
use nova_sd::{Bus, Value};

use crate::clock;
use crate::common::Context;
use crate::say;

pub const DUTY: &str = "sleep-lock";
const LOGIND: &str = "org.freedesktop.login1";
const PATH: &str = "/org/freedesktop/login1";
const MANAGER: &str = "org.freedesktop.login1.Manager";
const SESSION: &str = "org.freedesktop.login1.Session";

#[derive(Debug, Clone, PartialEq)]
enum Event {
    /// logind has an owner again (or for the first time this watch knows).
    Owner,
    /// PrepareForSleep: true before the sleep, false after the wake.
    Sleep(bool),
    /// A session's Lock, by its object path.
    Lock(String),
}

/// Woken from a sleep the lock was not up for: the screens stay off, and the
/// lock is asked for again until it is (nova-system-sleep-lock --resumed).
fn relock(ctx: &Context) {
    if ctx.runtime.join("sleep-unsecured").exists() {
        ctx.spawn(&["nova-system-sleep-lock", "--resumed"], true);
    }
}

/// Holds logind's delay inhibitor; one at a time, a new one in the old one's place.
fn hold(bus: &Bus, inhibitor: &mut Option<Arc<OwnedFd>>) {
    *inhibitor = None;
    let taken = bus.call(
        LOGIND,
        PATH,
        MANAGER,
        "Inhibit",
        &[
            Value::str("sleep"),
            Value::str("Nova"),
            Value::str("Locking the screen before sleep"),
            Value::str("delay"),
        ],
    );
    match taken {
        Ok(answer) => *inhibitor = answer.first().and_then(Value::as_fd).cloned(),
        Err(e) => say!(
            DUTY,
            "logind gave no inhibitor, so no lock before sleep: {e}"
        ),
    }
}

/// The session this runs for, logind's object path for it; none, said why,
/// where logind knows of no display session of this user's.
fn own_session(bus: &Bus) -> Option<String> {
    match bus.call(LOGIND, PATH, MANAGER, "GetSession", &[Value::str("auto")]) {
        Ok(answer) => answer.first().and_then(Value::as_str).map(str::to_owned),
        Err(e) => {
            say!(DUTY, "logind knows no session of this user's to lock: {e}");
            None
        }
    }
}

/// Watches logind on <bus> until the bus goes.
pub fn serve(bus: &Bus, ctx: &Context) -> Result<(), String> {
    relock(ctx);
    let events = Rc::new(RefCell::new(VecDeque::new()));
    let queue = events.clone();
    let _sleep = bus
        .match_signal(
            Some(LOGIND),
            Some(PATH),
            Some(MANAGER),
            Some("PrepareForSleep"),
            move |m| {
                if let Some(going) = m
                    .args()
                    .ok()
                    .and_then(|a| a.first().and_then(Value::as_bool))
                {
                    queue.borrow_mut().push_back(Event::Sleep(going));
                }
            },
        )
        .map_err(|e| e.to_string())?;
    // Every session's Lock, one match: which session is this one's is asked
    // of each logind, and a Lock for another is not this one's to follow.
    let queue = events.clone();
    let _lock = bus
        .match_signal(Some(LOGIND), None, Some(SESSION), Some("Lock"), move |m| {
            if let Some(path) = m.path() {
                queue.borrow_mut().push_back(Event::Lock(path.to_owned()));
            }
        })
        .map_err(|e| e.to_string())?;
    // logind's owner is asked for once its signals are watched, so a sleep
    // logind waits for is never one this has not heard of. A new owner, a
    // logind started again, gets an inhibitor of its own, in case the one
    // held before went with the last.
    let queue = events.clone();
    let (_owner, now) = bus
        .watch_name(LOGIND, move |owner| {
            if owner.is_some() {
                queue.borrow_mut().push_back(Event::Owner);
            }
        })
        .map_err(|e| e.to_string())?;
    let mut inhibitor = None;
    let mut session = None;
    if now.is_some() {
        hold(bus, &mut inhibitor);
        session = own_session(bus);
    }
    loop {
        let mut fds = [bus.poll_fd()];
        poll(&mut fds, sooner(bus.timeout(), None)).map_err(|e| format!("could not wait: {e}"))?;
        bus.dispatch()
            .map_err(|e| format!("the system bus went, and with it the lock before sleep: {e}"))?;
        loop {
            let Some(event) = events.borrow_mut().pop_front() else {
                break;
            };
            match event {
                Event::Owner => {
                    hold(bus, &mut inhibitor);
                    session = own_session(bus);
                }
                Event::Lock(path) if session.as_deref() == Some(path.as_str()) => {
                    say!(DUTY, "logind asked for the lock");
                    ctx.spawn(&["nova-system-lock"], true);
                }
                Event::Lock(_) => {}
                Event::Sleep(true) => {
                    ctx.run(&["nova-system-sleep-lock"]);
                    inhibitor = None;
                }
                Event::Sleep(false) => {
                    relock(ctx);
                    clock::moved(ctx, "woke");
                    hold(bus, &mut inhibitor);
                }
            }
        }
    }
}

pub fn run(ctx: &Context) -> Result<(), String> {
    let bus = Bus::system().map_err(|e| e.to_string())?;
    serve(&bus, ctx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{calls, context, duty, stub, wait_until, Service};
    use nova_sd::poll::{PollFd, POLLOUT};
    use nova_sd::testing::{scratch, PrivateBus};
    use nova_sd::{Interface, Message};
    use std::any::Any;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::sync::Mutex;

    extern "C" {
        fn pipe2(fds: *mut i32, flags: i32) -> i32;
    }

    /// The write ends of the inhibitors handed out: one whose reader is
    /// closed everywhere has been let go.
    type Handed = Arc<Mutex<Vec<OwnedFd>>>;

    /// This user's display session, and another's.
    const OWN: &str = "/org/freedesktop/login1/session/_32";
    const OTHER: &str = "/org/freedesktop/login1/session/c1";

    /// logind, as far as this needs it: Inhibit hands over the read end of a
    /// pipe, GetSession("auto") names OWN, and two sessions send their signals.
    fn logind(address: &str, handed: Handed) -> Service {
        Service::start(address, move |bus| {
            let manager = Interface::new(MANAGER)
                .method("Inhibit", "ssss", "h")
                .method("GetSession", "s", "o")
                .signal("PrepareForSleep", "b");
            let object = bus
                .export(PATH, vec![manager], move |m: &Message, args: Vec<Value>| {
                    if m.member() == Some("GetSession") {
                        assert_eq!(args[0].as_str(), Some("auto"));
                        return Ok(vec![Value::path(OWN)]);
                    }
                    assert_eq!(args[0].as_str(), Some("sleep"));
                    assert_eq!(args[3].as_str(), Some("delay"));
                    let mut fds = [0; 2];
                    // SAFETY: a valid array of two.
                    assert_eq!(unsafe { pipe2(fds.as_mut_ptr(), 0o2000000) }, 0);
                    // SAFETY: both just made, and ours.
                    let (read, write) =
                        unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
                    handed.lock().unwrap().push(write);
                    Ok(vec![Value::Fd(Arc::new(read))])
                })
                .unwrap();
            let sessions: Vec<_> = [OWN, OTHER]
                .into_iter()
                .map(|path| {
                    let session = Interface::new(SESSION)
                        .signal("Lock", "")
                        .signal("Unlock", "");
                    bus.export(path, vec![session], |_: &Message, _: Vec<Value>| Ok(vec![]))
                        .unwrap()
                })
                .collect();
            assert!(bus.request_name(LOGIND, 0).unwrap());
            Box::new((object, sessions)) as Box<dyn Any>
        })
    }

    fn session_signal(logind: &Service, path: &'static str, member: &'static str) {
        logind.send(move |bus, _| bus.emit_signal(path, SESSION, member, &[]).unwrap());
    }

    /// How many inhibitors were handed out, and how many are held now.
    fn inhibitors(handed: &Handed) -> (usize, usize) {
        let handed = handed.lock().unwrap();
        let held = handed
            .iter()
            .filter(|w| {
                let mut fds = [PollFd::new(w.as_raw_fd(), POLLOUT)];
                nova_sd::poll::poll(&mut fds, Some(std::time::Duration::ZERO)).unwrap();
                !fds[0].broken()
            })
            .count();
        (handed.len(), held)
    }

    fn sleep_signal(logind: &Service, going: bool) {
        logind.send(move |bus, _| {
            bus.emit_signal(PATH, MANAGER, "PrepareForSleep", &[Value::Bool(going)])
                .unwrap()
        });
    }

    /// A lock that takes a moment, and leaves the marker when <dir>/unsecured
    /// is there, as the real one does when it is not up in time.
    fn lock_stub(dir: &std::path::Path) {
        stub(
            dir,
            "nova-system-sleep-lock",
            &format!(
                "marker='{0}/run/nova/sleep-unsecured'
if [[ ${{1:-}} == --resumed ]]; then rm -f \"$marker\"; exit 0; fi
for fd in /proc/$$/fd/*; do echo \"${{fd##*/}}=$(readlink $fd)\"; done >'{0}/fds'
sleep 0.2
if [[ -e '{0}/unsecured' ]]; then : >\"$marker\"; exit 1; fi",
                dir.display()
            ),
        );
    }

    #[test]
    fn a_sleep_locks_first_then_lets_the_inhibitor_go_and_takes_it_again_on_the_wake() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("sleep");
        let ctx = context(&dir);
        lock_stub(&dir);
        let handed: Handed = Arc::default();
        let logind = logind(&private.address, handed.clone());
        let _duty = duty(&private.address, &ctx, serve);
        wait_until("an inhibitor", || inhibitors(&handed) == (1, 1));
        sleep_signal(&logind, true);
        wait_until("the lock", || calls(&dir) == vec!["nova-system-sleep-lock"]);
        // Held while the lock comes up, and let go once it is.
        assert_eq!(inhibitors(&handed), (1, 1));
        wait_until("the inhibitor to go", || inhibitors(&handed) == (1, 0));
        assert!(!ctx.runtime.join(clock::STAMP).exists());
        sleep_signal(&logind, false);
        wait_until("a new inhibitor", || inhibitors(&handed) == (2, 1));
        // The shell is told of the wake.
        let stamp = std::fs::read_to_string(ctx.runtime.join(clock::STAMP)).unwrap();
        assert!(stamp.starts_with("woke "), "{stamp}");
        // A lock that was up in time is not asked for again.
        assert_eq!(calls(&dir), vec!["nova-system-sleep-lock"]);
        // The lock ran with nothing of the daemon's open: not the inhibitor,
        // which would have held the sleep off for as long as it ran.
        let fds = std::fs::read_to_string(dir.join("fds")).unwrap();
        let inhibitor = std::fs::read_link(format!(
            "/proc/self/fd/{}",
            handed.lock().unwrap()[0].as_raw_fd()
        ))
        .unwrap();
        assert!(inhibitor.to_string_lossy().starts_with("pipe:"));
        assert!(!fds.contains(&*inhibitor.to_string_lossy()), "{fds}");
    }

    #[test]
    fn logind_s_lock_for_this_session_locks_it_and_its_unlock_opens_nothing() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("sleep");
        let ctx = context(&dir);
        stub(&dir, "nova-system-lock", "exit 0");
        let handed: Handed = Arc::default();
        let logind = logind(&private.address, handed.clone());
        let _duty = duty(&private.address, &ctx, serve);
        wait_until("an inhibitor", || inhibitors(&handed) == (1, 1));
        // Another session's Lock, and this one's Unlock, come first: neither
        // does anything, and the Lock after them locks, once.
        session_signal(&logind, OTHER, "Lock");
        session_signal(&logind, OWN, "Unlock");
        session_signal(&logind, OWN, "Lock");
        wait_until("the lock", || calls(&dir) == vec!["nova-system-lock"]);
        std::thread::sleep(std::time::Duration::from_millis(200));
        assert_eq!(calls(&dir), vec!["nova-system-lock"]);
    }

    #[test]
    fn a_new_logind_gets_a_new_inhibitor() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("sleep");
        let ctx = context(&dir);
        let first: Handed = Arc::default();
        let logind_one = logind(&private.address, first.clone());
        let _duty = duty(&private.address, &ctx, serve);
        wait_until("an inhibitor", || inhibitors(&first) == (1, 1));
        drop(logind_one);
        let second: Handed = Arc::default();
        let _logind_two = logind(&private.address, second.clone());
        wait_until("an inhibitor from the new logind", || {
            inhibitors(&second) == (1, 1)
        });
    }

    #[test]
    fn a_sleep_the_lock_was_not_up_for_asks_for_it_again_on_the_wake() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("sleep");
        let ctx = context(&dir);
        lock_stub(&dir);
        std::fs::write(dir.join("unsecured"), "").unwrap();
        let handed: Handed = Arc::default();
        let logind = logind(&private.address, handed.clone());
        let _duty = duty(&private.address, &ctx, serve);
        wait_until("an inhibitor", || inhibitors(&handed) == (1, 1));
        sleep_signal(&logind, true);
        wait_until("the inhibitor to go", || inhibitors(&handed) == (1, 0));
        sleep_signal(&logind, false);
        wait_until("the lock again", || {
            calls(&dir).contains(&"nova-system-sleep-lock --resumed".to_owned())
        });
        wait_until("the marker to go", || {
            !ctx.runtime.join("sleep-unsecured").exists()
        });
    }

    #[test]
    fn started_after_such_a_sleep_it_asks_for_the_lock_again_at_once() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("sleep");
        let ctx = context(&dir);
        lock_stub(&dir);
        std::fs::write(ctx.runtime.join("sleep-unsecured"), "").unwrap();
        let handed: Handed = Arc::default();
        let _logind = logind(&private.address, handed.clone());
        let _duty = duty(&private.address, &ctx, serve);
        wait_until("the lock", || {
            calls(&dir) == vec!["nova-system-sleep-lock --resumed"]
        });
    }

    #[test]
    fn without_logind_nothing_is_held_until_it_comes_and_a_bus_that_goes_ends_the_duty() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("sleep");
        let ctx = context(&dir);
        let duty = duty(&private.address, &ctx, serve);
        std::thread::sleep(std::time::Duration::from_millis(100));
        let handed: Handed = Arc::default();
        let logind = logind(&private.address, handed.clone());
        wait_until("an inhibitor", || inhibitors(&handed) == (1, 1));
        drop(logind);
        drop(private);
        let ended = duty.join().unwrap().unwrap_err();
        assert!(ended.contains("the system bus went"), "{ended}");
    }
}
