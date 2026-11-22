//! The starter as Hyprland runs it, with a compositor, an Xwayland and a
//! settings pass of the test's own: nothing starts until an app connects, the
//! settings run before the compositor hears that X is ready, and anything
//! that is not Hyprland's X server gets Xwayland unchanged. Hyprland is a
//! shell started by that name. No display, no
//! session: a scratch runtime directory and scripts on a PATH of the test's.

use std::fs;
use std::io::Read;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

extern "C" {
    fn fcntl(fd: i32, command: i32, argument: i32) -> i32;
    fn kill(pid: i32, signal: i32) -> i32;
}

static SCRATCHES: AtomicU32 = AtomicU32::new(0);

struct Session {
    dir: PathBuf,
    apps: PathBuf,
    ready: fs::File,
    compositor: Option<UnixStream>,
    child: Child,
    given: Vec<String>,
}

fn script(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn inherited(fd: &impl AsRawFd) -> i32 {
    assert_eq!(unsafe { fcntl(fd.as_raw_fd(), 2, 0) }, 0);
    fd.as_raw_fd()
}

fn wait_for(what: &str, mut holds: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !holds() {
        assert!(Instant::now() < deadline, "never: {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Who runs the starter: a parent named Hyprland (a shell by that name, which
/// starts it and closes its own copies of what it handed over, as Hyprland
/// does), or anyone else (the test itself, as gamescope would).
#[derive(Clone, Copy, PartialEq)]
enum Parent {
    Hyprland,
    Another,
}

/// Starts the starter with Hyprland's command line, from `parent`, with
/// NOVA_XWAYLAND set to `mode` in its environment.
fn start(parent: Parent, mode: Option<&str>) -> Session {
    start_with(parent, mode, |_| {})
}

/// The same, with <before> run on the scratch directory first.
fn start_with(parent: Parent, mode: Option<&str>, before: impl FnOnce(&Path)) -> Session {
    let dir = std::env::temp_dir().join(format!("nova-xwayland-{}-{}", std::process::id(), SCRATCHES.fetch_add(1, Ordering::SeqCst)));
    let _ = fs::remove_dir_all(&dir);
    for sub in ["bin", "run/nova", "out"] {
        fs::create_dir_all(dir.join(sub)).unwrap();
    }
    // The kernel names a process after the file it was started from.
    std::os::unix::fs::symlink("/bin/bash", dir.join("Hyprland")).unwrap();
    // The Xwayland after the starter on PATH: says what it was given, closes
    // the settings' socket (no X server is behind it here), says it is ready
    // and stays.
    script(
        &dir.join("bin/Xwayland"),
        "#!/bin/bash\nprintf '%s\\n' \"$@\" >\"$OUT/arguments.new\"\nmv \"$OUT/arguments.new\" \"$OUT/arguments\"\n\
         while (($#)); do case $1 in -displayfd) ready=$2 ;; -initfd) init=$2 ;; esac; shift; done\n\
         [[ -z ${init:-} ]] || eval \"exec $init>&-\"\n\
         [[ -z ${ready:-} ]] || eval \"printf '7\\n' >&$ready; exec $ready>&-\"\nexec sleep 60\n",
    );
    // The settings pass: what it found, what it was given and holds, and
    // that it took its time.
    script(
        &dir.join("bin/nova-hyprland-x11-scale"),
        "#!/bin/bash\nls \"$XDG_RUNTIME_DIR/nova\" >\"$OUT/state\"\necho \"$DISPLAY\" >\"$OUT/display\"\n\
         echo \"$*\" >\"$OUT/pass-arguments\"\nls /proc/$$/fd >\"$OUT/fds\"\nsleep 0.3\n: >\"$OUT/settled\"\n",
    );
    let apps = dir.join("run/X7");
    let sockets = [UnixListener::bind(&apps).unwrap(), UnixListener::bind(dir.join("run/X7_")).unwrap()];
    let (ready_read, ready_write) = std::io::pipe().unwrap();
    let (manager, _manager_end) = UnixStream::pair().unwrap();
    let (compositor, wayland) = UnixStream::pair().unwrap();
    let ready_write = OwnedFd::from(ready_write);
    let given: Vec<String> = format!(
        ":7 -rootless -core -listenfd {} -listenfd {} -displayfd {} -wm {}",
        inherited(&sockets[0]),
        inherited(&sockets[1]),
        inherited(&ready_write),
        inherited(&manager)
    )
    .split(' ')
    .map(String::from)
    .collect();
    let starter = env!("CARGO_BIN_EXE_nova-xwayland");
    let mut command = match parent {
        Parent::Another => {
            let mut command = Command::new(starter);
            command.arg0("Xwayland");
            command
        }
        Parent::Hyprland => {
            let mut command = Command::new(dir.join("Hyprland"));
            command.args([
                "-c",
                "\"$0\" \"$@\" & child=$!\n\
                 for fd in /proc/$$/fd/*; do fd=${fd##*/}; ((fd > 2)) && eval \"exec $fd>&-\" 2>/dev/null; done\n\
                 wait \"$child\"",
                starter,
            ]);
            command
        }
    };
    command
        .args(&given)
        .process_group(0)
        .env_clear()
        .env("PATH", format!("{}:/usr/bin", dir.join("bin").display()))
        .env("XDG_RUNTIME_DIR", dir.join("run"))
        .env("OUT", dir.join("out"))
        .env("DISPLAY", ":7")
        .env("WAYLAND_SOCKET", inherited(&wayland).to_string());
    if let Some(mode) = mode {
        command.env("NOVA_XWAYLAND", mode);
    }
    before(&dir);
    let child = command.spawn().unwrap();
    // The compositor's ends stay here; the X server's are the child's alone.
    drop((sockets, ready_write, manager, wayland));
    Session { dir, apps, ready: fs::File::from(OwnedFd::from(ready_read)), compositor: Some(compositor), child, given }
}

impl Session {
    fn out(&self, name: &str) -> PathBuf {
        self.dir.join("out").join(name)
    }
    fn state(&self, name: &str) -> PathBuf {
        self.dir.join("run/nova").join(name)
    }
    fn arguments(&self) -> Vec<String> {
        fs::read_to_string(self.out("arguments")).unwrap().lines().map(String::from).collect()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // The parent and everything it started: the starter, its Xwayland.
        unsafe { kill(-(self.child.id() as i32), 15) };
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn nothing_starts_until_an_app_connects_and_the_settings_come_first() {
    let mut session = start(Parent::Hyprland, None);
    wait_for("the waiting mark", || session.state("xwayland-7.wait").exists());
    std::thread::sleep(Duration::from_millis(200));
    assert!(!session.out("arguments").exists(), "Xwayland started with no app");
    assert!(!session.state("xwayland-7.init").exists());
    assert!(session.child.try_wait().unwrap().is_none());

    // The first X11 app: its connection waits in the socket's queue.
    let _app = UnixStream::connect(&session.apps).unwrap();
    let mut word = [0u8; 2];
    session.ready.read_exact(&mut word).unwrap();
    assert_eq!(&word, b"7\n");
    // The compositor hears "ready" only after the settings pass has ended.
    assert!(session.out("settled").exists(), "ready was passed on before the settings");

    // Xwayland got Hyprland's command line with ready rerouted and a socket for the settings.
    let arguments = session.arguments();
    assert_eq!(arguments.len(), session.given.len() + 3);
    assert_eq!(arguments[arguments.len() - 3], "-noreset");
    assert_eq!(arguments[arguments.len() - 2], "-initfd");
    let ready_at = session.given.iter().position(|a| a == "-displayfd").unwrap() + 1;
    assert_ne!(arguments[ready_at], session.given[ready_at]);
    for (index, argument) in session.given.iter().enumerate() {
        if index != ready_at {
            assert_eq!(&arguments[index], argument);
        }
    }
    // The settings pass found the socket and no waiting mark, and the session's DISPLAY.
    assert_eq!(fs::read_to_string(session.out("state")).unwrap(), "xwayland-7.init\n");
    assert_eq!(fs::read_to_string(session.out("display")).unwrap(), ":7\n");
    assert_eq!(fs::read_to_string(session.out("pass-arguments")).unwrap(), "--new-server\n");
    // And none of what Hyprland handed over: the apps' sockets, the window
    // manager's, the ready pipe, the Wayland connection.
    let held: Vec<String> = fs::read_to_string(session.out("fds")).unwrap().lines().map(String::from).collect();
    let numbers = |flag: &str| -> Vec<String> {
        session.given.iter().enumerate().filter(|(_, a)| *a == flag).map(|(i, _)| session.given[i + 1].clone()).collect()
    };
    for flag in ["-listenfd", "-displayfd", "-wm"] {
        for fd in numbers(flag) {
            assert!(!held.contains(&fd), "the settings pass holds {flag} {fd}: {held:?}");
        }
    }
    // The starter is Xwayland now: the same process, still there.
    assert!(session.child.try_wait().unwrap().is_none());
}

#[test]
fn it_ends_with_the_compositor_having_started_nothing() {
    let mut session = start(Parent::Hyprland, None);
    wait_for("the waiting mark", || session.state("xwayland-7.wait").exists());
    session.compositor.take();
    wait_for("the starter's end", || session.child.try_wait().unwrap().is_some());
    assert!(session.child.wait().unwrap().success());
    assert!(!session.state("xwayland-7.wait").exists());
    assert!(!session.out("arguments").exists());
}

#[test]
fn an_x_server_that_does_not_start_is_told_to_the_compositor_as_a_closed_pipe() {
    let mut session = start(Parent::Hyprland, None);
    // An Xwayland that ends at once, with nothing said.
    script(&session.dir.join("bin/Xwayland"), "#!/bin/bash\nexit 1\n");
    wait_for("the waiting mark", || session.state("xwayland-7.wait").exists());
    let _app = UnixStream::connect(&session.apps).unwrap();
    let mut word = Vec::new();
    session.ready.read_to_end(&mut word).unwrap();
    assert!(word.is_empty(), "ready was said for an X server that never was");
    assert!(!session.out("settled").exists());
    // Its settings' socket goes with it: nobody would answer there.
    assert!(!session.state("xwayland-7.init").exists());
    assert!(!session.state("xwayland-7.wait").exists());
}

#[test]
fn what_an_earlier_starter_of_the_display_left_goes_whoever_starts_the_next() {
    // A starter killed asleep leaves its mark, an X server that ended its
    // socket: stale with the next start, plain or Nova's.
    for parent in [Parent::Another, Parent::Hyprland] {
        let stale = |dir: &Path| {
            fs::write(dir.join("run/nova/xwayland-7.wait"), b"").unwrap();
            fs::write(dir.join("run/nova/xwayland-7.init"), b"").unwrap();
        };
        let mut session = start_with(parent, Some("eager"), stale);
        let mut word = [0u8; 2];
        session.ready.read_exact(&mut word).unwrap();
        assert!(!session.state("xwayland-7.wait").exists());
        if parent == Parent::Another {
            assert!(!session.state("xwayland-7.init").exists(), "a plain start leaves none");
        } else {
            // Nova's made its own, the one the settings pass found.
            assert_eq!(fs::read_to_string(session.out("state")).unwrap(), "xwayland-7.init\n");
        }
    }
}

#[test]
fn without_a_socket_for_the_settings_they_come_once_the_apps_are_let_in() {
    // Something that is no socket where the settings' socket goes: it
    // cannot be made, and the X server starts without it.
    let mut session = start_with(Parent::Hyprland, None, |dir| fs::create_dir(dir.join("run/nova/xwayland-7.init")).unwrap());
    wait_for("the waiting mark", || session.state("xwayland-7.wait").exists());
    let _app = UnixStream::connect(&session.apps).unwrap();
    let mut word = [0u8; 2];
    session.ready.read_exact(&mut word).unwrap();
    assert!(!session.arguments().iter().any(|a| a == "-initfd"), "{:?}", session.arguments());
    // The settings pass runs all the same, after the word.
    wait_for("the settings pass", || session.out("settled").exists());
    assert_eq!(fs::read_to_string(session.out("pass-arguments")).unwrap(), "--new-server\n");
}

#[test]
fn anyone_elses_xwayland_starts_at_once_and_unchanged() {
    // Not Hyprland's child (gamescope's, or a person's): no waiting, and no
    // settings pass, whatever the session's environment says: gamescope run
    // in a session that set eager has it too, and its X server is not the
    // desktop's.
    for mode in [None, Some("eager")] {
        let mut session = start(Parent::Another, mode);
        let mut word = [0u8; 2];
        session.ready.read_exact(&mut word).unwrap();
        assert_eq!(session.arguments(), session.given, "{mode:?}");
        assert!(!session.state("xwayland-7.wait").exists());
        assert!(!session.out("settled").exists(), "{mode:?}");
        assert!(!session.out("state").exists(), "{mode:?}");
        assert!(session.child.try_wait().unwrap().is_none());
    }
}

#[test]
fn eager_in_the_environment_turns_the_waiting_off_and_keeps_the_settings_first() {
    let mut session = start(Parent::Hyprland, Some("eager"));
    // No app has connected.
    let mut word = [0u8; 2];
    session.ready.read_exact(&mut word).unwrap();
    assert!(session.out("settled").exists(), "ready was passed on before the settings");
    assert_eq!(session.arguments()[session.given.len() + 1], "-initfd");
    assert_eq!(fs::read_to_string(session.out("state")).unwrap(), "xwayland-7.init\n");
}
