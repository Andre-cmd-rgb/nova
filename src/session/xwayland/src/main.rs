//! nova-xwayland, installed as /usr/lib/nova/bin/Xwayland: the X server
//! starts when the first X11 app comes, and its settings are in place before
//! that app is let in.
//!
//! Hyprland opens the X sockets itself and names them in DISPLAY, then runs
//! `Xwayland :N -rootless -core -listenfd A -listenfd B -displayfd D -wm W`
//! from PATH as it starts, whether or not an X11 app ever comes: 25 MB of
//! memory and 6 MiB of graphics memory at rest, in every session. Nova's
//! commands come first on the session's PATH, so Hyprland runs this instead:
//!
//! 1. It waits, asleep, on the sockets Hyprland handed over. A connection
//!    waits in the socket's queue, where the kernel keeps it.
//! 2. With the first one it becomes Xwayland (the next one on PATH), given
//!    `-noreset` and one more socket, `-initfd`, at
//!    $XDG_RUNTIME_DIR/nova/xwayland-N.init.
//!    Xwayland listens there at once, and on the apps' sockets only when
//!    the window manager has come (WM_S0), which is Hyprland's own, started
//!    when Xwayland says it is ready on `-displayfd`.
//! 3. So the word on `-displayfd` is held back: a helper takes it, runs
//!    `nova-hyprland-x11-scale --new-server` through the `-initfd` socket
//!    (Xft.dpi in the resources, xsettingsd with the scale, the theme and the
//!    cursor), waits until XSETTINGS has an owner when the pass says
//!    xsettingsd is coming, and only then passes the word on.
//!    Hyprland starts its window manager, Xwayland opens the apps' sockets,
//!    and the app that woke it finds the scale and the theme already there.
//!    Toolkits read them once, as they start (Qt and SDL the resources,
//!    Chrome and Electron the XSETTINGS): set a moment later, the first app
//!    of every session would be drawn at half its size.
//!
//! While it waits, $XDG_RUNTIME_DIR/nova/xwayland-N.wait says so:
//! nova-hyprland-x11-scale then writes the settings down and wakes nothing.
//! Both files go whenever a starter begins on display N (its X server is
//! the only one there can be), and before any start without them: one left
//! by a starter that was killed asleep, or by an X server that ended, is
//! gone with the next X server, and until then there is none on N to wake.
//! Without the settings' socket (it could not be made), the settings pass
//! runs all the same, once the apps are let in.
//!
//! Anything else that runs `Xwayland` (gamescope starts one of its own and
//! waits for it before it starts the game) gets Xwayland, unchanged, whatever
//! its environment says: only a child of Hyprland given sockets to listen on
//! is Nova's. Under Hyprland, NOVA_XWAYLAND=eager in the environment turns
//! the waiting off and keeps the rest: the X server starts with the session,
//! its settings in place before any app.

mod x11;

use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{self, Command, Stdio};
use std::time::{Duration, Instant};

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

const POLLIN: i16 = 0x001;
const POLLERR: i16 = 0x008;
const POLLHUP: i16 = 0x010;
const F_SETFD: i32 = 2;
const FD_CLOEXEC: i32 = 1;
const F_SETFL: i32 = 4;
const O_NONBLOCK: i32 = 0o4000;
const PR_SET_PDEATHSIG: i32 = 1;
const SIGTERM: u64 = 15;

extern "C" {
    fn poll(fds: *mut PollFd, count: u64, timeout: i32) -> i32;
    fn fork() -> i32;
    fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
    fn fcntl(fd: i32, command: i32, argument: i32) -> i32;
    fn prctl(option: i32, argument: u64, a3: u64, a4: u64, a5: u64) -> i32;
    fn getppid() -> i32;
    fn close(fd: i32) -> i32;
    fn _exit(code: i32) -> !;
}

/// The settings pass may take this long before the app is let in without it.
const SETTINGS_PATIENCE: Duration = Duration::from_secs(5);

/// What Hyprland's command line says, as far as the waiting needs it.
#[derive(Debug, PartialEq)]
struct Plan {
    /// The display's number: N of `:N`.
    display: String,
    /// The sockets the apps connect to.
    listen: Vec<RawFd>,
    /// Where Xwayland writes that it is ready, and the argument that names it.
    ready: RawFd,
    ready_argument: usize,
    /// The window manager's socket, Xwayland's alone.
    manager: RawFd,
}

