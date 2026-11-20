// nova-sessiond: what the session watches for as long as it runs, in one
// small process.
//
// Each of these was a program of its own, Python or bash, most with programs
// of their own under them (gdbus monitor, journalctl, jq, socat, sed,
// systemd-inhibit, sleep), about 67 MB between them, for what is mostly
// waiting. Here each is a duty on a thread of its own, asleep in poll() until
// D-Bus, the journal or Hyprland has something for it:
//
//   idle-inhibitors  org.freedesktop.ScreenSaver for the apps that keep the screen on
//   sleep-lock       the lock before sleep, under logind's delay inhibitor
//   crash-watch      "… quit unexpectedly", with Reopen, for an app a crash took away
//   display-watch    the clamshell passes and the X11 scale as displays come and go
//   automount        removable drives mounted, while somebody has unlocked
//   printing         the job viewer while jobs are queued, and the notices of a printer plugged in
//
// A duty that fails says why and starts again after a pause, longer each time
// in a row; the others go on meanwhile. One with nothing to do here (no
// Hyprland) ends, and the rest go on. nova-sessiond.service runs it.

mod automount;
mod common;
mod crash;
mod displays;
mod hypr;
mod idle;
mod json;
mod printing;
mod sleep;
#[cfg(test)]
mod testing;

use std::ffi::c_int;
use std::thread;
use std::time::{Duration, Instant};

use common::{Backoff, Context};

type Duty = fn(&Context) -> Result<(), String>;

const DUTIES: [(&str, Duty); 6] = [
    (idle::DUTY, idle::run),
    (sleep::DUTY, sleep::run),
    (crash::DUTY, crash::run),
    (displays::DUTY, displays::run),
    (automount::DUTY, automount::run),
    (printing::DUTY, printing::run),
];

/// Runs a duty again after each failure: 2 s after the first in a row, up to
/// a minute; a duty that ran for a minute before it failed starts over at 2 s.
fn supervise(name: &'static str, duty: Duty, ctx: Context) {
    let mut backoff = Backoff::new(Duration::from_secs(2), Duration::from_secs(60));
    loop {
        let started = Instant::now();
        match duty(&ctx) {
            Ok(()) => return,
            Err(e) => say!(name, "{e}"),
        }
        if started.elapsed() > Duration::from_secs(60) {
            backoff = Backoff::new(Duration::from_secs(2), Duration::from_secs(60));
        }
        thread::sleep(backoff.pause());
    }
}

// The signals that stop the daemon, waited for on the main thread: blocked in
// every thread (the duties inherit the mask), and taken with sigwait.
#[repr(C)]
struct SigSet([u64; 16]);

extern "C" {
    fn sigemptyset(set: *mut SigSet) -> c_int;
    fn sigaddset(set: *mut SigSet, signal: c_int) -> c_int;
    fn pthread_sigmask(how: c_int, set: *const SigSet, old: *mut SigSet) -> c_int;
    fn sigwait(set: *const SigSet, signal: *mut c_int) -> c_int;
}
const SIG_BLOCK: c_int = 0;
const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;

fn main() {
    let ctx = match Context::from_env() {
        Ok(ctx) => ctx,
        Err(e) => {
            eprintln!("nova-sessiond: {e}");
            std::process::exit(1);
        }
    };
    let mut stopping = SigSet([0; 16]);
    // SAFETY: a sigset_t-sized buffer, filled and used by the C library only.
    unsafe {
        sigemptyset(&mut stopping);
        sigaddset(&mut stopping, SIGTERM);
        sigaddset(&mut stopping, SIGINT);
        pthread_sigmask(SIG_BLOCK, &stopping, std::ptr::null_mut());
    }
    for (name, duty) in DUTIES {
        let ctx = ctx.clone();
        // Small stacks: the duties hold little, and a thread's stack is its own memory.
        let started = thread::Builder::new()
            .name(name.into())
            .stack_size(256 * 1024)
            .spawn(move || supervise(name, duty, ctx));
        if let Err(e) = started {
            say!(name, "could not start: {e}");
        }
    }
    let mut signal = 0;
    // SAFETY: the set made above and a valid pointer.
    unsafe { sigwait(&stopping, &mut signal) };
    // Stopped, it holds the screen awake for nobody: the shell counts idle
    // time again. logind's inhibitor goes with the process.
    idle::clean_up(&ctx);
    std::process::exit(0);
}
