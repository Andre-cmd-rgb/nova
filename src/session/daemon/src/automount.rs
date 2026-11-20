//! Mounts removable drives as they are plugged in, through udisks2, while
//! somebody has unlocked the session.
//!
//! Mounting a drive has the kernel read whatever file system is on it, so a
//! drive plugged into a locked computer waits for an unlock. The lock screen
//! runs `nova-automount on` once somebody has unlocked and `off` while it is
//! locked; that writes and removes $XDG_RUNTIME_DIR/nova/automount, which
//! holds the session it was written in (Hyprland's instance), so that one
//! left by an earlier session never counts.
//!
//! The first time it is on in a session, every removable drive there is is
//! mounted: one plugged in before the login, say. After that only the drives
//! that come are, and those that came while it was off once it is on again;
//! a drive unmounted on purpose stays so. That the first sweep is done is
//! kept in $XDG_RUNTIME_DIR/nova/automount-swept, so that the daemon started
//! again does not sweep a second time.
//!
//! Which drives: those udisks gives a desktop to mount on its own (HintAuto,
//! and not HintSystem: USB, FireWire, memory cards, removable media), and not
//! one marked to be left alone (HintIgnore, as nova-usb marks the stick it
//! is writing). An encrypted one is asked for its passphrase, and what it
//! opens to is mounted. Nothing is said: Files shows the drive.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::Read;
use std::path::PathBuf;
use std::process::Stdio;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use nova_sd::poll::{poll, sooner, PollFd, POLLIN};
use nova_sd::{Bus, Value};

use crate::common::{
    signal, write_atomically, Context, FolderWatch, Waker, IN_CLOSE_WRITE, IN_CREATE, IN_DELETE,
    IN_MOVED_FROM, IN_MOVED_TO, SIGTERM,
};
use crate::say;

pub const DUTY: &str = "automount";
const UDISKS: &str = "org.freedesktop.UDisks2";
const ROOT: &str = "/org/freedesktop/UDisks2";
const OBJECT_MANAGER: &str = "org.freedesktop.DBus.ObjectManager";
pub const BLOCK: &str = "org.freedesktop.UDisks2.Block";
pub const FILESYSTEM: &str = "org.freedesktop.UDisks2.Filesystem";
pub const ENCRYPTED: &str = "org.freedesktop.UDisks2.Encrypted";
pub const PARTITION: &str = "org.freedesktop.UDisks2.Partition";
pub const DRIVE: &str = "org.freedesktop.UDisks2.Drive";

/// udisks's objects: by path, each interface's properties (a{sv}).
pub type Objects = BTreeMap<String, BTreeMap<String, Value>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Mount,
    Unlock,
    Nothing,
}

fn props<'a>(objects: &'a Objects, path: &str, interface: &str) -> Option<&'a Value> {
    objects.get(path)?.get(interface)
}

fn prop<'a>(objects: &'a Objects, path: &str, interface: &str, name: &str) -> Option<&'a Value> {
    props(objects, path, interface)?.get(name)
}

fn flag(objects: &Objects, path: &str, name: &str) -> bool {
    prop(objects, path, BLOCK, name)
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// Another object a property points at; "/" is none.
fn link(objects: &Objects, path: &str, interface: &str, name: &str) -> Option<String> {
    prop(objects, path, interface, name)
        .and_then(Value::as_str)
        .filter(|p| *p != "/")
        .map(str::to_owned)
}

/// Whether the block at <path> is one to mount by itself: neither it nor
/// what it is on is to be left alone, and the drive under it all is one
/// udisks gives a desktop to mount (an unlocked encrypted drive's hints are
/// device-mapper's, which say nothing about the drive, so its own are
/// looked through).
pub fn handled(objects: &Objects, path: &str) -> bool {
    let mut current = path.to_owned();
    // Partition, table, the device an encrypted one opened from: a few steps at most.
    for _ in 0..8 {
        if props(objects, &current, BLOCK).is_none() || flag(objects, &current, "HintIgnore") {
            return false;
        }
        if let Some(backing) = link(objects, &current, BLOCK, "CryptoBackingDevice") {
            current = backing;
            continue;
        }
        if flag(objects, &current, "HintSystem") || !flag(objects, &current, "HintAuto") {
            return false;
        }
        match link(objects, &current, PARTITION, "Table") {
            Some(table) => current = table,
            None => return true,
        }
    }
    false
}

/// What to do with the block at <path>.
pub fn decide(objects: &Objects, path: &str) -> Action {
    if !handled(objects, path) {
        return Action::Nothing;
    }
    if let Some(filesystem) = props(objects, path, FILESYSTEM) {
        let mounted = filesystem
            .get("MountPoints")
            .and_then(Value::as_list)
            .is_some_and(|m| !m.is_empty());
        return if mounted {
            Action::Nothing
        } else {
            Action::Mount
        };
    }
    if props(objects, path, ENCRYPTED).is_some()
        && link(objects, path, ENCRYPTED, "CleartextDevice").is_none()
    {
        return Action::Unlock;
    }
    Action::Nothing
}

/// The device's name, for the journal: /dev/sdb1.
fn device(objects: &Objects, path: &str) -> String {
    ["PreferredDevice", "Device"]
        .iter()
        .find_map(|name| prop(objects, path, BLOCK, name).and_then(Value::as_bytes))
        .map(|bytes| {
            String::from_utf8_lossy(bytes.split(|b| *b == 0).next().unwrap_or_default())
                .into_owned()
        })
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| path.rsplit('/').next().unwrap_or(path).to_owned())
}

