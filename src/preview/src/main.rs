// nova-previewer: Quick Look's front on D-Bus (docs/using.md). Files asks for
// a preview of the selected file with Space, and this answers where GNOME
// Sushi used to. The window is the shell's (plugins/preview); this only
// speaks the bus. Quickshell cannot own a name, so this does, describes each
// file the way the window needs it, and hands it to the shell through
// nova-shell. D-Bus starts it on the first Space, so how soon it answers is
// how soon the preview opens: a Rust program with the system's libsystemd and
// GIO is up in a few milliseconds. It quits half a minute after the preview
// closes. Tests live in tests/unit/preview.
//
// What Files (Nautilus 51) calls, kept as Sushi's own so that nothing in
// Files changes: the name org.gnome.NautilusPreviewer, the path
// /org/gnome/NautilusPreviewer, the interface org.gnome.NautilusPreviewer2:
//   ShowFile(uri, windowHandle, closeIfAlreadyShown, activationToken)
//       the file asked for is shown, in the window already open if there is
//       one; the same file again closes it, when closeIfAlreadyShown says so
//   Close()
//   Visible, ParentHandle   properties, with PropertiesChanged
//   SelectionEvent(u)       a GTK direction (up 2, down 3, left 4, right 5):
//       Files moves its selection that way and calls ShowFile on the new one
// Sushi's NavigateTo, Rename and Trash signals are not sent: no key of the
// window asks for them. The window reports back through org.nova.Previewer
// on the same object: Select(u), which becomes SelectionEvent, and
// Closed(seq), that the window it showed as <seq> is gone. A Closed for an
// older file than the one now asked for is a window that was replaced, and
// changes nothing.
//
// For each file the shell is handed one line of JSON (nova-shell shell
// summon nova.preview): uri, path ("" when it has none on this computer),
// name, mime, kind (folder, image, pdf, video, audio, text or other), type (the
// kind in words), size (bytes, -1 for a folder), sizeText, items (a folder's,
// else -1), icon (theme icon names, best first) and seq.
//
// NOVA_PREVIEW_SHELL names the command that takes the place of nova-shell,
// NOVA_PREVIEW_IDLE_SECONDS the time before it quits; the tests set them.

mod describe;

use std::cell::RefCell;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::rc::Rc;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner, PollFd, POLLIN};
use nova_sd::{Bus, Interface, Message, Value};

const NAME: &str = "org.gnome.NautilusPreviewer";
const PATH: &str = "/org/gnome/NautilusPreviewer";
const PREVIEWER: &str = "org.gnome.NautilusPreviewer2";
const OURS: &str = "org.nova.Previewer";
const PLUGIN: &str = "nova.preview";

extern "C" {
    // glibc's; std has no stable way to wait on a child from poll().
    fn pidfd_open(pid: i32, flags: u32) -> i32;
}

fn log(message: &str) {
    eprintln!("nova-previewer: {message}");
}

/// A nova-shell call that has not ended yet.
struct Running {
    child: Child,
    pidfd: Option<OwnedFd>,
    summon: bool,
    seq: u32,
}

struct Previewer {
    bus: Bus,
    visible: bool,
    handle: String,
    uri: String,
    seq: u32,
    idle: Duration,
    /// When it quits, while nothing is shown.
    quit_at: Option<Instant>,
    running: Vec<Running>,
}

impl Previewer {
    fn changed(&self, property: &str, value: Value) {
        if let Err(error) =
            self.bus
                .emit_properties_changed(PATH, PREVIEWER, vec![(property, value)])
        {
            log(&format!("could not say {property} changed: {error}"));
        }
    }

    fn set_visible(&mut self, visible: bool) {
        if visible == self.visible {
            return;
        }
        self.visible = visible;
        self.changed("Visible", Value::Bool(visible));
        self.quit_at = (!visible).then(|| Instant::now() + self.idle);
    }

    fn show_file(&mut self, uri: &str, handle: &str, close_if_shown: bool) {
        if self.visible && uri == self.uri {
            if close_if_shown {
                self.close();
            }
            return;
        }
        self.uri = uri.to_string();
        self.seq += 1;
        if handle != self.handle {
            self.handle = handle.to_string();
            self.changed("ParentHandle", Value::str(handle));
        }
        let line = describe::describe(uri).json(self.seq);
        self.set_visible(true);
        self.ask(&["summon", PLUGIN, &line]);
    }

    fn close(&mut self) {
        self.ask(&["hide", PLUGIN]);
        self.set_visible(false);
    }