impl Plan {
    /// None for a command line that is not a compositor's with sockets to
    /// listen on, a window manager to wait for and a word to send when ready.
    fn from_arguments(arguments: &[OsString]) -> Option<Plan> {
        let text = |index: usize| arguments.get(index).and_then(|a| a.to_str());
        let number = |index: usize| {
            text(index)
                .and_then(|a| a.parse::<RawFd>().ok())
                .filter(|fd| *fd > 2)
        };
        let mut display = None;
        let (mut listen, mut ready, mut manager, mut settings) = (Vec::new(), None, None, false);
        let mut index = 0;
        while index < arguments.len() {
            match text(index)? {
                "-listenfd" | "-listen" => listen.push(number(index + 1)?),
                "-displayfd" => ready = Some((number(index + 1)?, index + 1)),
                "-wm" => manager = number(index + 1),
                "-initfd" => settings = true,
                name if name.starts_with(':') && display.is_none() => {
                    let digits = &name[1..];
                    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
                        return None;
                    }
                    display = Some(digits.to_string());
                    index += 1;
                    continue;
                }
                _ => {
                    index += 1;
                    continue;
                }
            }
            index += 2;
        }
        let (ready, ready_argument) = ready?;
        // A compositor that brings its own -initfd runs its own settings.
        if listen.is_empty() || settings {
            return None;
        }
        Some(Plan {
            display: display?,
            listen,
            ready,
            ready_argument,
            manager: manager?,
        })
    }

    /// Xwayland's arguments: ready goes to the helper, the settings get a
    /// socket of their own, and the server stays as it is when its last
    /// client leaves. Without -noreset it starts over then, and cannot: the
    /// Wayland connection it was given is spent. Started Hyprland's way that
    /// never comes up, its window manager being the first client and the
    /// last; here xrdb comes and goes before the window manager is let in.
    fn arguments(
        &self,
        given: &[OsString],
        ready: RawFd,
        settings: Option<RawFd>,
    ) -> Vec<OsString> {
        let mut arguments = given.to_vec();
        arguments[self.ready_argument] = ready.to_string().into();
        if !given.iter().any(|argument| argument == "-noreset") {
            arguments.push("-noreset".into());
        }
        if let Some(settings) = settings {
            arguments.push("-initfd".into());
            arguments.push(settings.to_string().into());
        }
        arguments
    }
}

/// The display's number of any X server's command line: N of its first `:N`.
fn display_of(arguments: &[OsString]) -> Option<String> {
    let name = arguments
        .iter()
        .filter_map(|a| a.to_str())
        .find(|a| a.starts_with(':'))?;
    let digits = &name[1..];
    (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())).then(|| digits.to_string())
}

/// Where the starter of display <display> keeps its marks under <state>: the
/// settings' socket, and the mark that it waits.
fn marks(state: &Path, display: &str) -> (PathBuf, PathBuf) {
    (
        state.join(format!("xwayland-{display}.init")),
        state.join(format!("xwayland-{display}.wait")),
    )
}

/// Xwayland as it was asked for, its marks gone first: a socket nobody would
/// answer on, a mark that says it waits.
fn fall_back(arguments: &[OsString], marks: &(PathBuf, PathBuf)) -> ! {
    let _ = fs::remove_file(&marks.0);
    let _ = fs::remove_file(&marks.1);
    become_xwayland(arguments)
}

fn say(message: &str) {
    eprintln!("nova-xwayland: {message}");
}

/// The Xwayland after this one on PATH; /usr/bin's if PATH has none.
fn real_xwayland() -> PathBuf {
    let own = env::current_exe().and_then(fs::canonicalize).ok();
    env::var_os("PATH")
        .into_iter()
        .flat_map(|path| env::split_paths(&path).collect::<Vec<_>>())
        .map(|dir| dir.join("Xwayland"))
        .find(|candidate| {
            let Ok(real) = fs::canonicalize(candidate) else {
                return false;
            };
            Some(&real) != own.as_ref()
                && fs::metadata(&real)
                    .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
                    .unwrap_or(false)
        })
        .unwrap_or_else(|| PathBuf::from("/usr/bin/Xwayland"))
}

