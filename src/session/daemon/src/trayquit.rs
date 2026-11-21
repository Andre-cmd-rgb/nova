//! nova-tray-quit check|quit <id> [<title>]: the Quit row of a tray icon's
//! menu (the bar's TrayMenu). `quit` ends the app behind the icon for good,
//! every process of it, as a tray icon's Quit does on Windows; `check` says
//! whether it would, and prints the app's name to say it by (an empty line
//! for none), ending nothing. Either refuses with the reason on stderr and
//! exit status 1, and then the menu offers no Quit.
//!
//! The icon is a StatusNotifierItem on the session bus, which the shell
//! knows by its Id and Title alone: the watcher (Quickshell) lists every
//! item's bus name, the one whose Id fits (and Title, when two share the Id)
//! is the icon's, and its connection's process (GetConnectionUnixProcessID)
//! and that process's cgroup say what holds the app:
//!
//! - The app's own unit: a scope or service in app.slice named for an app,
//!   as systemd's desktop integration names them (nova-launch's
//!   app-Hyprland-<id>-<random>.scope, an autostart entry's
//!   app-<id>@autostart.service, a Flatpak's app-flatpak-<id>-<n>.scope), or
//!   one D-Bus started for a name that has a desktop entry; with no terminal
//!   above the icon's process and none beside it in the unit. The unit is
//!   stopped (systemd sends SIGTERM to every process in it), and what is left
//!   after GRACE is killed.
//! - The app's own processes, in a unit that holds more: started from a
//!   terminal (a session with a controlling terminal above the icon's
//!   process), or beside one, or by Hyprland's exec, or as a helper a
//!   service let go of. The process its tree starts at (below the terminal's
//!   shell) and every process under it in the unit get SIGTERM, and SIGKILL
//!   after GRACE: the terminal, its shell and the rest of the unit stay.
//! - Nothing, when that tree is the unit's own (a service the user enabled,
//!   Nova's, a portal: it owns an icon for something it does for the whole
//!   session), when the process runs outside the user's service manager (a
//!   system service, the login session's scope) or is not the user's, when
//!   two apps answer to the icon's Id and Title, or when what would end holds
//!   this program's own parents (the shell itself, the compositor, the
//!   session).

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::ffi::c_void;
use std::fs;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, PollFd, POLLIN};
use nova_sd::{Bus, Error, Value};

use crate::crash;

const WATCHER: &str = "org.kde.StatusNotifierWatcher";
const WATCHER_PATH: &str = "/StatusNotifierWatcher";
const ITEM: &str = "org.kde.StatusNotifierItem";
const ITEM_PATH: &str = "/StatusNotifierItem";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
const DBUS: &str = "org.freedesktop.DBus";
const DBUS_PATH: &str = "/org/freedesktop/DBus";
const SYSTEMD: &str = "org.freedesktop.systemd1";
const SYSTEMD_PATH: &str = "/org/freedesktop/systemd1";
const MANAGER: &str = "org.freedesktop.systemd1.Manager";
const NO_SUCH_UNIT: &str = "org.freedesktop.systemd1.NoSuchUnit";

/// How long an app has to end once asked: systemd's own TimeoutStopSec for
/// the apps it starts from autostart entries. Long enough for an app to save
/// and close its files, short enough that Quit means quit.
pub const GRACE: Duration = Duration::from_secs(5);
/// How long what was killed has to be gone.
const AFTER_KILL: Duration = Duration::from_secs(2);
/// How long an item or the bus has to answer: a hung app keeps no one
/// waiting long.
const ASK: Duration = Duration::from_secs(1);

const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;

extern "C" {
    fn getuid() -> u32;
    fn pidfd_open(pid: i32, flags: u32) -> i32;
    fn pidfd_send_signal(pidfd: i32, signal: i32, info: *mut c_void, flags: u32) -> i32;
}

/// A process, as /proc has it.
#[derive(Debug, Clone)]
pub struct Proc {
    pub pid: u32,
    pub ppid: u32,
    pub session: u32,
    /// The controlling terminal's device, 0 for none.
    pub tty: u64,
    /// When it started, in clock ticks after boot: with the pid, which
    /// process it is.
    pub start: u64,
    pub uid: u32,
    /// Its cgroup (v2), from the root: /user.slice/…/app-….scope.
    pub cgroup: String,
}

/// Every process under a /proc (or a stand-in), by pid.
pub struct Procs {
    root: PathBuf,
    by_pid: HashMap<u32, Proc>,
}

impl Procs {
    pub fn read(root: &Path) -> Procs {
        let by_pid = fs::read_dir(root)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| e.file_name().to_str()?.parse::<u32>().ok())
            .filter_map(|pid| Some((pid, read_proc(root, pid)?)))
            .collect();
        Procs {
            root: root.to_owned(),
            by_pid,
        }
    }

    pub fn get(&self, pid: u32) -> Option<&Proc> {
        self.by_pid.get(&pid)
    }

    /// <pid> and every process it descends from, as far as /proc goes.
    pub fn ancestry(&self, pid: u32) -> Vec<u32> {
        let mut out = vec![pid];
        let mut at = pid;
        while let Some(parent) = self.get(at).map(|p| p.ppid).filter(|p| *p != 0) {
            if out.contains(&parent) {
                break;
            }
            out.push(parent);
            at = parent;
        }
        out
    }

    /// The processes in the cgroup at <path> and in those under it.
    fn in_cgroup(&self, path: &str) -> Vec<&Proc> {
        let below = format!("{path}/");
        let mut out: Vec<&Proc> = self
            .by_pid
            .values()
            .filter(|p| p.cgroup == path || p.cgroup.starts_with(&below))
            .collect();
        out.sort_by_key(|p| p.pid);
        out
    }

    /// <root> and every process under it, among <among>.
    fn tree(&self, root: u32, among: &[&Proc]) -> Vec<u32> {
        let mut out = vec![root];
        let mut i = 0;
        while i < out.len() {
            let parent = out[i];
            for p in among {
                if p.ppid == parent && !out.contains(&p.pid) {
                    out.push(p.pid);
                }
            }
            i += 1;
        }
        out
    }

    /// The name a process was started by: its command's file name, or else
    /// the kernel's short name for it.
    fn command(&self, pid: u32) -> Option<String> {
        let dir = self.root.join(pid.to_string());
        let line = fs::read(dir.join("cmdline")).unwrap_or_default();
        let first = line.split(|b| *b == 0).next().unwrap_or_default();
        let name = String::from_utf8_lossy(first);
        let name = name.rsplit('/').next().unwrap_or_default().trim();
        if !name.is_empty() {
            return Some(name.to_owned());
        }
        let comm = fs::read_to_string(dir.join("comm")).ok()?;
        Some(comm.trim().to_owned()).filter(|c| !c.is_empty())
    }
}

