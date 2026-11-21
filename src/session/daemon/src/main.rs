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
//   clock-watch      the shell told when the wall clock moved: a wake, a clock set, a new time zone
//   crash-watch      "… quit unexpectedly", with Reopen, for an app a crash took away
//   display-watch    the clamshell passes and the X11 scale as displays come and go
//   automount        removable drives mounted, while somebody has unlocked
//   bluetooth-pairing  the questions of a pairing the user picked, on the shell's card
//   printing         a printer out of paper or jammed, and a held job's password on the card, while jobs are queued
//
// A duty that fails says why and starts again after a pause, longer each time
// in a row; the others go on meanwhile. One with nothing to do here (no
// Hyprland) ends, and the rest go on. nova-sessiond.service runs it.

mod automount;
mod bluetooth;
mod clock;
mod common;
mod crash;
mod displays;
mod exchange;
mod filechooser;
mod hypr;
mod idle;
mod json;
mod keyring;
mod pinentry;
mod printing;
mod prompt;
mod share;
mod simpin;
mod sleep;
#[cfg(test)]
mod testing;

use std::ffi::c_int;
use std::thread;
use std::time::{Duration, Instant};

use common::{Backoff, Context};

type Duty = fn(&Context) -> Result<(), String>;

const DUTIES: [(&str, Duty); 10] = [
    (idle::DUTY, idle::run),
    (sleep::DUTY, sleep::run),
    (clock::DUTY, clock::run),
    (crash::DUTY, crash::run),
    (displays::DUTY, displays::run),
    (automount::DUTY, automount::run),
    (bluetooth::DUTY, bluetooth::run),
    (printing::DUTY, printing::run),
    (keyring::DUTY, keyring::run),
    (filechooser::DUTY, filechooser::run),
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

/// xdg-desktop-portal-hyprland asks Nova's card what to share once
/// ~/.config/hypr/xdph.conf says so: an account made before Nova did has none
/// yet. xdph reads it when it starts.
fn provide_share_picker() {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|c| !c.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config")));
    if let Some(config) = config {
        match share::provide_config(&config) {
            Ok(true) => say!("share", "wrote {}/hypr/xdph.conf", config.display()),
            Ok(false) => {}
            Err(e) => say!(
                "share",
                "could not write {}/hypr/xdph.conf: {e}",
                config.display()
            ),
        }
    }
}

fn main() {
    // The same program answers for gpg-agent, for the screen-sharing portal
    // and for mobile-data's SIM PIN under other names: one copy of the
    // card's and the bus's code, and no program more to keep in memory.
    let called = std::env::args_os()
        .next()
        .map(std::path::PathBuf::from)
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()));
    match called.as_deref() {
        Some("nova-pinentry") => std::process::exit(pinentry::main()),
        Some("nova-share-picker") => std::process::exit(share::main()),
        Some("nova-sim-pin") => std::process::exit(simpin::main()),
        _ => {}
    }
    let ctx = match Context::from_env() {
        Ok(ctx) => ctx,
        Err(e) => {
            eprintln!("nova-sessiond: {e}");
            std::process::exit(1);
        }
    };
    provide_share_picker();
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