/// Becomes Xwayland with these arguments; returns only if that failed.
fn become_xwayland(arguments: &[OsString]) -> ! {
    let xwayland = real_xwayland();
    let error = Command::new(&xwayland)
        .arg0("Xwayland")
        .args(arguments)
        .exec();
    say(&format!("could not start {}: {error}", xwayland.display()));
    process::exit(1);
}

/// When the X server starts: with the first app, with the session, or (for
/// anyone but Hyprland) as plain Xwayland, at once and unchanged.
#[derive(PartialEq)]
enum Start {
    WithAnApp,
    WithTheSession,
    Plain,
}

/// The parent decides first: an X server of anyone but Hyprland (gamescope's,
/// started in a session whose environment says eager) is not Nova's to set up.
/// NOVA_XWAYLAND only chooses between the two starts under Hyprland.
fn start() -> Start {
    let parent = unsafe { getppid() };
    match fs::read_to_string(format!("/proc/{parent}/comm")) {
        Ok(comm) if comm.trim() == "Hyprland" => {}
        _ => return Start::Plain,
    }
    match env::var("NOVA_XWAYLAND").as_deref() {
        Ok("eager") => Start::WithTheSession,
        _ => Start::WithAnApp,
    }
}

/// Sleeps until an app has connected to one of the sockets (true), or the
/// compositor has gone (false). A connection stays in the socket's queue.
fn wait_for_an_app(listen: &[RawFd], compositor: Option<RawFd>) -> bool {
    let mut fds: Vec<PollFd> = listen
        .iter()
        .map(|fd| PollFd {
            fd: *fd,
            events: POLLIN,
            revents: 0,
        })
        .collect();
    // No events asked for: the kernel still says when the other end closed.
    if let Some(fd) = compositor {
        fds.push(PollFd {
            fd,
            events: 0,
            revents: 0,
        });
    }
    loop {
        let ready = unsafe { poll(fds.as_mut_ptr(), fds.len() as u64, -1) };
        if ready < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return false;
        }
        if compositor.is_some()
            && fds
                .last()
                .is_some_and(|fd| fd.revents & (POLLHUP | POLLERR) != 0)
        {
            return false;
        }
        if fds[..listen.len()]
            .iter()
            .any(|fd| fd.revents & POLLIN != 0)
        {
            return true;
        }
        if fds[..listen.len()].iter().any(|fd| fd.revents != 0) {
            return false;
        }
    }
}

/// The settings pass for a new X server, given until <deadline>: whether it
/// ended well having started xsettingsd ("xsettingsd" on its output), whose
/// settings are then still to come.
fn settings_pass(deadline: Instant) -> bool {
    let mut child = match Command::new("nova-hyprland-x11-scale")
        .arg("--new-server")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            say(&format!("could not run nova-hyprland-x11-scale: {error}"));
            return false;
        }
    };
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    say(&format!("nova-hyprland-x11-scale failed ({status}); the app starts without the X11 settings"));
                    return false;
                }
                // What it said before it ended, read without waiting on what
                // it started, which may hold the pipe still.
                let mut said = Vec::new();
                if let Some(out) = child.stdout.take() {
                    let fd = OwnedFd::from(out);
                    unsafe { fcntl(fd.as_raw_fd(), F_SETFL, O_NONBLOCK) };
                    let _ = fs::File::from(fd).read_to_end(&mut said);
                }
                return String::from_utf8_lossy(&said)
                    .lines()
                    .any(|line| line == "xsettingsd");
            }
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                say("the X11 settings took too long; the app starts without waiting for them");
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