/// <pid>'s stat, status and cgroup under <root>.
fn read_proc(root: &Path, pid: u32) -> Option<Proc> {
    let dir = root.join(pid.to_string());
    let stat = fs::read_to_string(dir.join("stat")).ok()?;
    // After the name, which may hold spaces and brackets: field 3 on.
    let fields: Vec<&str> = stat
        .get(stat.rfind(')')? + 1..)?
        .split_whitespace()
        .collect();
    let field = |n: usize| fields.get(n - 3)?.parse::<u64>().ok();
    let status = fs::read_to_string(dir.join("status")).ok()?;
    let uid = status
        .lines()
        .find_map(|l| l.strip_prefix("Uid:"))?
        .split_whitespace()
        .next()?
        .parse()
        .ok()?;
    let cgroup = fs::read_to_string(dir.join("cgroup")).ok()?;
    let cgroup = cgroup
        .lines()
        .find_map(|l| l.strip_prefix("0::"))?
        .to_owned();
    Some(Proc {
        pid,
        ppid: field(4)? as u32,
        session: field(6)? as u32,
        tty: field(7)?,
        start: field(22)?,
        uid,
        cgroup,
    })
}

/// Where a cgroup is under the user's service manager: the slices it is in,
/// outermost first, the unit, and the unit's own cgroup.
#[derive(Debug, PartialEq)]
struct Place {
    slices: Vec<String>,
    unit: String,
    path: String,
}

fn place(cgroup: &str, uid: u32) -> Option<Place> {
    let manager = format!("/user.slice/user-{uid}.slice/user@{uid}.service");
    let rest = cgroup.strip_prefix(&manager)?.strip_prefix('/')?;
    let mut path = manager;
    let mut slices = Vec::new();
    for part in rest.split('/') {
        path.push('/');
        path.push_str(part);
        if part.ends_with(".slice") {
            slices.push(part.to_owned());
        } else if part.ends_with(".scope") || part.ends_with(".service") {
            return Some(Place {
                slices,
                unit: part.to_owned(),
                path,
            });
        } else {
            return None;
        }
    }
    None
}

/// A unit name's \xNN escapes as the bytes they stand for.
fn unescape(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && bytes.get(i + 1) == Some(&b'x') && i + 4 <= bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&text[i + 2..i + 4], 16) {
                out.push(byte);
                i += 4;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The app a unit is for, when its name and place say the unit is an app's
/// own: in app.slice, named as systemd's desktop integration names an app's
/// scope (app[-<launcher>]-<id>-<random>.scope) or service
/// (app[-<launcher>]-<id>[@<random>].service), or one dbus-broker started
/// (dbus-:<bus>-<name>@<n>.service) for a name with a desktop entry.
fn app_of(place: &Place, folders: &[PathBuf]) -> Option<String> {
    if place.slices.first().map(String::as_str) != Some("app.slice") {
        return None;
    }
    let unit = place.unit.as_str();
    let id = if let Some(base) = unit.strip_suffix(".scope") {
        let parts: Vec<&str> = base.split('-').collect();
        if parts.len() < 3 || parts[0] != "app" {
            return None;
        }
        // The last part is the random one; a launcher comes first when
        // there are more than three.
        if parts.len() == 3 {
            parts[1].to_owned()
        } else {
            parts[2..parts.len() - 1].join("-")
        }
    } else {
        let base = unit.strip_suffix(".service")?;
        if let Some(rest) = base.strip_prefix("dbus-:") {
            let name = rest.split('@').next().unwrap_or_default();
            let id = unescape(name.split_once('-')?.1);
            let listed = folders
                .iter()
                .any(|f| f.join(format!("{id}.desktop")).is_file());
            return listed.then_some(id);
        }
        let name = base.strip_prefix("app-")?;
        let name = name.split('@').next().unwrap_or_default();
        let parts: Vec<&str> = name.split('-').collect();
        if parts.len() == 1 {
            parts[0].to_owned()
        } else {
            parts[1..].join("-")
        }
    };
    let id = unescape(&id);
    (!id.is_empty()).then_some(id)
}

/// What Quit ends of an icon's app.
#[derive(Debug, PartialEq)]
pub enum Plan {
    /// The app's own unit, every process in it; and the app it is for.
    Unit { unit: String, app: String },
    /// The app's own processes, the first the one its tree starts at, each
    /// with its start time, in a unit that holds more.
    Tree { pids: Vec<(u32, u64)> },
}

/// What Quit would end of the app whose icon is <pid>'s, for the user <uid>,
/// never one of <guarded> (this program and its parents); <folders> hold the
/// desktop entries. The error says why it ends nothing.
pub fn plan(
    procs: &Procs,
    pid: u32,
    uid: u32,
    guarded: &[u32],
    folders: &[PathBuf],
) -> Result<Plan, String> {
    let p = procs.get(pid).ok_or("the app has quit already")?;
    if p.uid != uid {
        return Err("the icon belongs to a program that is not yours".into());
    }
    let place = place(&p.cgroup, uid)
        .ok_or("the icon belongs to a program outside your session's service manager")?;
    if place.slices.is_empty() {
        return Err("the icon belongs to the service manager itself".into());
    }
    let members = procs.in_cgroup(&place.path);
    let inside: HashSet<u32> = members.iter().map(|m| m.pid).collect();
    let mut chain = vec![p];
    while let Some(parent) = procs
        .get(chain[chain.len() - 1].ppid)
        .filter(|q| inside.contains(&q.pid) && !chain.iter().any(|c| c.pid == q.pid))
    {
        chain.push(parent);
    }
    let top = chain[chain.len() - 1];
    let leads_terminal = |q: &Proc| q.tty != 0 && q.session == q.pid;
    // A terminal above the icon's process: its tree starts below the shell.
    let above = chain.iter().position(|q| leads_terminal(q));
    let own: HashSet<u32> = procs.tree(top.pid, &members).into_iter().collect();
    // Or a terminal beside it in the unit, the unit being the terminal's.
    let beside = members
        .iter()
        .any(|q| !own.contains(&q.pid) && leads_terminal(q));
    let app = app_of(&place, folders);
    let plan = match (&app, above) {
        (Some(app), None) if !beside => Plan::Unit {
            unit: place.unit.clone(),
            app: app.clone(),
        },
        _ => {
            let root = match above {
                Some(0) => chain[0],
                Some(i) => chain[i - 1],
                None => top,
            };
            let first = members
                .iter()
                .min_by_key(|m| (m.start, m.pid))
                .expect("the process itself is in its unit");
            let pids = procs.tree(root.pid, &members);
            if pids.contains(&first.pid) {
                return Err(format!(
                    "the icon belongs to {}, which is not an app",
                    unescape(&place.unit)
                ));
            }
            Plan::Tree {
                pids: pids
                    .into_iter()
                    .filter_map(|q| procs.get(q).map(|p| (q, p.start)))
                    .collect(),
            }
        }
    };
    let ending: Vec<u32> = match &plan {
        Plan::Unit { .. } => members.iter().map(|m| m.pid).collect(),
        Plan::Tree { pids } => pids.iter().map(|(q, _)| *q).collect(),
    };
    if ending.iter().any(|q| guarded.contains(q)) {
        return Err("the icon belongs to the shell or the session itself".into());
    }
    Ok(plan)
}

/// The desktop entries' folders: the apps', the user's first, and the
/// autostart entries', where an app started at login has its.
pub fn entry_folders() -> Vec<PathBuf> {
    let mut folders = crash::entry_folders_from_env();
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|c| !c.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".config"));
    let dirs = std::env::var("XDG_CONFIG_DIRS")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "/etc/xdg".into());
    folders.push(config.join("autostart"));
    folders.extend(
        dirs.split(':')
            .filter(|d| !d.is_empty())
            .map(|d| Path::new(d).join("autostart")),
    );
    folders
}