/// What a person calls the drive: its label, else its make and model, else its device.
pub fn label(objects: &Objects, path: &str) -> String {
    if let Some(label) = prop(objects, path, BLOCK, "IdLabel")
        .and_then(Value::as_str)
        .filter(|l| !l.trim().is_empty())
    {
        return label.trim().to_owned();
    }
    let drive = link(objects, path, BLOCK, "Drive").or_else(|| {
        link(objects, path, PARTITION, "Table").and_then(|t| link(objects, &t, BLOCK, "Drive"))
    });
    if let Some(drive) = drive {
        let words: Vec<&str> = ["Vendor", "Model"]
            .iter()
            .filter_map(|n| prop(objects, &drive, DRIVE, n).and_then(Value::as_str))
            .map(str::trim)
            .filter(|w| !w.is_empty())
            .collect();
        if !words.is_empty() {
            return words.join(" ");
        }
    }
    device(objects, path)
}

/// Every object udisks has, with its interfaces' properties.
pub fn managed_objects(bus: &Bus) -> Result<Objects, String> {
    let answer = bus
        .call(UDISKS, ROOT, OBJECT_MANAGER, "GetManagedObjects", &[])
        .map_err(|e| format!("udisks did not answer: {e}"))?;
    let mut objects = Objects::new();
    for (path, interfaces) in answer.first().and_then(Value::as_dict).unwrap_or_default() {
        let Some(path) = path.as_str() else { continue };
        let entry = objects.entry(path.to_owned()).or_default();
        for (name, properties) in interfaces.as_dict().unwrap_or_default() {
            if let Some(name) = name.as_str() {
                entry.insert(name.to_owned(), properties.clone());
            }
        }
    }
    Ok(objects)
}

fn no_interaction() -> Value {
    // Plugging a drive in never asks for an administrator's password.
    Value::options(vec![("auth.no_user_interaction", Value::Bool(true))])
}

fn mount(bus: &Bus, objects: &Objects, path: &str) {
    let name = device(objects, path);
    for attempt in 0..2 {
        match bus.call_timeout(
            UDISKS,
            path,
            FILESYSTEM,
            "Mount",
            &[no_interaction()],
            Some(Duration::from_secs(120)),
        ) {
            Ok(answer) => {
                let at = answer.first().and_then(Value::as_str).unwrap_or("?");
                say!(DUTY, "mounted {name} at {at}");
                return;
            }
            // Mounted meanwhile (Files was quicker): nothing to do.
            Err(e) if e.name().is_some_and(|n| n.ends_with(".AlreadyMounted")) => return,
            Err(e)
                if e.name().is_some_and(|n| {
                    n.ends_with(".NotAuthorized") || n.ends_with(".NotAuthorizedCanObtain")
                }) =>
            {
                say!(DUTY, "not allowed to mount {name}: {e}");
                return;
            }
            // What an encrypted drive opens to can need a moment before it mounts.
            Err(e) if attempt == 0 => {
                say!(DUTY, "could not mount {name} yet ({e}); trying again");
                thread::sleep(Duration::from_millis(1500));
            }
            Err(e) => say!(DUTY, "could not mount {name}: {e}"),
        }
    }
}

/// A passphrase being asked for: the asking program, and whether it was
/// called off (the lock came, the drive went).
#[derive(Default)]
struct Prompt {
    pid: Option<u32>,
    called_off: bool,
}

type Prompts = Arc<Mutex<HashMap<String, Arc<Mutex<Prompt>>>>>;

fn call_off(prompts: &Prompts, path: &str) -> bool {
    let Ok(mut all) = prompts.lock() else {
        return false;
    };
    let Some(prompt) = all.remove(path) else {
        return false;
    };
    if let Ok(mut prompt) = prompt.lock() {
        prompt.called_off = true;
        if let Some(pid) = prompt.pid {
            signal(pid, SIGTERM);
        }
    }
    true
}

/// A passphrase typed, for the duty to open the drive with on its own
/// connection; none when the question was cancelled.
struct Answer {
    path: String,
    label: String,
    attempt: u32,
    passphrase: Option<String>,
}