/// The helper's whole life: Xwayland's word that it is ready, the settings
/// through their own socket (<socket>), XSETTINGS owned when xsettingsd is
/// coming, and the word passed on. Without the socket the word goes first and
/// the settings after, once the apps are let in. Without the word (Xwayland
/// did not start) it ends with `to` closed, which is how Hyprland learns of a
/// start that failed, and the socket goes with it.
fn settle_settings(mut from: fs::File, mut to: fs::File, socket: Option<&Path>) -> io::Result<()> {
    let mut word = Vec::new();
    let mut byte = [0u8; 1];
    while !word.ends_with(b"\n") {
        if from.read(&mut byte)? == 0 {
            if let Some(socket) = socket {
                let _ = fs::remove_file(socket);
            }
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "Xwayland ended before it was ready",
            ));
        }
        word.push(byte[0]);
    }
    let deadline = Instant::now() + SETTINGS_PATIENCE;
    let Some(socket) = socket else {
        to.write_all(&word)?;
        drop(to);
        settings_pass(deadline);
        return Ok(());
    };
    // xsettingsd is started, not yet heard: wait until it holds the settings.
    // After a pass that failed, or started none, nobody is coming, and the
    // app is not kept.
    if settings_pass(deadline) {
        if let Err(error) = x11::wait_for_owner(socket, "_XSETTINGS_S0", deadline) {
            say(&format!(
                "XSETTINGS has no owner ({error}); the app starts without them"
            ));
        }
    }
    to.write_all(&word)
}