/// The name to say Quit by: the Name of the app's desktop entry, found by the
/// unit's app or the command the app's tree starts at; none without one.
pub fn name_of(plan: &Plan, procs: &Procs, folders: &[PathBuf]) -> Option<String> {
    let id = match plan {
        Plan::Unit { app, .. } => app.clone(),
        Plan::Tree { pids } => procs.command(pids.first()?.0)?,
    };
    let exact = folders
        .iter()
        .map(|f| f.join(format!("{id}.desktop")))
        .find(|f| f.is_file());
    let file = exact.or_else(|| crash::entry_of(&id, folders))?;
    crash::entry_value(&file, "Name")
        .map(|n| n.trim().to_owned())
        .filter(|n| !n.is_empty())
}

/// A call that gives up after ASK.
fn ask(
    bus: &Bus,
    to: &str,
    path: &str,
    iface: &str,
    member: &str,
    args: &[Value],
) -> nova_sd::Result<Vec<Value>> {
    bus.call_timeout(to, path, iface, member, args, Some(ASK))
}

/// The bus names of the items that are the icon whose Id is <id>: those
/// with its Title too, when more than one has the Id and some the Title.
pub fn items(bus: &Bus, id: &str, title: &str) -> Result<Vec<String>, String> {
    let answer = ask(
        bus,
        WATCHER,
        WATCHER_PATH,
        PROPERTIES,
        "Get",
        &[
            Value::str(WATCHER),
            Value::str("RegisteredStatusNotifierItems"),
        ],
    )
    .map_err(|e| format!("no tray to ask for the icon: {e}"))?;
    let listed: Vec<String> = answer
        .first()
        .and_then(|v| v.as_list())
        .unwrap_or_default()
        .iter()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect();
    let mut found: Vec<(String, String)> = Vec::new();
    for entry in listed {
        let (service, path) = match entry.find('/') {
            Some(at) => (entry[..at].to_owned(), entry[at..].to_owned()),
            None => (entry.clone(), ITEM_PATH.to_owned()),
        };
        let Ok(all) = ask(
            bus,
            &service,
            &path,
            PROPERTIES,
            "GetAll",
            &[Value::str(ITEM)],
        ) else {
            continue;
        };
        let Some(properties) = all.first() else {
            continue;
        };
        let text = |key: &str| {
            properties
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        if text("Id") == id {
            found.push((service, text("Title")));
        }
    }
    if found.len() > 1 && !title.is_empty() && found.iter().any(|(_, t)| t == title) {
        found.retain(|(_, t)| t == title);
    }
    let mut services: Vec<String> = found.into_iter().map(|(s, _)| s).collect();
    services.dedup();
    Ok(services)
}

/// The process of the connection that holds <service>.
fn process_of(bus: &Bus, service: &str) -> Result<u32, String> {
    let answer = ask(
        bus,
        DBUS,
        DBUS_PATH,
        DBUS,
        "GetConnectionUnixProcessID",
        &[Value::str(service)],
    )
    .map_err(|e| format!("the bus could not say whose the icon is: {e}"))?;
    answer
        .first()
        .and_then(Value::as_u64)
        .map(|p| p as u32)
        .ok_or_else(|| "the bus could not say whose the icon is".into())
}

/// What Quit would end of the app whose icon has <id> and <title>.
pub fn find(
    bus: &Bus,
    procs: &Procs,
    id: &str,
    title: &str,
    uid: u32,
    guarded: &[u32],
    folders: &[PathBuf],
) -> Result<Plan, String> {
    let services = items(bus, id, title)?;
    let mut plans: Vec<Plan> = Vec::new();
    for service in &services {
        let plan = plan(procs, process_of(bus, service)?, uid, guarded, folders)?;
        if !plans.contains(&plan) {
            plans.push(plan);
        }
    }
    match plans.len() {
        0 => Err("no app shows this icon now".into()),
        1 => Ok(plans.remove(0)),
        _ => Err("more than one app shows an icon of this name".into()),
    }
}

/// Ends what <plan> says: asks it to end, and kills what is left after
/// <grace>. The error says what did not end.
pub fn carry_out(bus: &Bus, plan: &Plan, grace: Duration) -> Result<(), String> {
    match plan {
        Plan::Unit { unit, .. } => stop_unit(bus, unit, grace),
        Plan::Tree { pids } => end_processes(pids, grace),
    }
}

/// Stops <unit> as `systemctl --user stop` does, which sends SIGTERM to every
/// process in it; one still stopping after <grace> gets SIGKILL.
fn stop_unit(bus: &Bus, unit: &str, grace: Duration) -> Result<(), String> {
    let removed: Rc<RefCell<Vec<String>>> = Rc::default();
    let seen = removed.clone();
    // Before the call, so that a job that ends at once is not missed.
    let _slot = bus
        .match_signal(
            None,
            Some(SYSTEMD_PATH),
            Some(MANAGER),
            Some("JobRemoved"),
            move |signal| {
                if let Ok(args) = signal.args() {
                    if let Some(Value::Path(job)) = args.get(1) {
                        seen.borrow_mut().push(job.clone());
                    }
                }
            },
        )
        .map_err(|e| format!("could not listen to systemd: {e}"))?;
    let job = match ask(
        bus,
        SYSTEMD,
        SYSTEMD_PATH,
        MANAGER,
        "StopUnit",
        &[Value::str(unit), Value::str("replace")],
    ) {
        Ok(reply) => match reply.into_iter().next() {
            Some(Value::Path(job)) => job,
            _ => return Err(format!("systemd gave no job to stop {unit}")),
        },
        Err(Error::Bus { name, .. }) if name == NO_SUCH_UNIT => return Ok(()),
        Err(e) => return Err(format!("systemd would not stop {unit}: {e}")),
    };
    let done = |within: Duration| -> Result<bool, String> {
        let deadline = Instant::now() + within;
        loop {
            bus.dispatch()
                .map_err(|e| format!("lost the session bus: {e}"))?;
            if removed.borrow().contains(&job) {
                return Ok(true);
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(false);
            }
            bus.wait(Some(left))
                .map_err(|e| format!("lost the session bus: {e}"))?;
        }
    };
    if done(grace)? {
        return Ok(());
    }
    match ask(
        bus,
        SYSTEMD,
        SYSTEMD_PATH,
        MANAGER,
        "KillUnit",
        &[Value::str(unit), Value::str("all"), Value::Int32(SIGKILL)],
    ) {
        Ok(_) => {}
        Err(Error::Bus { name, .. }) if name == NO_SUCH_UNIT => return Ok(()),
        Err(e) => {
            return Err(format!(
                "systemd would not kill what is left of {unit}: {e}"
            ))
        }
    }
    if done(AFTER_KILL)? {
        Ok(())
    } else {
        Err(format!("{unit} is still stopping"))
    }
}

/// A handle on a process that stays its own: none when the process has gone,
/// or when its pid is now another's (its start time is not <start>).
fn handle(pid: u32, start: u64) -> Option<OwnedFd> {
    // SAFETY: a plain system call; the descriptor is ours if it succeeds.
    let fd = unsafe { pidfd_open(pid as i32, 0) };
    if fd < 0 {
        return None;
    }
    // SAFETY: just opened, and ours alone.
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    // Read after the handle is open: the process it holds cannot be replaced.
    read_proc(Path::new("/proc"), pid)
        .filter(|p| p.start == start)
        .map(|_| fd)
}

fn signal(fd: &OwnedFd, signal: i32) {
    // SAFETY: a pidfd of ours, and no siginfo.
    unsafe { pidfd_send_signal(fd.as_raw_fd(), signal, std::ptr::null_mut(), 0) };
}

/// Waits until each of <fds> has ended (a pidfd reads as ready then), at most
/// <within>; the ones still running.
fn wait_ended(mut fds: Vec<OwnedFd>, within: Duration) -> Vec<OwnedFd> {
    let deadline = Instant::now() + within;
    loop {
        if fds.is_empty() {
            return fds;
        }
        let mut polled: Vec<PollFd> = fds
            .iter()
            .map(|f| PollFd::new(f.as_raw_fd(), POLLIN))
            .collect();
        let left = deadline.saturating_duration_since(Instant::now());
        let _ = poll(&mut polled, Some(left));
        let ended: Vec<bool> = polled.iter().map(PollFd::ready).collect();
        let mut i = 0;
        fds.retain(|_| {
            i += 1;
            !ended[i - 1]
        });
        if Instant::now() >= deadline {
            return fds;
        }
    }
}

/// SIGTERM to each of <pids>, and SIGKILL to those still running after
/// <grace>.
fn end_processes(pids: &[(u32, u64)], grace: Duration) -> Result<(), String> {
    let fds: Vec<OwnedFd> = pids
        .iter()
        .filter_map(|(pid, start)| handle(*pid, *start))
        .collect();
    for fd in &fds {
        signal(fd, SIGTERM);
    }
    let left = wait_ended(fds, grace);
    for fd in &left {
        signal(fd, SIGKILL);
    }
    let still = wait_ended(left, AFTER_KILL);
    if still.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "{} of its processes are still running",
            still.len()
        ))
    }
}