/// Asks for an encrypted drive's passphrase, on a thread of its own, so that
/// the duty goes on meanwhile; the answer comes back to it through <answers>.
fn ask_for_passphrase(
    ctx: &Context,
    prompts: &Prompts,
    answers: &Answers,
    path: &str,
    label: String,
    attempt: u32,
) {
    let prompt = Arc::new(Mutex::new(Prompt::default()));
    {
        let Ok(mut all) = prompts.lock() else { return };
        if all.contains_key(path) {
            return;
        }
        all.insert(path.to_owned(), prompt.clone());
    }
    let (ctx, answers, path) = (ctx.clone(), answers.clone(), path.to_owned());
    let started = thread::Builder::new()
        .name("automount-ask".into())
        .spawn(move || {
            let text = if attempt == 1 {
                format!("“{label}” is encrypted. Type its passphrase to open it.")
            } else {
                format!("That passphrase did not open “{label}”. Type it again.")
            };
            let passphrase = ask(&ctx, &prompt, &text);
            // Called off meanwhile (the lock came, the drive went): nothing to tell.
            if prompt.lock().is_ok_and(|p| p.called_off) {
                return;
            }
            answers.send(Answer {
                path,
                label,
                attempt,
                passphrase,
            });
        });
    if let Err(e) = started {
        say!(DUTY, "could not ask for the passphrase: {e}");
    }
}

/// Where the asking threads hand their answers to the duty, and wake it.
#[derive(Clone)]
struct Answers {
    sender: std::sync::mpsc::Sender<Answer>,
    waker: Arc<Waker>,
}

impl Answers {
    fn send(&self, answer: Answer) {
        if self.sender.send(answer).is_ok() {
            self.waker.wake();
        }
    }
}

/// The passphrase, from a dialog; none when it was cancelled or called off.
fn ask(ctx: &Context, prompt: &Arc<Mutex<Prompt>>, text: &str) -> Option<String> {
    if prompt.lock().ok()?.called_off {
        return None;
    }
    let mut child = ctx
        .command("zenity")
        .args(["--entry", "--hide-text", "--title=Encrypted drive", &format!("--text={text}")])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .inspect_err(|e| say!(DUTY, "no dialog to ask for the passphrase with ({e}); Files asks for it as the drive is opened"))
        .ok()?;
    {
        let mut prompt = prompt.lock().ok()?;
        if prompt.called_off {
            let _ = child.kill();
        }
        prompt.pid = Some(child.id());
    }
    let mut answer = String::new();
    let read = child
        .stdout
        .take()
        .map(|mut out| out.read_to_string(&mut answer));
    let status = child.wait().ok()?;
    if let Ok(mut prompt) = prompt.lock() {
        prompt.pid = None;
        if prompt.called_off {
            return None;
        }
    }
    if !status.success() || !matches!(read, Some(Ok(_))) {
        return None;
    }
    // Only the line's end is the dialog's: a passphrase may end in a space.
    let passphrase = answer.strip_suffix('\n').unwrap_or(&answer).to_owned();
    (!passphrase.is_empty()).then_some(passphrase)
}

/// What a change on the bus was.
#[derive(Debug)]
enum Change {
    Added(String, Vec<String>),
    Removed(String, Vec<String>),
}

struct Automount<'a> {
    ctx: &'a Context,
    bus: &'a Bus,
    on: bool,
    /// Drives that came while it was off, to look at once it is on.
    pending: Vec<String>,
    prompts: Prompts,
    answers: Answers,
}