fn main() {
    let arguments: Vec<OsString> = env::args_os().skip(1).collect();
    let start = start();
    let state = env::var_os("XDG_RUNTIME_DIR")
        .filter(|dir| !dir.is_empty())
        .map(|dir| PathBuf::from(dir).join("nova"));
    // Whatever X server starts on display N is the only one there: what an
    // earlier starter of N left is stale, whoever starts this one.
    let display = display_of(&arguments);
    if let (Some(state), Some(display)) = (&state, &display) {
        let (socket, waiting) = marks(state, display);
        let _ = fs::remove_file(socket);
        let _ = fs::remove_file(waiting);
    }
    let plan = match Plan::from_arguments(&arguments) {
        Some(plan) if start != Start::Plain => plan,
        _ => become_xwayland(&arguments),
    };
    let Some(state) = state else {
        become_xwayland(&arguments)
    };
    let marks = marks(&state, &plan.display);
    let (socket, waiting) = (&marks.0, &marks.1);
    let _ = fs::create_dir_all(&state);
    let compositor = env::var("WAYLAND_SOCKET")
        .ok()
        .and_then(|fd| fd.parse::<RawFd>().ok());
    if start == Start::WithAnApp {
        if fs::write(waiting, b"").is_err() {
            fall_back(&arguments, &marks);
        }
        // Gone with the compositor: told by the kernel when it ends, and by
        // its end of the Wayland socket closing.
        unsafe { prctl(PR_SET_PDEATHSIG, SIGTERM, 0, 0, 0) };
        if !wait_for_an_app(&plan.listen, compositor) {
            let _ = fs::remove_file(waiting);
            process::exit(0);
        }
    }

    // The settings' socket first, then the mark off: from here
    // nova-hyprland-x11-scale talks to X through the socket. Without one it
    // talks to X as any app does, once the apps are let in.
    let settings = match UnixListener::bind(socket) {
        Ok(listener) => Some(OwnedFd::from(listener)),
        Err(error) => {
            say(&format!(
                "no socket for the settings at {} ({error}); they come once the apps are let in",
                socket.display()
            ));
            let _ = fs::remove_file(socket);
            None
        }
    };
    let _ = fs::remove_file(waiting);
    let Ok((ready_read, ready_write)) = io::pipe() else {
        fall_back(&arguments, &marks)
    };
    let ready_write = OwnedFd::from(ready_write);

    // The helper is nobody's child once its parent has gone, so it leaves no
    // zombie under Xwayland: a child that ends at once, and its child.
    let child = unsafe { fork() };
    if child == 0 {
        if unsafe { fork() } != 0 {
            unsafe { _exit(0) };
        }
        // Not its to hold: Xwayland's sockets, the window manager's and the
        // Wayland connection; and Hyprland's ready pipe is its own, not what
        // it runs (the settings pass, xrdb, systemctl).
        for fd in plan
            .listen
            .iter()
            .copied()
            .chain([plan.manager])
            .chain(compositor)
        {
            unsafe { close(fd) };
        }
        unsafe { fcntl(plan.ready, F_SETFD, FD_CLOEXEC) };
        let has_socket = settings.is_some();
        drop(settings);
        drop(ready_write);
        unsafe { prctl(PR_SET_PDEATHSIG, 0, 0, 0, 0) };
        let to = unsafe { fs::File::from_raw_fd(plan.ready) };
        let code = match settle_settings(
            fs::File::from(OwnedFd::from(ready_read)),
            to,
            has_socket.then_some(socket.as_path()),
        ) {
            Ok(()) => 0,
            Err(error) => {
                say(&error.to_string());
                1
            }
        };
        unsafe { _exit(code) };
    }
    if child < 0 {
        say("could not fork the settings helper");
        fall_back(&arguments, &marks);
    }
    let mut status = 0;
    unsafe { waitpid(child, &mut status, 0) };
    drop(ready_read);
    // The helper alone holds Hyprland's end now: a start that fails closes it.
    unsafe { close(plan.ready) };
    // Xwayland inherits the ones it was not given by Hyprland.
    let (ready, settings) = (
        ready_write.into_raw_fd(),
        settings.map(IntoRawFd::into_raw_fd),
    );
    for fd in [Some(ready), settings].into_iter().flatten() {
        unsafe { fcntl(fd, F_SETFD, 0) };
    }
    unsafe { prctl(PR_SET_PDEATHSIG, 0, 0, 0, 0) };
    become_xwayland(&plan.arguments(&arguments, ready, settings));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(text: &str) -> Vec<OsString> {
        text.split_whitespace().map(OsString::from).collect()
    }

    #[test]
    fn hyprlands_command_line_is_a_plan() {
        let given = arguments(":1 -rootless -core -listenfd 41 -listenfd 42 -displayfd 47 -wm 46");
        let plan = Plan::from_arguments(&given).expect("a plan");
        assert_eq!(
            plan,
            Plan {
                display: "1".into(),
                listen: vec![41, 42],
                ready: 47,
                ready_argument: 8,
                manager: 46
            }
        );
        let rewritten = plan.arguments(&given, 50, Some(51));
        assert_eq!(rewritten, arguments(":1 -rootless -core -listenfd 41 -listenfd 42 -displayfd 50 -wm 46 -noreset -initfd 51"));
        // Said once, by whoever said it.
        let given = arguments(":1 -rootless -noreset -listenfd 41 -displayfd 47 -wm 46");
        let plan = Plan::from_arguments(&given).expect("a plan");
        assert_eq!(
            plan.arguments(&given, 50, Some(51)),
            arguments(":1 -rootless -noreset -listenfd 41 -displayfd 50 -wm 46 -initfd 51")
        );
        // No socket for the settings: none named.
        assert_eq!(
            plan.arguments(&given, 50, None),
            arguments(":1 -rootless -noreset -listenfd 41 -displayfd 50 -wm 46")
        );
    }

    #[test]
    fn any_x_servers_display_is_its_first_colon_number() {
        assert_eq!(display_of(&arguments(":7 -rootless")), Some("7".into()));
        assert_eq!(
            display_of(&arguments("-rootless :12 :13")),
            Some("12".into())
        );
        // gamescope's picks one with -displayfd and names none.
        assert_eq!(display_of(&arguments("-rootless -displayfd 5")), None);
        assert_eq!(display_of(&arguments(":x")), None);
    }

    #[test]
    fn a_command_line_without_the_sockets_a_manager_and_a_ready_word_is_left_alone() {
        // By hand, or a test: nothing to wait on.
        assert_eq!(Plan::from_arguments(&arguments(":7")), None);
        assert_eq!(Plan::from_arguments(&arguments("-version")), None);
        // No window manager to hold the apps back for.
        assert_eq!(
            Plan::from_arguments(&arguments(":1 -rootless -listenfd 41 -displayfd 47")),
            None
        );
        // Nobody to tell.
        assert_eq!(
            Plan::from_arguments(&arguments(":1 -rootless -listenfd 41 -wm 46")),
            None
        );
        // A compositor with a settings pass of its own (GNOME's).
        assert_eq!(
            Plan::from_arguments(&arguments(
                ":1 -rootless -listenfd 41 -displayfd 47 -wm 46 -initfd 9"
            )),
            None
        );
        // Not descriptors: the standard ones, or words.
        assert_eq!(
            Plan::from_arguments(&arguments(":1 -listenfd 1 -displayfd 47 -wm 46")),
            None
        );
        assert_eq!(
            Plan::from_arguments(&arguments(":1 -listenfd x -displayfd 47 -wm 46")),
            None
        );
        assert_eq!(
            Plan::from_arguments(&arguments(":one -listenfd 41 -displayfd 47 -wm 46")),
            None
        );
    }
}