/// Says that the app did not quit, in a notification: the row went away
/// as if it had.
fn tell(name: Option<&str>, why: &str) {
    let _ = std::process::Command::new("notify-send")
        .args(["-a", "Nova", "-i", "dialog-warning"])
        .arg(format!("{} did not quit", name.unwrap_or("The app")))
        .arg(why)
        .stdin(std::process::Stdio::null())
        .status();
}

const USAGE: &str = "usage: nova-tray-quit check|quit <id> [<title>]";

pub fn main() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (verb, id, title) = match args.as_slice() {
        [verb, id] => (verb.as_str(), id.as_str(), ""),
        [verb, id, title] => (verb.as_str(), id.as_str(), title.as_str()),
        _ => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    if !matches!(verb, "check" | "quit") || id.is_empty() {
        eprintln!("{USAGE}");
        return 2;
    }
    let bus = match Bus::user() {
        Ok(bus) => bus,
        Err(e) => {
            eprintln!("nova-tray-quit: {e}");
            return 1;
        }
    };
    let procs = Procs::read(Path::new("/proc"));
    // SAFETY: always succeeds.
    let uid = unsafe { getuid() };
    let guarded = procs.ancestry(std::process::id());
    let folders = entry_folders();
    let plan = match find(&bus, &procs, id, title, uid, &guarded, &folders) {
        Ok(plan) => plan,
        Err(why) => {
            eprintln!("nova-tray-quit: {why}");
            return 1;
        }
    };
    let name = name_of(&plan, &procs, &folders);
    if verb == "check" {
        println!("{}", name.unwrap_or_default());
        return 0;
    }
    let what = match &plan {
        Plan::Unit { unit, .. } => unit.clone(),
        Plan::Tree { pids } => format!("process {} and those under it", pids[0].0),
    };
    match carry_out(&bus, &plan, GRACE) {
        Ok(()) => {
            eprintln!("nova-tray-quit: ended {what}");
            0
        }
        Err(why) => {
            eprintln!("nova-tray-quit: {why}");
            tell(name.as_deref(), &why);
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::no_real_buses;
    use nova_sd::testing::{scratch, PrivateBus};
    use nova_sd::{Handler, Interface, Message};
    use std::process::{Child, Command, Stdio};
    use std::sync::{mpsc, Arc, Mutex};
    use std::thread;

    const UID: u32 = 1000;
    const APPS: &str = "/user.slice/user-1000.slice/user@1000.service/app.slice";
    const SESSION: &str = "/user.slice/user-1000.slice/user@1000.service/session.slice";

    /// A stand-in /proc, a process at a time.
    struct FakeProc {
        dir: PathBuf,
    }

    impl FakeProc {
        fn new() -> FakeProc {
            FakeProc {
                dir: scratch("trayquit-proc"),
            }
        }

        /// <pid>, child of <ppid>, in <session> with terminal <tty> (0 for
        /// none), started at <start>, in <cgroup>, running <command>.
        #[allow(clippy::too_many_arguments)]
        fn add(
            &self,
            pid: u32,
            ppid: u32,
            session: u32,
            tty: u64,
            start: u64,
            cgroup: &str,
            command: &str,
        ) -> &FakeProc {
            self.add_as(pid, ppid, session, tty, start, cgroup, command, UID)
        }

        #[allow(clippy::too_many_arguments)]
        fn add_as(
            &self,
            pid: u32,
            ppid: u32,
            session: u32,
            tty: u64,
            start: u64,
            cgroup: &str,
            command: &str,
            uid: u32,
        ) -> &FakeProc {
            let dir = self.dir.join(pid.to_string());
            fs::create_dir_all(&dir).unwrap();
            let comm: String = command
                .rsplit('/')
                .next()
                .unwrap()
                .chars()
                .take(15)
                .collect();
            fs::write(
                dir.join("stat"),
                format!("{pid} ({comm}) S {ppid} {session} {session} {tty} -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 {start} 0 0\n"),
            )
            .unwrap();
            fs::write(
                dir.join("status"),
                format!("Name:\t{comm}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n"),
            )
            .unwrap();
            fs::write(dir.join("cgroup"), format!("0::{cgroup}\n")).unwrap();
            fs::write(dir.join("cmdline"), format!("{command}\0--flag\0")).unwrap();
            fs::write(dir.join("comm"), format!("{comm}\n")).unwrap();
            self
        }

        fn procs(&self) -> Procs {
            Procs::read(&self.dir)
        }
    }

    impl Drop for FakeProc {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    /// Desktop entries in a folder of the test's own.
    fn entries(list: &[(&str, &str)]) -> (PathBuf, Vec<PathBuf>) {
        let dir = scratch("trayquit-entries");
        for (id, name) in list {
            fs::write(
                dir.join(format!("{id}.desktop")),
                format!("[Desktop Entry]\nType=Application\nName={name}\nExec={id}\n"),
            )
            .unwrap();
        }
        (dir.clone(), vec![dir])
    }

    /// The shell, which runs this program: in Hyprland's unit, as on Nova.
    const SHELL: u32 = 1107;
    fn with_shell(fake: &FakeProc) {
        let unit = format!("{SESSION}/wayland-wm@hyprland.desktop.service");
        fake.add(900, 1, 900, 0, 50, &unit, "/usr/bin/uwsm")
            .add(964, 900, 900, 0, 60, &unit, "/usr/bin/Hyprland")
            .add(SHELL, 827, SHELL, 0, 70, &unit, "/usr/bin/quickshell");
    }
    const GUARDED: [u32; 2] = [99999, SHELL];

    /// Steam as it ran on the owner's laptop, started from the menu: the
    /// script nova-launch's scope began with, a logger that left it, the
    /// client in pressure-vessel's container, which starts a session of its
    /// own with no terminal, and the web helpers under it.
    fn steam(fake: &FakeProc) -> String {
        let unit = format!("{APPS}/app-graphical.slice/app-Hyprland-steam-198c4fc7.scope");
        fake.add(82983, 827, 82982, 0, 1000, &unit, "/bin/bash")
            .add(83011, 827, 83010, 0, 1001, &unit, "srt-logger")
            .add(
                83034,
                82983,
                82982,
                0,
                1002,
                &unit,
                "/home/u/.local/share/Steam/ubuntu12_32/steam",
            )
            .add(83134, 83034, 82982, 0, 1003, &unit, "srt-bwrap")
            .add(83315, 83134, 83315, 0, 1004, &unit, "pv-adverb")
            .add(83339, 83315, 83315, 0, 1005, &unit, "steam")
            .add(83627, 83339, 83627, 0, 1006, &unit, "steamwebhelper");
        unit
    }

    #[test]
    fn steam_from_the_menu_is_its_whole_scope_by_its_entrys_name() {
        let fake = FakeProc::new();
        with_shell(&fake);
        steam(&fake);
        let (_dir, folders) = entries(&[("steam", "Steam")]);
        let procs = fake.procs();
        for icon in [83339, 83627, 83034] {
            assert_eq!(
                plan(&procs, icon, UID, &GUARDED, &folders),
                Ok(Plan::Unit {
                    unit: "app-Hyprland-steam-198c4fc7.scope".into(),
                    app: "steam".into()
                }),
                "the icon held by {icon}"
            );
        }
        let ends = plan(&procs, 83339, UID, &GUARDED, &folders).unwrap();
        assert_eq!(name_of(&ends, &procs, &folders).as_deref(), Some("Steam"));
        let (_none, no_entries) = entries(&[]);
        assert_eq!(
            name_of(&ends, &procs, &no_entries),
            None,
            "no entry: Quit says no name"
        );
    }

    #[test]
    fn an_app_started_from_a_terminal_is_its_own_processes_and_the_terminal_stays() {
        let fake = FakeProc::new();
        with_shell(&fake);
        let foot = format!("{APPS}/app-graphical.slice/app-Hyprland-foot-0a0b0c0d.scope");
        // foot, its shell (a session with the terminal), steam's script run
        // from it, and the client under that; and vim in another tab.
        fake.add(500, 827, 499, 0, 100, &foot, "/usr/bin/foot")
            .add(501, 500, 501, 34816, 101, &foot, "/bin/bash")
            .add(502, 501, 501, 34816, 200, &foot, "/bin/bash")
            .add(503, 502, 501, 34816, 201, &foot, "steam")
            .add(504, 503, 501, 34816, 202, &foot, "steamwebhelper")
            .add(510, 500, 510, 34817, 102, &foot, "/bin/bash")
            .add(511, 510, 510, 34817, 103, &foot, "vim");
        let (_dir, folders) = entries(&[("steam", "Steam"), ("foot", "Foot")]);
        let procs = fake.procs();
        // 502 is steam's script (/usr/bin/steam): bash, as the stand-in has it.
        assert_eq!(
            plan(&procs, 503, UID, &GUARDED, &folders),
            Ok(Plan::Tree {
                pids: vec![(502, 200), (503, 201), (504, 202)]
            }),
            "the job the shell started, and what is under it: not foot, its shell, nor vim"
        );
        // Run straight from the shell, the app's tree starts at itself.
        let fake2 = FakeProc::new();
        with_shell(&fake2);
        fake2
            .add(500, 827, 499, 0, 100, &foot, "/usr/bin/foot")
            .add(501, 500, 501, 34816, 101, &foot, "/bin/bash")
            .add(
                503,
                501,
                501,
                34816,
                201,
                &foot,
                "/usr/bin/telegram-desktop",
            );
        let (_dir2, folders2) = entries(&[("org.telegram.desktop", "Telegram")]);
        let procs2 = fake2.procs();
        let ends = plan(&procs2, 503, UID, &GUARDED, &folders2).unwrap();
        assert_eq!(
            ends,
            Plan::Tree {
                pids: vec![(503, 201)]
            }
        );
        assert_eq!(
            name_of(&ends, &procs2, &folders2),
            None,
            "no entry named after the command: no name"
        );
    }

    #[test]
    fn an_app_let_go_of_by_a_terminal_ends_alone() {
        // `setsid -f app` in foot: the app's parent is the service manager,
        // and no terminal is above it, but the unit is foot's, with a shell
        // in it.
        let fake = FakeProc::new();
        with_shell(&fake);
        let foot = format!("{APPS}/app-graphical.slice/app-Hyprland-foot-0a0b0c0d.scope");
        fake.add(500, 827, 499, 0, 100, &foot, "/usr/bin/foot")
            .add(501, 500, 501, 34816, 101, &foot, "/bin/bash")
            .add(520, 827, 520, 0, 300, &foot, "/usr/bin/discord")
            .add(521, 520, 520, 0, 301, &foot, "/usr/bin/discord");
        let procs = fake.procs();
        assert_eq!(
            plan(&procs, 521, UID, &GUARDED, &[]),
            Ok(Plan::Tree {
                pids: vec![(520, 300), (521, 301)]
            })
        );
    }

    #[test]
    fn an_app_that_hosts_terminals_of_its_own_is_its_whole_scope() {
        // An app whose own children are terminal sessions (an editor's
        // built-in terminal): they are below the app, not above it.
        let fake = FakeProc::new();
        with_shell(&fake);
        let unit = format!("{APPS}/app-graphical.slice/app-Hyprland-code-11223344.scope");
        fake.add(600, 827, 600, 0, 100, &unit, "/usr/lib/code/code")
            .add(601, 600, 601, 34818, 101, &unit, "/bin/bash");
        let procs = fake.procs();
        assert_eq!(
            plan(&procs, 600, UID, &GUARDED, &[]),
            Ok(Plan::Unit {
                unit: "app-Hyprland-code-11223344.scope".into(),
                app: "code".into()
            })
        );
    }

    #[test]
    fn units_named_for_apps_by_flatpak_autostart_dbus_and_others_are_the_apps() {
        let (_dir, folders) = entries(&[("org.gnome.Loupe", "Image Viewer")]);
        let cases = [
            (format!("{APPS}/app-flatpak-org.telegram.desktop-12345.scope"), Some("org.telegram.desktop")),
            (format!("{APPS}/app-com.t3tools.T3Code-4167175.scope"), Some("com.t3tools.T3Code")),
            (format!("{APPS}/app-gnome\\x2dkeyring\\x2dpkcs11@autostart.service"), Some("gnome-keyring-pkcs11")),
            (format!("{APPS}/app-Hyprland-org.x.App@0a1b.service"), Some("org.x.App")),
            (format!("{APPS}/app-graphical.slice/app-Hyprland-google\\x2dchrome\\x2dstable-b495a5aa.scope"), Some("google-chrome-stable")),
            (format!("{APPS}/app-dbus\\x2d:1.2\\x2dorg.gnome.Loupe.slice/dbus-:1.2-org.gnome.Loupe@0.service"), Some("org.gnome.Loupe")),
            // One D-Bus started that is no app: the accessibility registry.
            (format!("{APPS}/app-dbus\\x2d:1.34\\x2dorg.a11y.atspi.Registry.slice/dbus-:1.34-org.a11y.atspi.Registry@0.service"), None),
            // Services by their own names, in app.slice or elsewhere.
            (format!("{APPS}/nova-xsettings.service"), None),
            (format!("{APPS}/blueman-applet.service"), None),
            (format!("{APPS}/app-t3code.slice/app-t3code-agents.slice/t3code-acp-bbff6810.scope"), None),
            (format!("{SESSION}/app-Hyprland-x-12345678.scope"), None),
        ];
        for (cgroup, want) in cases {
            let place =
                place(&cgroup, UID).unwrap_or_else(|| panic!("{cgroup} is under the manager"));
            assert_eq!(app_of(&place, &folders).as_deref(), want, "{cgroup}");
        }
    }

    #[test]
    fn a_service_that_owns_an_icon_is_not_ended() {
        let fake = FakeProc::new();
        with_shell(&fake);
        // A service the user enabled, a helper under it, and one it let go.
        let unit = format!("{APPS}/blueman-applet.service");
        fake.add(700, 827, 700, 0, 100, &unit, "/usr/bin/blueman-applet")
            .add(701, 700, 700, 0, 101, &unit, "/usr/bin/blueman-tray")
            .add(702, 827, 702, 0, 102, &unit, "/usr/bin/blueman-helper");
        let procs = fake.procs();
        let said = plan(&procs, 700, UID, &GUARDED, &[]).unwrap_err();
        assert!(
            said.contains("blueman-applet.service") && said.contains("not an app"),
            "{said}"
        );
        assert!(
            plan(&procs, 701, UID, &GUARDED, &[]).is_err(),
            "nor a process of its own tree"
        );
        assert_eq!(
            plan(&procs, 702, UID, &GUARDED, &[]),
            Ok(Plan::Tree {
                pids: vec![(702, 102)]
            }),
            "a helper it let go of is a program of its own"
        );
        // Nova's own, in the session's slice.
        let sessiond = format!("{SESSION}/nova-sessiond.service");
        fake.add(
            800,
            827,
            800,
            0,
            100,
            &sessiond,
            "/usr/lib/nova/nova-sessiond",
        );
        assert!(fake.procs().get(800).is_some());
        assert!(plan(&fake.procs(), 800, UID, &GUARDED, &[]).is_err());
    }

    #[test]
    fn an_app_hyprland_started_ends_alone_and_the_shell_never() {
        let fake = FakeProc::new();
        with_shell(&fake);
        let unit = format!("{SESSION}/wayland-wm@hyprland.desktop.service");
        fake.add(1200, 827, 1200, 0, 400, &unit, "/usr/bin/nm-applet");
        let procs = fake.procs();
        assert_eq!(
            plan(&procs, 1200, UID, &GUARDED, &[]),
            Ok(Plan::Tree {
                pids: vec![(1200, 400)]
            })
        );
        let said = plan(&procs, SHELL, UID, &GUARDED, &[]).unwrap_err();
        assert!(said.contains("shell or the session"), "{said}");
        assert!(
            plan(&procs, 964, UID, &GUARDED, &[]).is_err(),
            "nor Hyprland"
        );
    }

    #[test]
    fn what_holds_the_shell_is_never_ended_even_in_an_apps_unit() {
        let fake = FakeProc::new();
        let unit = format!("{APPS}/app-graphical.slice/app-Hyprland-x-01020304.scope");
        fake.add(40, 1, 40, 0, 10, &unit, "/usr/bin/x").add(
            41,
            40,
            40,
            0,
            11,
            &unit,
            "/usr/bin/quickshell",
        );
        let said = plan(&fake.procs(), 40, UID, &[99999, 41], &[]).unwrap_err();
        assert!(said.contains("shell or the session"), "{said}");
    }

    #[test]
    fn programs_outside_the_users_manager_or_not_the_users_are_not_ended() {
        let fake = FakeProc::new();
        fake.add(
            30,
            1,
            30,
            0,
            10,
            "/system.slice/bluetooth.service",
            "/usr/lib/bluetooth/bluetoothd",
        )
        .add(
            31,
            1,
            31,
            0,
            10,
            "/user.slice/user-1000.slice/session-2.scope",
            "/bin/bash",
        )
        .add(
            32,
            1,
            32,
            0,
            10,
            "/user.slice/user-1000.slice/user@1000.service/init.scope",
            "/usr/lib/systemd/systemd",
        )
        .add_as(
            33,
            1,
            33,
            0,
            10,
            &format!("{APPS}/app-x-12345678.scope"),
            "/usr/bin/x",
            0,
        );
        let procs = fake.procs();
        for (pid, says) in [
            (30, "outside"),
            (31, "outside"),
            (32, "service manager itself"),
            (33, "not yours"),
            (34, "quit already"),
        ] {
            let said = plan(&procs, pid, UID, &GUARDED, &[]).unwrap_err();
            assert!(said.contains(says), "{pid}: {said}");
        }
    }

    #[test]
    fn proc_is_read_as_the_kernel_writes_it() {
        let me = std::process::id();
        let procs = Procs::read(Path::new("/proc"));
        let mine = procs.get(me).expect("this process is in /proc");
        assert_eq!(mine.ppid, std::os::unix::process::parent_id());
        assert!(mine.start > 0 && mine.cgroup.starts_with('/'));
        assert!(procs.ancestry(me).starts_with(&[me, mine.ppid]));
        // A name with brackets and spaces in it.
        let fake = FakeProc::new();
        fake.add(5, 1, 5, 0, 77, "/x", "a b) (c");
        let five = fake.procs();
        let five = five.get(5).unwrap();
        assert_eq!((five.ppid, five.start, five.tty), (1, 77, 0));
    }

    #[test]
    fn unit_names_unescape() {
        assert_eq!(unescape("google\\x2dchrome"), "google-chrome");
        assert_eq!(unescape("caf\\xc3\\xa9"), "café");
        assert_eq!(unescape("plain\\x"), "plain\\x");
    }

    // ----- the bus: the tray's watcher, items, and systemd -----

    /// An object with properties and no methods: a watcher or an item.
    struct Props(Vec<(&'static str, Value)>);

    impl Handler for Props {
        fn call(&mut self, _: &Message, _: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
            Ok(vec![])
        }
        fn get(&mut self, _: &str, property: &str) -> Option<Value> {
            self.0
                .iter()
                .find(|(n, _)| *n == property)
                .map(|(_, v)| v.clone())
        }
    }

    /// A connection of its own on the private bus, serving <setup>'s objects
    /// on a thread until the test ends; its unique name.
    fn serve(
        address: &str,
        setup: impl FnOnce(&Bus) -> Vec<nova_sd::Slot> + Send + 'static,
    ) -> String {
        let (named, name) = mpsc::channel();
        let address = address.to_owned();
        thread::spawn(move || {
            let bus = Bus::connect(&address).unwrap();
            let _slots = setup(&bus);
            named.send(bus.unique_name().unwrap()).unwrap();
            loop {
                if bus.wait(None).is_err() || bus.dispatch().is_err() {
                    return;
                }
            }
        });
        name.recv_timeout(Duration::from_secs(5)).unwrap()
    }

    fn item(address: &str, path: &'static str, id: &'static str, title: &'static str) -> String {
        serve(address, move |bus| {
            vec![bus
                .export(
                    path,
                    vec![Interface::new(ITEM)
                        .property("Id", "s")
                        .property("Title", "s")],
                    Props(vec![("Id", Value::str(id)), ("Title", Value::str(title))]),
                )
                .unwrap()]
        })
    }

    fn watcher(address: &str, registered: Vec<String>) {
        let address2 = address.to_owned();
        serve(address, move |bus| {
            let slot = bus
                .export(
                    WATCHER_PATH,
                    vec![Interface::new(WATCHER).property("RegisteredStatusNotifierItems", "as")],
                    Props(vec![(
                        "RegisteredStatusNotifierItems",
                        Value::strings(&registered),
                    )]),
                )
                .unwrap();
            assert!(
                bus.request_name(WATCHER, 0).unwrap(),
                "the watcher's name on {address2}"
            );
            vec![slot]
        });
    }

    #[test]
    fn the_icon_is_found_by_its_id_and_title_among_the_watchers_items() {
        no_real_buses();
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let a = &private.address;
        let steam = item(a, "/org/ayatana/NotificationItem/steam", "steam", "Steam");
        let chat_one = item(a, ITEM_PATH, "chrome_status_icon_1", "Discord");
        let chat_two = item(a, ITEM_PATH, "chrome_status_icon_1", "Slack");
        let quiet = item(a, ITEM_PATH, "quiet", "");
        watcher(
            a,
            vec![
                format!("{steam}/org/ayatana/NotificationItem/steam"),
                format!("{chat_one}/StatusNotifierItem"),
                chat_two.clone(),
                format!("{quiet}/StatusNotifierItem"),
                ":1.999/StatusNotifierItem".into(),
            ],
        );
        let bus = Bus::connect(a).unwrap();
        crate::testing::wait_until("the watcher", || {
            bus.name_owner(WATCHER).ok().flatten().is_some()
        });
        assert_eq!(items(&bus, "steam", "Steam"), Ok(vec![steam.clone()]));
        assert_eq!(
            items(&bus, "steam", "renamed"),
            Ok(vec![steam]),
            "one with the Id: its Title does not matter"
        );
        assert_eq!(
            items(&bus, "chrome_status_icon_1", "Slack"),
            Ok(vec![chat_two.clone()]),
            "two with the Id: the Title tells"
        );
        assert_eq!(
            items(&bus, "chrome_status_icon_1", "").map(|v| v.len()),
            Ok(2),
            "and without one, both"
        );
        assert_eq!(items(&bus, "gone", "x"), Ok(vec![]));

        // Each connection's process is this test's: in a scope of an app
        // here, so the plan is that scope's.
        let fake = FakeProc::new();
        let me = std::process::id();
        let unit = format!("{APPS}/app-graphical.slice/app-Hyprland-steam-0badc0de.scope");
        fake.add(me, 1, me, 0, 10, &unit, "steam");
        let procs = fake.procs();
        assert_eq!(
            find(&bus, &procs, "steam", "Steam", UID, &[99999], &[]),
            Ok(Plan::Unit {
                unit: "app-Hyprland-steam-0badc0de.scope".into(),
                app: "steam".into()
            })
        );
        assert_eq!(
            find(&bus, &procs, "gone", "", UID, &[99999], &[]),
            Err("no app shows this icon now".into())
        );
        assert!(
            find(&bus, &procs, "steam", "Steam", UID, &[me], &[]).is_err(),
            "never the process asking"
        );
    }

    #[test]
    fn with_no_tray_on_the_bus_nothing_is_found() {
        no_real_buses();
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let bus = Bus::connect(&private.address).unwrap();
        let said = items(&bus, "steam", "").unwrap_err();
        assert!(said.contains("no tray"), "{said}");
    }

    /// systemd's manager, for StopUnit and KillUnit: each call is written to
    /// <heard>; a unit in <polite> ends as soon as it is stopped, any other
    /// only once it is killed; "gone.scope" is no unit.
    struct Systemd {
        heard: Arc<Mutex<Vec<String>>>,
        polite: Vec<&'static str>,
        jobs: u32,
        stopping: Vec<(String, String, u32)>,
    }

    impl Handler for Systemd {
        fn call(&mut self, call: &Message, args: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
            let unit = args[0].as_str().unwrap().to_owned();
            let words: Vec<String> = args
                .iter()
                .map(|a| match a {
                    Value::Str(s) => s.clone(),
                    Value::Int32(n) => n.to_string(),
                    other => format!("{other:?}"),
                })
                .collect();
            self.heard.lock().unwrap().push(format!(
                "{} {}",
                call.member().unwrap(),
                words.join(" ")
            ));
            if unit == "gone.scope" {
                return Err(Error::bus(NO_SUCH_UNIT, "Unit gone.scope not loaded."));
            }
            let removed = |bus: &Bus, id: u32, job: &str, unit: &str| {
                bus.emit_signal(
                    SYSTEMD_PATH,
                    MANAGER,
                    "JobRemoved",
                    &[
                        Value::Uint32(id),
                        Value::path(job),
                        Value::str(unit),
                        Value::str("done"),
                    ],
                )
                .unwrap();
            };
            match call.member() {
                Some("StopUnit") => {
                    self.jobs += 1;
                    let job = format!("/org/freedesktop/systemd1/job/{}", self.jobs);
                    if self.polite.contains(&unit.as_str()) {
                        removed(&call.bus(), self.jobs, &job, &unit);
                    } else {
                        self.stopping.push((unit, job.clone(), self.jobs));
                    }
                    Ok(vec![Value::path(job)])
                }
                Some("KillUnit") => {
                    if let Some(at) = self.stopping.iter().position(|(u, _, _)| *u == unit) {
                        let (unit, job, id) = self.stopping.remove(at);
                        if args[2] == Value::Int32(SIGKILL) {
                            removed(&call.bus(), id, &job, &unit);
                        }
                    }
                    Ok(vec![])
                }
                _ => unreachable!(),
            }
        }
    }

    fn systemd(address: &str, polite: Vec<&'static str>) -> Arc<Mutex<Vec<String>>> {
        let heard: Arc<Mutex<Vec<String>>> = Arc::default();
        let log = heard.clone();
        serve(address, move |bus| {
            let slot = bus
                .export(
                    SYSTEMD_PATH,
                    vec![Interface::new(MANAGER)
                        .method("StopUnit", "ss", "o")
                        .method("KillUnit", "ssi", "")
                        .signal("JobRemoved", "uoss")],
                    Systemd {
                        heard: log,
                        polite,
                        jobs: 0,
                        stopping: vec![],
                    },
                )
                .unwrap();
            assert!(bus.request_name(SYSTEMD, 0).unwrap());
            vec![slot]
        });
        heard
    }

    #[test]
    fn a_unit_is_stopped_and_what_will_not_stop_is_killed_after_the_grace() {
        no_real_buses();
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let heard = systemd(&private.address, vec!["polite.scope"]);
        let bus = Bus::connect(&private.address).unwrap();
        crate::testing::wait_until("systemd", || {
            bus.name_owner(SYSTEMD).ok().flatten().is_some()
        });
        let grace = Duration::from_millis(300);
        let unit = |name: &str| Plan::Unit {
            unit: name.into(),
            app: "x".into(),
        };

        let started = Instant::now();
        assert_eq!(carry_out(&bus, &unit("polite.scope"), grace), Ok(()));
        assert!(
            started.elapsed() < grace,
            "an app that ends when asked is not waited for"
        );
        assert_eq!(
            *heard.lock().unwrap(),
            vec!["StopUnit polite.scope replace"]
        );

        heard.lock().unwrap().clear();
        let started = Instant::now();
        assert_eq!(carry_out(&bus, &unit("stubborn.scope"), grace), Ok(()));
        assert!(
            started.elapsed() >= grace,
            "one that does not end gets the whole grace"
        );
        assert_eq!(
            *heard.lock().unwrap(),
            vec![
                "StopUnit stubborn.scope replace",
                "KillUnit stubborn.scope all 9"
            ]
        );

        heard.lock().unwrap().clear();
        assert_eq!(
            carry_out(&bus, &unit("gone.scope"), grace),
            Ok(()),
            "a unit gone already is no failure"
        );
        assert_eq!(*heard.lock().unwrap(), vec!["StopUnit gone.scope replace"]);
    }

    /// A child that ends on SIGTERM, or one that will not.
    fn child(stubborn: bool) -> Child {
        let script = if stubborn {
            "trap '' TERM; while :; do sleep 0.05; done"
        } else {
            "exec sleep 60"
        };
        Command::new("sh")
            .args(["-c", script])
            .stdin(Stdio::null())
            .spawn()
            .unwrap()
    }

    fn start_of(pid: u32) -> u64 {
        read_proc(Path::new("/proc"), pid).unwrap().start
    }

    #[test]
    fn processes_get_sigterm_then_sigkill_after_the_grace_and_a_reused_pid_nothing() {
        let mut polite = child(false);
        let mut stubborn = child(true);
        let mut other = child(false);
        // The shell has set its trap once it runs the loop.
        thread::sleep(Duration::from_millis(200));
        let grace = Duration::from_millis(300);
        let (p, s, o) = (polite.id(), stubborn.id(), other.id());
        let plan = Plan::Tree {
            pids: vec![(p, start_of(p)), (s, start_of(s)), (o, start_of(o) + 1)],
        };
        let Plan::Tree { pids } = &plan else {
            unreachable!()
        };
        let started = Instant::now();
        assert_eq!(end_processes(pids, grace), Ok(()));
        let took = started.elapsed();
        assert!(took >= grace && took < grace + AFTER_KILL, "{took:?}");
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(polite.wait().unwrap().signal(), Some(SIGTERM));
        assert_eq!(stubborn.wait().unwrap().signal(), Some(SIGKILL));
        assert_eq!(
            other.try_wait().unwrap(),
            None,
            "a pid whose start time is another's is left alone"
        );
        let _ = other.kill();
        let _ = other.wait();
    }
}