impl Automount<'_> {
    fn switch(&self) -> PathBuf {
        self.ctx.runtime.join("automount")
    }

    fn swept_marker(&self) -> PathBuf {
        self.ctx.runtime.join("automount-swept")
    }

    /// Whether this session's lock screen has said on.
    fn switched_on(&self) -> bool {
        fs::read_to_string(self.switch()).is_ok_and(|s| s.trim() == self.ctx.session)
    }

    fn swept(&self) -> bool {
        fs::read_to_string(self.swept_marker()).is_ok_and(|s| s.trim() == self.ctx.session)
    }

    fn act(&self, objects: &Objects, path: &str) {
        match decide(objects, path) {
            Action::Mount => mount(self.bus, objects, path),
            Action::Unlock => ask_for_passphrase(
                self.ctx,
                &self.prompts,
                &self.answers,
                path,
                label(objects, path),
                1,
            ),
            Action::Nothing => {}
        }
    }

    /// The first time on in a session: every drive there is.
    fn sweep(&mut self) {
        let objects = match managed_objects(self.bus) {
            Ok(objects) => objects,
            Err(e) => return say!(DUTY, "{e}"),
        };
        for path in objects.keys() {
            self.act(&objects, path);
        }
        self.pending.clear();
        if let Err(e) = write_atomically(&self.swept_marker(), &format!("{}\n", self.ctx.session)) {
            say!(DUTY, "could not keep that the drives were mounted: {e}");
        }
    }

    fn look_at(&self, paths: &[String]) {
        if paths.is_empty() {
            return;
        }
        match managed_objects(self.bus) {
            Ok(objects) => paths.iter().for_each(|p| self.act(&objects, p)),
            Err(e) => say!(DUTY, "{e}"),
        }
    }

    fn turn(&mut self, on: bool) {
        if on == self.on {
            return;
        }
        self.on = on;
        if on {
            if self.swept() {
                let pending = std::mem::take(&mut self.pending);
                self.look_at(&pending);
            } else {
                self.sweep();
            }
        } else {
            // A passphrase asked for under the lock would be asked behind it:
            // the drive waits for the unlock, and is asked for then.
            let asked: Vec<String> = self
                .prompts
                .lock()
                .map(|p| p.keys().cloned().collect())
                .unwrap_or_default();
            for path in asked {
                call_off(&self.prompts, &path);
                if !self.pending.contains(&path) {
                    self.pending.push(path);
                }
            }
        }
    }

    /// Opens an encrypted drive with the passphrase typed; what it opens to
    /// comes as a new block, which is mounted as any other. A wrong
    /// passphrase is asked again, twice.
    fn answered(&mut self, answer: Answer) {
        if let Ok(mut all) = self.prompts.lock() {
            all.remove(&answer.path);
        }
        let Some(passphrase) = answer.passphrase else {
            return;
        };
        if !self.on {
            if !self.pending.contains(&answer.path) {
                self.pending.push(answer.path);
            }
            return;
        }
        let unlocked = self.bus.call_timeout(
            UDISKS,
            &answer.path,
            ENCRYPTED,
            "Unlock",
            &[Value::Str(passphrase), no_interaction()],
            Some(Duration::from_secs(120)),
        );
        let label = answer.label;
        match unlocked {
            Ok(_) => say!(DUTY, "opened {label}"),
            Err(e)
                if e.name().is_some_and(|n| n.ends_with(".Error.Failed")) && answer.attempt < 3 =>
            {
                say!(DUTY, "the passphrase did not open {label}");
                ask_for_passphrase(
                    self.ctx,
                    &self.prompts,
                    &self.answers,
                    &answer.path,
                    label,
                    answer.attempt + 1,
                );
            }
            Err(e) => say!(DUTY, "could not open {label}: {e}"),
        }
    }

    fn changed(&mut self, change: Change) {
        match change {
            Change::Added(path, interfaces) => {
                if !interfaces.iter().any(|i| i == FILESYSTEM || i == ENCRYPTED) {
                    return;
                }
                if self.on {
                    self.look_at(&[path]);
                } else if !self.pending.contains(&path) {
                    self.pending.push(path);
                }
            }
            Change::Removed(path, interfaces) => {
                if interfaces
                    .iter()
                    .any(|i| i == BLOCK || i == FILESYSTEM || i == ENCRYPTED)
                {
                    self.pending.retain(|p| *p != path);
                    call_off(&self.prompts, &path);
                }
            }
        }
    }
}

/// Mounts drives through udisks on <bus> until the bus goes.
pub fn serve(bus: &Bus, ctx: &Context) -> Result<(), String> {
    let runtime = ctx
        .runtime_dir()
        .map_err(|e| format!("no runtime folder: {e}"))?
        .to_owned();
    let changes = Rc::new(RefCell::new(Vec::new()));
    let heard = changes.clone();
    let _changes = bus
        .match_signal(
            Some(UDISKS),
            Some(ROOT),
            Some(OBJECT_MANAGER),
            None,
            move |m| {
                let args = m.args().unwrap_or_default();
                let path = args
                    .first()
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let interfaces: Vec<String> = match m.member() {
                    Some("InterfacesAdded") => args
                        .get(1)
                        .and_then(Value::as_dict)
                        .unwrap_or_default()
                        .iter()
                        .filter_map(|(k, _)| k.as_str().map(str::to_owned))
                        .collect(),
                    _ => args
                        .get(1)
                        .and_then(Value::as_list)
                        .unwrap_or_default()
                        .iter()
                        .filter_map(|v| v.as_str().map(str::to_owned))
                        .collect(),
                };
                heard.borrow_mut().push(match m.member() {
                    Some("InterfacesAdded") => Change::Added(path, interfaces),
                    _ => Change::Removed(path, interfaces),
                });
            },
        )
        .map_err(|e| e.to_string())?;
    let switch = FolderWatch::new(
        &runtime,
        IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE,
    )
    .map_err(|e| format!("cannot watch {}: {e}", runtime.display()))?;
    let waker = Arc::new(Waker::new().map_err(|e| format!("cannot make a waker: {e}"))?);
    let (sender, answered) = std::sync::mpsc::channel();
    let mut automount = Automount {
        ctx,
        bus,
        on: false,
        pending: Vec::new(),
        prompts: Arc::new(Mutex::new(HashMap::new())),
        answers: Answers {
            sender,
            waker: waker.clone(),
        },
    };
    let on = automount.switched_on();
    automount.turn(on);
    let ended = loop {
        let mut fds = [
            bus.poll_fd(),
            PollFd::new(switch.fd(), POLLIN),
            PollFd::new(waker.fd(), POLLIN),
        ];
        if let Err(e) = poll(&mut fds, sooner(bus.timeout(), None)) {
            break format!("could not wait: {e}");
        }
        if fds[1].ready() && switch.names().iter().any(|n| n == "automount") {
            let on = automount.switched_on();
            automount.turn(on);
        }
        if let Err(e) = bus.dispatch() {
            break format!("the system bus went: {e}");
        }
        let waiting: Vec<Change> = changes.borrow_mut().drain(..).collect();
        for change in waiting {
            automount.changed(change);
        }
        if fds[2].ready() {
            waker.drain();
            while let Ok(answer) = answered.try_recv() {
                automount.answered(answer);
            }
        }
    };
    automount.turn(false);
    Err(ended)
}