    /// One nova-shell call, answered in the background; a shell that is not
    /// there takes the preview away again.
    fn ask(&mut self, args: &[&str]) {
        let mut command = Command::new(shell_command());
        command.arg("shell").args(args).stdout(Stdio::null());
        match command.spawn() {
            Ok(child) => {
                // SAFETY: a child of ours, not reaped yet; the descriptor is new and ours.
                let fd = unsafe { pidfd_open(child.id() as i32, 0) };
                self.running.push(Running {
                    child,
                    pidfd: (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd) }),
                    summon: args[0] == "summon",
                    seq: self.seq,
                });
            }
            Err(error) => {
                log(&error.to_string());
                self.set_visible(false);
            }
        }
    }

    /// The nova-shell calls that have ended, and what each says.
    fn reap(&mut self) {
        let mut ended = Vec::new();
        self.running
            .retain_mut(|running| match running.child.try_wait() {
                Ok(None) => true,
                Ok(Some(status)) => {
                    ended.push((
                        status.success(),
                        status.to_string(),
                        running.summon,
                        running.seq,
                    ));
                    false
                }
                Err(_) => false,
            });
        for (success, status, summon, seq) in ended {
            if !success {
                log(&format!("the shell did not take it: {status}"));
                if summon && seq == self.seq {
                    self.set_visible(false);
                }
            }
        }
    }

    fn descriptors(&self) -> Vec<RawFd> {
        self.running
            .iter()
            .filter_map(|r| r.pidfd.as_ref().map(|fd| fd.as_raw_fd()))
            .collect()
    }
}

fn shell_command() -> PathBuf {
    if let Some(given) = std::env::var_os("NOVA_PREVIEW_SHELL").filter(|v| !v.is_empty()) {
        return given.into();
    }
    // D-Bus starts this with the environment it has, which may not have
    // Nova's bin on its PATH: nova-shell is next to this, in lib/nova/bin.
    let near = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.canonicalize().ok())
        .and_then(|exe| exe.parent().map(|dir| dir.join("bin").join("nova-shell")));
    match near {
        Some(near) if near.exists() => near,
        _ => "nova-shell".into(),
    }
}

/// Answers the object's calls from the shared state.
struct Object(Rc<RefCell<Previewer>>);

impl nova_sd::Handler for Object {
    fn call(&mut self, call: &Message, args: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
        let mut previewer = self.0.borrow_mut();
        let text = |at: usize| {
            args.get(at)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string()
        };
        match (call.interface().unwrap_or(""), call.member().unwrap_or("")) {
            (PREVIEWER, "ShowFile") => {
                let close = args.get(2).and_then(Value::as_bool).unwrap_or(false);
                previewer.show_file(&text(0), &text(1), close);
            }
            (PREVIEWER, "Close") => previewer.close(),
            (OURS, "Select") => {
                let direction = args.first().and_then(Value::as_u64).unwrap_or(0) as u32;
                if let Err(error) = previewer.bus.emit_signal(
                    PATH,
                    PREVIEWER,
                    "SelectionEvent",
                    &[Value::Uint32(direction)],
                ) {
                    log(&format!("could not pass the selection on: {error}"));
                }
            }
            (OURS, "Closed") => {
                let seq = args.first().and_then(Value::as_u64).unwrap_or(0);
                if seq == previewer.seq as u64 {
                    previewer.set_visible(false);
                }
            }
            _ => {}
        }
        Ok(vec![])
    }

    fn get(&mut self, interface: &str, property: &str) -> Option<Value> {
        let previewer = self.0.borrow();
        match (interface, property) {
            (PREVIEWER, "Visible") => Some(Value::Bool(previewer.visible)),
            (PREVIEWER, "ParentHandle") => Some(Value::str(previewer.handle.as_str())),
            _ => None,
        }
    }
}

fn interfaces() -> Vec<Interface> {
    vec![
        Interface::new(PREVIEWER)
            .method("ShowFile", "ssbs", "")
            .method("Close", "", "")
            .signal("SelectionEvent", "u")
            .signal("NavigateTo", "s")
            .signal("Rename", "s")
            .signal("Trash", "s")
            .property("ParentHandle", "s")
            .property("Visible", "b"),
        Interface::new(OURS)
            .method("Select", "u", "")
            .method("Closed", "u", ""),
    ]
}

fn run() -> nova_sd::Result<()> {
    let bus = Bus::user()?;
    let idle = std::env::var("NOVA_PREVIEW_IDLE_SECONDS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(30);
    let state = Rc::new(RefCell::new(Previewer {
        bus: bus.clone(),
        visible: false,
        handle: String::new(),
        uri: String::new(),
        seq: 0,
        idle: Duration::from_secs(idle),
        quit_at: Some(Instant::now() + Duration::from_secs(idle)),
        running: Vec::new(),
    }));
    let _object = bus.export(PATH, interfaces(), Object(state.clone()))?;
    // Another one has the name: this one has nothing to do.
    if !bus.request_name(NAME, 0).unwrap_or(false) {
        return Ok(());
    }
    loop {
        bus.dispatch()?;
        let (children, quit_at) = {
            let mut previewer = state.borrow_mut();
            previewer.reap();
            if previewer.quit_at.is_some_and(|at| Instant::now() >= at) && !previewer.visible {
                return Ok(());
            }
            (previewer.descriptors(), previewer.quit_at)
        };
        let mut fds = vec![bus.poll_fd()];
        fds.extend(children.iter().map(|&fd| PollFd::new(fd, POLLIN)));
        let wait = quit_at.map(|at| at.saturating_duration_since(Instant::now()));
        let _ = poll(&mut fds, sooner(bus.timeout(), wait));
    }
}

fn main() {
    if let Err(error) = run() {
        log(&error.to_string());
        std::process::exit(1);
    }
}