pub fn run(ctx: &Context) -> Result<(), String> {
    // The switch names the session it is for; with no Hyprland instance to
    // name, no switch can be this session's, and nothing would ever mount.
    if ctx.session.is_empty() {
        say!(DUTY, "not in a Hyprland session: no drives mounted");
        return Ok(());
    }
    let bus = Bus::system().map_err(|e| e.to_string())?;
    serve(&bus, ctx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{calls, context, duty, stub, wait_until, Service};
    use nova_sd::testing::{scratch, PrivateBus};
    use nova_sd::{Interface, Message, Slot};
    use std::any::Any;
    use std::path::Path;

    const DEV: &str = "/org/freedesktop/UDisks2/block_devices/";

    fn bytes(text: &str) -> Value {
        let mut b: Vec<Value> = text.bytes().map(Value::Byte).collect();
        b.push(Value::Byte(0));
        Value::Array("y".into(), b)
    }

    /// A block's interfaces: <hints> is "system", "auto" or "ignored" words;
    /// <on> a partition table or the device it was opened from.
    fn block(
        name: &str,
        hints: &str,
        table: Option<&str>,
        backing: Option<&str>,
    ) -> BTreeMap<String, Value> {
        let mut interfaces = BTreeMap::new();
        interfaces.insert(
            BLOCK.to_owned(),
            Value::options(vec![
                ("Device", bytes(&format!("/dev/{name}"))),
                ("HintSystem", Value::Bool(hints.contains("system"))),
                ("HintAuto", Value::Bool(hints.contains("auto"))),
                ("HintIgnore", Value::Bool(hints.contains("ignored"))),
                (
                    "IdLabel",
                    Value::str(if name == "sde1" { "Backup" } else { "" }),
                ),
                (
                    "CryptoBackingDevice",
                    Value::path(backing.map_or("/".into(), |b| format!("{DEV}{b}"))),
                ),
                ("Drive", Value::path("/")),
            ]),
        );
        if let Some(table) = table {
            interfaces.insert(
                PARTITION.to_owned(),
                Value::options(vec![("Table", Value::path(format!("{DEV}{table}")))]),
            );
        }
        interfaces
    }

    fn with_filesystem(
        mut interfaces: BTreeMap<String, Value>,
        mounted: bool,
    ) -> BTreeMap<String, Value> {
        let points = if mounted {
            vec![bytes("/run/media/x")]
        } else {
            vec![]
        };
        interfaces.insert(
            FILESYSTEM.to_owned(),
            Value::options(vec![("MountPoints", Value::Array("ay".into(), points))]),
        );
        interfaces
    }

    fn encrypted(
        mut interfaces: BTreeMap<String, Value>,
        cleartext: Option<&str>,
    ) -> BTreeMap<String, Value> {
        let cleartext = cleartext.map_or("/".into(), |c| format!("{DEV}{c}"));
        interfaces.insert(
            ENCRYPTED.to_owned(),
            Value::options(vec![("CleartextDevice", Value::path(cleartext))]),
        );
        interfaces
    }

    fn usb_stick() -> Objects {
        let mut objects = Objects::new();
        objects.insert(format!("{DEV}sdb"), block("sdb", "auto", None, None));
        objects.insert(
            format!("{DEV}sdb1"),
            with_filesystem(block("sdb1", "auto", Some("sdb"), None), false),
        );
        objects.insert(
            format!("{DEV}nvme0n1"),
            block("nvme0n1", "system", None, None),
        );
        objects.insert(
            format!("{DEV}nvme0n1p2"),
            with_filesystem(block("nvme0n1p2", "system", Some("nvme0n1"), None), false),
        );
        objects
    }

    #[test]
    fn a_removable_drives_file_system_is_mounted_and_the_computers_own_are_not() {
        let mut objects = usb_stick();
        assert_eq!(decide(&objects, &format!("{DEV}sdb1")), Action::Mount);
        assert_eq!(decide(&objects, &format!("{DEV}sdb")), Action::Nothing);
        assert_eq!(
            decide(&objects, &format!("{DEV}nvme0n1p2")),
            Action::Nothing
        );
        assert_eq!(decide(&objects, &format!("{DEV}gone")), Action::Nothing);
        // One mounted already, by Files or by hand, is left as it is.
        objects.insert(
            format!("{DEV}sdb1"),
            with_filesystem(block("sdb1", "auto", Some("sdb"), None), true),
        );
        assert_eq!(decide(&objects, &format!("{DEV}sdb1")), Action::Nothing);
        // A drive udisks leaves to the user (UDISKS_AUTO=0) waits for Files.
        objects.insert(
            format!("{DEV}sdc1"),
            with_filesystem(block("sdc1", "", None, None), false),
        );
        assert_eq!(decide(&objects, &format!("{DEV}sdc1")), Action::Nothing);
    }

    #[test]
    fn what_nova_usb_marks_to_be_left_alone_is_never_mounted_nor_asked_for() {
        let mut objects = Objects::new();
        // udev marks the disk, its partitions and what they open to.
        objects.insert(
            format!("{DEV}sdd"),
            block("sdd", "auto ignored", None, None),
        );
        objects.insert(
            format!("{DEV}sdd1"),
            with_filesystem(block("sdd1", "auto", Some("sdd"), None), false),
        );
        objects.insert(
            format!("{DEV}sdd2"),
            encrypted(block("sdd2", "auto ignored", Some("sdd"), None), None),
        );
        objects.insert(
            format!("{DEV}dm_2d1"),
            with_filesystem(block("dm-1", "system ignored", None, Some("sdd2")), false),
        );
        for name in ["sdd1", "sdd2", "dm_2d1"] {
            assert_eq!(
                decide(&objects, &format!("{DEV}{name}")),
                Action::Nothing,
                "{name}"
            );
        }
    }

    #[test]
    fn an_encrypted_drive_is_asked_for_and_what_it_opens_to_is_mounted() {
        let mut objects = Objects::new();
        objects.insert(format!("{DEV}sde"), block("sde", "auto", None, None));
        objects.insert(
            format!("{DEV}sde1"),
            encrypted(block("sde1", "auto", Some("sde"), None), None),
        );
        assert_eq!(decide(&objects, &format!("{DEV}sde1")), Action::Unlock);
        assert_eq!(label(&objects, &format!("{DEV}sde1")), "Backup");
        // Opened: what it opened to has device-mapper's hints, and is the drive's.
        objects.insert(
            format!("{DEV}sde1"),
            encrypted(block("sde1", "auto", Some("sde"), None), Some("dm_2d0")),
        );
        objects.insert(
            format!("{DEV}dm_2d0"),
            with_filesystem(block("dm-0", "system", None, Some("sde1")), false),
        );
        assert_eq!(decide(&objects, &format!("{DEV}sde1")), Action::Nothing);
        assert_eq!(decide(&objects, &format!("{DEV}dm_2d0")), Action::Mount);
        // The computer's own encrypted disk, opened at boot, is not.
        objects.insert(
            format!("{DEV}nvme0n1p3"),
            encrypted(block("nvme0n1p3", "system", None, None), Some("dm_2d9")),
        );
        objects.insert(
            format!("{DEV}dm_2d9"),
            with_filesystem(block("dm-9", "system", None, Some("nvme0n1p3")), false),
        );
        assert_eq!(decide(&objects, &format!("{DEV}dm_2d9")), Action::Nothing);
        assert_eq!(label(&objects, &format!("{DEV}dm_2d9")), "/dev/dm-9");
    }

    /// udisks on the private bus, as far as this needs it: its objects,
    /// Mount, Unlock with "right" as the passphrase, and errands that add and
    /// take away drives as plugging them in would.
    struct Udisks {
        objects: Rc<RefCell<Objects>>,
        slots: Rc<RefCell<Vec<Slot>>>,
        mounted: Arc<Mutex<Vec<String>>>,
        tried: Arc<Mutex<Vec<String>>>,
    }

    fn export(bus: &Bus, udisks: &Udisks, path: &str) {
        let interfaces: Vec<Interface> = udisks.objects.borrow()[path]
            .keys()
            .map(|name| match name.as_str() {
                FILESYSTEM => Interface::new(FILESYSTEM).method("Mount", "a{sv}", "s"),
                ENCRYPTED => Interface::new(ENCRYPTED).method("Unlock", "sa{sv}", "o"),
                other => Interface::new(other),
            })
            .collect();
        let (objects, slots, mounted, tried) = (
            udisks.objects.clone(),
            udisks.slots.clone(),
            udisks.mounted.clone(),
            udisks.tried.clone(),
        );
        let me = path.to_owned();
        let slot = bus
            .export(
                path,
                interfaces,
                move |call: &Message, args: Vec<Value>| match call.member() {
                    Some("Mount") => {
                        assert_eq!(
                            args[0]
                                .get("auth.no_user_interaction")
                                .and_then(Value::as_bool),
                            Some(true)
                        );
                        mounted
                            .lock()
                            .unwrap()
                            .push(me.rsplit('/').next().unwrap().to_owned());
                        let fs = objects.borrow_mut().get_mut(&me).unwrap().insert(
                            FILESYSTEM.into(),
                            Value::options(vec![(
                                "MountPoints",
                                Value::Array("ay".into(), vec![bytes("/run/media/x")]),
                            )]),
                        );
                        drop(fs);
                        Ok(vec![Value::str("/run/media/x")])
                    }
                    Some("Unlock") => {
                        let passphrase = args[0].as_str().unwrap().to_owned();
                        tried.lock().unwrap().push(passphrase.clone());
                        if passphrase != "right" {
                            return Err(nova_sd::Error::bus(
                                "org.freedesktop.UDisks2.Error.Failed",
                                "wrong passphrase",
                            ));
                        }
                        let name = me.rsplit('/').next().unwrap();
                        let cleartext = format!("{DEV}dm_2d0");
                        objects.borrow_mut().insert(
                            me.clone(),
                            encrypted(block(name, "auto", Some("sde"), None), Some("dm_2d0")),
                        );
                        objects.borrow_mut().insert(
                            cleartext.clone(),
                            with_filesystem(block("dm-0", "system", None, Some(name)), false),
                        );
                        let udisks = Udisks {
                            objects: objects.clone(),
                            slots: slots.clone(),
                            mounted: mounted.clone(),
                            tried: tried.clone(),
                        };
                        plug(&call.bus(), &udisks, &cleartext);
                        Ok(vec![Value::path(cleartext)])
                    }
                    _ => Ok(vec![]),
                },
            )
            .unwrap();
        udisks.slots.borrow_mut().push(slot);
    }

    /// Puts <path> on the bus and says so, as udisks does when a drive comes.
    fn plug(bus: &Bus, udisks: &Udisks, path: &str) {
        export(bus, udisks, path);
        let interfaces = udisks.objects.borrow()[path].clone();
        let added = Value::Dict(
            "s".into(),
            "a{sv}".into(),
            interfaces
                .into_iter()
                .map(|(k, v)| (Value::str(k), v))
                .collect(),
        );
        bus.emit_signal(
            ROOT,
            OBJECT_MANAGER,
            "InterfacesAdded",
            &[Value::path(path), added],
        )
        .unwrap();
    }

    /// What the mock udisks was asked: the drives it mounted, the passphrases tried.
    type Log = Arc<Mutex<Vec<String>>>;

    fn udisks(address: &str, start: Objects) -> (Service, Log, Log) {
        let mounted = Arc::new(Mutex::new(Vec::new()));
        let tried = Arc::new(Mutex::new(Vec::new()));
        let (m, t) = (mounted.clone(), tried.clone());
        let service = Service::start(address, move |bus| {
            let udisks = Udisks {
                objects: Rc::new(RefCell::new(start)),
                slots: Rc::default(),
                mounted: m,
                tried: t,
            };
            let objects = udisks.objects.clone();
            let manager = bus
                .export(
                    ROOT,
                    vec![Interface::new(OBJECT_MANAGER).method(
                        "GetManagedObjects",
                        "",
                        "a{oa{sa{sv}}}",
                    )],
                    move |_: &Message, _| {
                        let all = objects
                            .borrow()
                            .iter()
                            .map(|(path, interfaces)| {
                                let interfaces = interfaces
                                    .iter()
                                    .map(|(k, v)| (Value::str(k), v.clone()))
                                    .collect();
                                (
                                    Value::path(path),
                                    Value::Dict("s".into(), "a{sv}".into(), interfaces),
                                )
                            })
                            .collect();
                        Ok(vec![Value::Dict("o".into(), "a{sa{sv}}".into(), all)])
                    },
                )
                .unwrap();
            let paths: Vec<String> = udisks.objects.borrow().keys().cloned().collect();
            for path in paths {
                export(bus, &udisks, &path);
            }
            assert!(bus.request_name(UDISKS, 0).unwrap());
            Box::new((udisks, manager)) as Box<dyn Any>
        });
        (service, mounted, tried)
    }

    /// Plugs a drive in: <interfaces> at <name>.
    fn plug_in(service: &Service, name: &str, interfaces: BTreeMap<String, Value>) {
        let path = format!("{DEV}{name}");
        service.send(move |bus, state| {
            let (udisks, _) = state.downcast_mut::<(Udisks, Slot)>().unwrap();
            udisks.objects.borrow_mut().insert(path.clone(), interfaces);
            plug(bus, udisks, &path);
        });
    }

    /// Unmounts a drive behind the daemon's back, as a person does in Files.
    fn unmount(service: &Service, name: &str) {
        let path = format!("{DEV}{name}");
        service.send(move |_, state| {
            let (udisks, _) = state.downcast_mut::<(Udisks, Slot)>().unwrap();
            let fs = udisks.objects.borrow_mut().get_mut(&path).unwrap().insert(
                FILESYSTEM.into(),
                Value::options(vec![("MountPoints", Value::Array("ay".into(), vec![]))]),
            );
            drop(fs);
        });
    }

    /// As the lock screen does: `nova-automount on` or `off` itself, so that
    /// what it writes and what the duty reads cannot drift apart.
    fn switch(ctx: &Context, on: bool) {
        let helper = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../cli/bin/nova-automount");
        // The script asks the user manager whether an older automounter runs,
        // and would freeze the real one: a systemctl that says none does.
        let bin = ctx.runtime.parent().unwrap().join("stub-bin");
        std::fs::create_dir_all(&bin).unwrap();
        let stub = bin.join("systemctl");
        std::fs::write(&stub, "#!/bin/sh\nexit 3\n").unwrap();
        std::fs::set_permissions(&stub, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let status = std::process::Command::new(helper)
            .arg(if on { "on" } else { "off" })
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env("XDG_RUNTIME_DIR", ctx.runtime.parent().unwrap())
            .env("HYPRLAND_INSTANCE_SIGNATURE", &ctx.session)
            .stdin(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "nova-automount failed");
    }

    fn settle() {
        thread::sleep(Duration::from_millis(150));
    }

    fn zenity(dir: &Path) {
        stub(
            dir,
            "zenity",
            &format!(
                "n=$(cat '{0}/asked' 2>/dev/null || echo 0); echo $((n + 1)) >'{0}/asked'
if ((n == 0)); then echo wrong; else echo right; fi",
                dir.display()
            ),
        );
    }

    #[test]
    fn drives_mount_only_while_unlocked_the_first_unlock_mounts_all_and_one_unmounted_on_purpose_stays_so(
    ) {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("automount");
        let ctx = context(&dir);
        zenity(&dir);
        let (udisks, mounted, tried) = udisks(&private.address, usb_stick());
        let _duty = duty(&private.address, &ctx, serve);
        settle();
        // Under the lock, before the first unlock: nothing.
        assert!(mounted.lock().unwrap().is_empty());
        switch(&ctx, true);
        wait_until("the stick", || *mounted.lock().unwrap() == ["sdb1"]);
        assert!(ctx.runtime.join("automount-swept").exists());

        // Unmounted on purpose, it stays so across a lock and an unlock.
        unmount(&udisks, "sdb1");
        switch(&ctx, false);
        settle();
        switch(&ctx, true);
        settle();
        assert_eq!(*mounted.lock().unwrap(), ["sdb1"]);

        // Plugged in under the lock, it waits for the unlock.
        switch(&ctx, false);
        settle();
        plug_in(&udisks, "sdc", block("sdc", "auto", None, None));
        plug_in(
            &udisks,
            "sdc1",
            with_filesystem(block("sdc1", "auto", Some("sdc"), None), false),
        );
        settle();
        assert_eq!(*mounted.lock().unwrap(), ["sdb1"]);
        switch(&ctx, true);
        wait_until("the drive plugged in under the lock", || {
            *mounted.lock().unwrap() == ["sdb1", "sdc1"]
        });

        // Unlocked: one marked to be left alone is, and an encrypted one is
        // asked for, again after a wrong passphrase, and opened and mounted.
        plug_in(&udisks, "sdd", block("sdd", "auto ignored", None, None));
        plug_in(
            &udisks,
            "sdd1",
            with_filesystem(block("sdd1", "auto", Some("sdd"), None), false),
        );
        plug_in(&udisks, "sde", block("sde", "auto", None, None));
        plug_in(
            &udisks,
            "sde1",
            encrypted(block("sde1", "auto", Some("sde"), None), None),
        );
        wait_until("what the encrypted drive opened to", || {
            *mounted.lock().unwrap() == ["sdb1", "sdc1", "dm_2d0"]
        });
        assert_eq!(*tried.lock().unwrap(), ["wrong", "right"]);
        let asked: Vec<String> = calls(&dir)
            .into_iter()
            .filter(|c| c.starts_with("zenity"))
            .collect();
        assert_eq!(asked.len(), 2);
        assert!(asked[0].contains("“Backup” is encrypted"), "{}", asked[0]);
        assert!(
            asked[1].contains("That passphrase did not open “Backup”"),
            "{}",
            asked[1]
        );
    }

    #[test]
    fn started_again_in_the_same_session_it_does_not_sweep_again() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("automount");
        let ctx = context(&dir);
        switch(&ctx, true);
        write_atomically(&ctx.runtime.join("automount-swept"), "test-session\n").unwrap();
        let (_udisks, mounted, _) = udisks(&private.address, usb_stick());
        let _duty = duty(&private.address, &ctx, serve);
        settle();
        assert!(mounted.lock().unwrap().is_empty());
    }

    #[test]
    fn a_switch_or_a_sweep_left_by_another_session_counts_for_nothing() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("automount");
        let mut ctx = context(&dir);
        ctx.session = "this-session".into();
        write_atomically(&ctx.runtime.join("automount"), "an-earlier-session\n").unwrap();
        write_atomically(&ctx.runtime.join("automount-swept"), "an-earlier-session\n").unwrap();
        let (_udisks, mounted, _) = udisks(&private.address, usb_stick());
        let _duty = duty(&private.address, &ctx, serve);
        settle();
        assert!(mounted.lock().unwrap().is_empty());
        // This session's unlock sweeps, the earlier one's marker notwithstanding.
        switch(&ctx, true);
        wait_until("the stick", || *mounted.lock().unwrap() == ["sdb1"]);
    }

    #[test]
    fn a_passphrase_asked_for_as_the_lock_comes_is_asked_again_after_the_unlock() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("automount");
        let ctx = context(&dir);
        stub(&dir, "zenity", "exec sleep 5");
        let mut objects = Objects::new();
        objects.insert(format!("{DEV}sde"), block("sde", "auto", None, None));
        objects.insert(
            format!("{DEV}sde1"),
            encrypted(block("sde1", "auto", Some("sde"), None), None),
        );
        let (_udisks, _, tried) = udisks(&private.address, objects);
        switch(&ctx, true);
        let _duty = duty(&private.address, &ctx, serve);
        wait_until("the question", || calls(&dir).len() == 1);
        switch(&ctx, false);
        settle();
        switch(&ctx, true);
        wait_until("the question again", || calls(&dir).len() == 2);
        assert!(tried.lock().unwrap().is_empty());
    }
}
