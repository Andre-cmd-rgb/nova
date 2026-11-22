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
//! and that process's cgroup say what holds the app. /proc is read once the
//! bus has answered, and the bus is asked again after: each process read is
//! still the one holding its icon.
//!
//! - The app's own unit: a scope or service in app.slice named for an app,
//!   as systemd's desktop integration names them (nova-launch's
//!   app-Hyprland-<id>-<random>.scope, an autostart entry's
//!   app-<id>@autostart.service when the entry is not NoDisplay or Hidden, a
//!   Flatpak's app-flatpak-<id>-<n>.scope), or one D-Bus started for a name
//!   that has a desktop entry; when the icon is the app the unit was started
//!   for (see `plan`), with no terminal above the icon's process and none
//!   beside it in the unit. Once the icon's process is seen to be the same
//!   still, the unit is stopped (systemd sends SIGTERM to every process in
//!   it), and what is left after the unit's own stop timeout (its
//!   TimeoutStopSec, or NO_TIMEOUT when it has none) is killed.
//! - The app's own processes, in a unit that holds more: started from a
//!   terminal (a session with a controlling terminal above the icon's
//!   process), or beside one, or by Hyprland's exec, or by another app (a
//!   link opened from the browser, a game Steam started). The process its
//!   tree starts at (below the terminal's shell, below the app that started
//!   it) and every process under it in the unit get SIGTERM, and SIGKILL
//!   after NO_TIMEOUT, with what those still running started meanwhile in
//!   the unit: the terminal, its shell, the other app and the rest of the
//!   unit stay. One that ended and left a child behind leaves it to the
//!   service manager, where nothing tells it from another program.
//! - Nothing, when the process belongs to a unit that is no app's (a service
//!   the user enabled, Nova's, a portal: it owns an icon for something it does
//!   for the whole session, and what it let go of is its own still), when the
//!   process runs outside the user's service manager (a system service, the
//!   login session's scope) or is not the user's, when two apps answer to the
//!   icon's Id and Title, or when what would end holds the session: this
//!   program's own parents, the compositor, the shell, or the first process
//!   of one of the session's units, known by what they are, as `quit` runs
//!   with none of them above it.

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
const SCOPE: &str = "org.freedesktop.systemd1.Scope";
const SERVICE: &str = "org.freedesktop.systemd1.Service";
const NO_SUCH_UNIT: &str = "org.freedesktop.systemd1.NoSuchUnit";

/// How long an app has to end once asked, when nothing says otherwise: a
/// unit has its own stop timeout (90 s for a scope, 5 s for an autostart
/// entry's service), a program's processes in another's unit have this.
/// Quit runs detached once the menu has closed, so waiting costs nothing, and
/// an app saving a recording, a download or a game gets the time it needs.
pub const NO_TIMEOUT: Duration = Duration::from_secs(20);
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
/// (dbus-:<bus>-<name>@<n>.service) for a name with a desktop entry. An
/// autostart entry's (app-<id>@autostart.service) is an app's only when its
/// entry is one a user would call an app: not NoDisplay (the keyring's
/// agents, the accessibility bus), not Hidden.
fn app_of(place: &Place, folders: &[PathBuf]) -> Option<String> {
    let id = unit_app(place, folders)?;
    if place.unit.ends_with("@autostart.service") {
        let (autostart, apps): (Vec<&PathBuf>, Vec<&PathBuf>) =
            folders.iter().partition(|f| f.ends_with("autostart"));
        let file = autostart
            .into_iter()
            .chain(apps)
            .map(|f| f.join(format!("{id}.desktop")))
            .find(|f| f.is_file())?;
        let shown = |key: &str| crash::entry_value(&file, key).as_deref() != Some("true");
        return (shown("NoDisplay") && shown("Hidden")).then_some(id);
    }
    Some(id)
}

fn unit_app(place: &Place, folders: &[PathBuf]) -> Option<String> {
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

/// The icon as the tray shows it: its Id and its Title.
#[derive(Debug, Clone, Copy)]
pub struct Icon<'a> {
    pub id: &'a str,
    pub title: &'a str,
}

/// The id of the desktop entry <pid>'s command names, as crash::entry_of
/// finds one for a window's class.
fn entry_id(procs: &Procs, pid: u32, folders: &[PathBuf]) -> Option<String> {
    let file = crash::entry_of(&procs.command(pid)?, folders)?;
    Some(file.file_stem()?.to_string_lossy().into_owned())
}

/// The desktop entry of the app a unit is named for: <app>.desktop, or the
/// one crash::entry_of finds for the name (a unit named for the command,
/// ghostty, whose entry is com.mitchellh.ghostty.desktop).
fn app_entry(app: &str, folders: &[PathBuf]) -> Option<PathBuf> {
    folders
        .iter()
        .map(|f| f.join(format!("{app}.desktop")))
        .find(|f| f.is_file())
        .or_else(|| crash::entry_of(app, folders))
}

/// <said> without a count at either end, as an app puts its unread ones in
/// its icon's Title: "Slack (3)", "(12) Telegram", "Discord [99+]".
fn uncounted(said: &str) -> &str {
    let count = |c: &str| {
        let c = c.strip_suffix('+').unwrap_or(c);
        !c.is_empty() && c.bytes().all(|b| b.is_ascii_digit())
    };
    let mut said = said.trim();
    for (open, close) in [('(', ')'), ('[', ']')] {
        if let Some(rest) = said.strip_suffix(close) {
            if let Some((name, n)) = rest.rsplit_once(open) {
                if count(n) && !name.trim().is_empty() {
                    said = name.trim_end();
                }
            }
        }
        if let Some(rest) = said.strip_prefix(open) {
            if let Some((n, name)) = rest.split_once(close) {
                if count(n) && !name.trim().is_empty() {
                    said = name.trim_start();
                }
            }
        }
    }
    said
}

/// Whether the icon's Id or Title is the app <app>: its id, the last part of
/// a reverse-DNS one, or its entry's Name (Steam's is steam, or Steam), a
/// count of unread ones in the Title set aside.
fn icon_names(icon: &Icon, app: &str, folders: &[PathBuf]) -> bool {
    let name = app_entry(app, folders).and_then(|f| crash::entry_value(&f, "Name"));
    let last = app.rsplit('.').next().unwrap_or(app);
    [icon.id, icon.title]
        .iter()
        .map(|said| uncounted(said))
        .filter(|said| !said.is_empty())
        .any(|said| {
            said.eq_ignore_ascii_case(app)
                || said.eq_ignore_ascii_case(last)
                || name
                    .as_deref()
                    .is_some_and(|n| said.eq_ignore_ascii_case(n.trim()))
        })
}

/// Whether <app>'s entry is a terminal's (Categories: TerminalEmulator): a
/// terminal's unit holds what was started from it, and what it let go of.
fn is_terminal(app: &str, folders: &[PathBuf]) -> bool {
    app_entry(app, folders)
        .and_then(|f| crash::entry_value(&f, "Categories"))
        .is_some_and(|c| c.split(';').any(|c| c == "TerminalEmulator"))
}

/// The session's own processes, by what they are rather than by whose
/// parents they are (a `quit` run detached has none of them above it): the
/// compositor and the shell, by their commands, and the first process of
/// each of the session's units (session.slice: the compositor's, Nova's
/// daemons, the portals).
fn session_processes(procs: &Procs, uid: u32) -> HashSet<u32> {
    let mut out = HashSet::new();
    let mut first: HashMap<String, &Proc> = HashMap::new();
    for p in procs.by_pid.values().filter(|p| p.uid == uid) {
        if procs
            .command(p.pid)
            .is_some_and(|c| matches!(c.as_str(), "Hyprland" | "quickshell" | "qs"))
        {
            out.insert(p.pid);
        }
        if let Some(place) = place(&p.cgroup, uid) {
            if place.slices.first().map(String::as_str) == Some("session.slice") {
                let oldest = first.entry(place.path).or_insert(p);
                if (p.start, p.pid) < (oldest.start, oldest.pid) {
                    *oldest = p;
                }
            }
        }
    }
    out.extend(first.values().map(|p| p.pid));
    out
}

/// What Quit would end of the app whose icon (<icon>) is <pid>'s, for the
/// user <uid>, never one of <guarded> (this program and its parents) nor the
/// session's own processes; <folders> hold the desktop entries. The error
/// says why it ends nothing.
///
/// The whole unit ends only when the icon is the app the unit was started
/// for: its process descends from the unit's first one, and the nearest
/// process above it (itself included) whose command names a desktop entry
/// names the unit's app; when that one is not the icon's own process (a
/// helper of the app, or a program the app started, such as a game under
/// Steam), the icon's Id or Title must name the app too. With no entry named
/// on the way, the icon must name the app, or its process be the unit's
/// first one with nothing in the unit outside that one's tree (two apps a
/// launcher left in its scope are no app's), and never in a terminal's
/// unit. A Flatpak's scope is the sandbox alone. Otherwise only the icon's
/// own program ends: from the highest process above it that names the same
/// other app (Discord opened from a link in the browser, in the browser's
/// scope), from the one the unit's app started (the game), or from the top
/// of its tree in the unit (one a terminal let go of); and never from above
/// it through the unit's first process, unless that is the same app: then
/// from the one below that, on the icon's side (Telegram opened from a link
/// in Chrome, neither named by an entry).
pub fn plan(
    procs: &Procs,
    pid: u32,
    icon: &Icon,
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
    let first = members
        .iter()
        .min_by_key(|m| (m.start, m.pid))
        .expect("the process itself is in its unit");
    let not_an_app = || {
        format!(
            "the icon belongs to {}, which is not an app",
            unescape(&place.unit)
        )
    };
    // Walking up from the icon's process, the first whose command names an
    // entry: the app the icon is, as far as the commands say.
    let named = chain
        .iter()
        .enumerate()
        .find_map(|(i, q)| entry_id(procs, q.pid, folders).map(|id| (i, id)));
    let reaches_first = chain.iter().any(|q| q.pid == first.pid);
    // Everything in the unit descends from its first process.
    let first_tree: HashSet<u32> = procs.tree(first.pid, &members).into_iter().collect();
    let alone = members.iter().all(|m| first_tree.contains(&m.pid));
    let is_app = |id: &str, app: &str| id.eq_ignore_ascii_case(app);
    let whole = match (&app, above) {
        (Some(app), None) if !beside => {
            place.unit.starts_with("app-flatpak-")
                || (reaches_first
                    && match &named {
                        Some((0, id)) => is_app(id, app),
                        Some((_, id)) => is_app(id, app) && icon_names(icon, app, folders),
                        None => {
                            !is_terminal(app, folders)
                                && (icon_names(icon, app, folders) || (p.pid == first.pid && alone))
                        }
                    })
        }
        _ => false,
    };
    // Outside an app's own unit (a service, the session's), a program ends
    // alone only below a terminal, beside one, or as one the compositor
    // started (its exec): never one a service let go of.
    let compositors = members
        .iter()
        .any(|q| procs.command(q.pid).as_deref() == Some("Hyprland"));
    if app.is_none() && above.is_none() && !beside && !compositors {
        return Err(not_an_app());
    }
    let plan = if whole {
        Plan::Unit {
            unit: place.unit.clone(),
            app: app.clone().unwrap_or_default(),
        }
    } else {
        let mut root = match (above, &named) {
            (Some(0), _) => 0,
            (Some(i), _) => i - 1,
            // Another app's program: from the highest that is still it.
            (None, Some((i, id))) if !app.as_deref().is_some_and(|a| is_app(id, a)) => {
                let mut at = *i;
                while at + 1 < chain.len()
                    && entry_id(procs, chain[at + 1].pid, folders).as_deref() == Some(id.as_str())
                {
                    at += 1;
                }
                at
            }
            // A program the unit's app started, with an icon of its own.
            (None, Some((i, _))) if *i > 0 => i - 1,
            _ => chain.len() - 1,
        };
        // The unit's first process is the app it was started for, or what
        // is left of the unit: a tree from it holds that app as well as the
        // icon's, unless it is the icon's process, names the same app, or
        // runs the same command as the one below it (Telegram's helper,
        // Telegram left first in a launcher's scope).
        if let Some(at) = chain.iter().position(|q| q.pid == first.pid) {
            let same = at > 0
                && (named.as_ref().is_some_and(|(_, id)| {
                    entry_id(procs, first.pid, folders).as_deref() == Some(id.as_str())
                }) || procs.command(first.pid) == procs.command(chain[at - 1].pid));
            if at > 0 && root >= at && !same {
                root = at - 1;
            }
        }
        let root = chain[root];
        let pids = procs.tree(root.pid, &members);
        // A unit's own tree outside an app's unit is a service's main one.
        // In an app's unit it is what is left there: one a terminal let go
        // of, its terminal gone.
        if app.is_none() && pids.contains(&first.pid) {
            return Err(not_an_app());
        }
        Plan::Tree {
            pids: pids
                .into_iter()
                .filter_map(|q| procs.get(q).map(|p| (q, p.start)))
                .collect(),
        }
    };
    let ending: Vec<u32> = match &plan {
        Plan::Unit { .. } => members.iter().map(|m| m.pid).collect(),
        Plan::Tree { pids } => pids.iter().map(|(q, _)| *q).collect(),
    };
    let session = session_processes(procs, uid);
    if ending
        .iter()
        .any(|q| guarded.contains(q) || session.contains(q))
    {
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
    let file = match plan {
        Plan::Unit { app, .. } => app_entry(app, folders)?,
        // The first of what ends, from where it starts, whose command names
        // an entry: a game's launcher names none, the game may.
        Plan::Tree { pids } => pids
            .iter()
            .find_map(|(pid, _)| crash::entry_of(&procs.command(*pid)?, folders))?,
    };
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

/// What `find` found: the plan, the icon's process with its start time,
/// and the processes it was made from.
pub struct Found {
    pub plan: Plan,
    pub holder: (u32, u64),
    pub procs: Procs,
}

/// What Quit would end of the app whose icon is <icon>, for the user <uid>,
/// read from the /proc at <root>; <me> is this program, never ended with its
/// parents.
pub fn find(
    bus: &Bus,
    root: &Path,
    icon: &Icon,
    uid: u32,
    me: u32,
    folders: &[PathBuf],
) -> Result<Found, String> {
    let services = items(bus, icon.id, icon.title)?;
    let mut holders = Vec::new();
    for service in &services {
        holders.push(process_of(bus, service)?);
    }
    // Read once the bus has answered, so an app started since is there; and
    // the bus asked again, so that each process read holds its icon still: a
    // connection lives as long as its process, and a pid freed in between
    // would answer for none.
    let procs = Procs::read(root);
    for (service, holder) in services.iter().zip(&holders) {
        if process_of(bus, service)? != *holder {
            return Err("the icon moved to another program while it was looked at".into());
        }
    }
    let guarded = procs.ancestry(me);
    let mut plans: Vec<(Plan, u32)> = Vec::new();
    for holder in holders {
        let plan = plan(&procs, holder, icon, uid, &guarded, folders)?;
        if !plans.iter().any(|(p, _)| *p == plan) {
            plans.push((plan, holder));
        }
    }
    match plans.len() {
        0 => Err("no app shows this icon now".into()),
        1 => {
            let (plan, holder) = plans.remove(0);
            let start = procs.get(holder).map(|p| p.start).unwrap_or_default();
            Ok(Found {
                plan,
                holder: (holder, start),
                procs,
            })
        }
        _ => Err("more than one app shows an icon of this name".into()),
    }
}

/// Ends what <plan> says: asks it to end, and kills what is left after its
/// time (the unit's stop timeout, or NO_TIMEOUT). A unit is stopped only
/// while <holder>, the icon's process (pid and start time), is the one the
/// plan was made from: gone, the app has quit. The error says what did not
/// end.
pub fn carry_out(bus: &Bus, plan: &Plan, holder: (u32, u64)) -> Result<(), String> {
    match plan {
        Plan::Unit { unit, .. } => match handle(holder.0, holder.1) {
            Some(_held) => stop_unit(bus, unit),
            None => Ok(()),
        },
        Plan::Tree { pids } => end_processes(pids, NO_TIMEOUT),
    }
}

/// A unit's stop timeout in microseconds as systemd has it, as a time to
/// wait: none, 0 and infinity (no timeout) are NO_TIMEOUT.
fn timeout_of(usec: Option<u64>) -> Duration {
    match usec {
        None | Some(0) | Some(u64::MAX) => NO_TIMEOUT,
        Some(usec) => Duration::from_micros(usec),
    }
}

/// <unit>'s own stop timeout (TimeoutStopUSec), as systemd says it.
fn stop_timeout(bus: &Bus, unit: &str) -> Duration {
    let path = match ask(
        bus,
        SYSTEMD,
        SYSTEMD_PATH,
        MANAGER,
        "GetUnit",
        &[Value::str(unit)],
    ) {
        Ok(reply) => match reply.into_iter().next() {
            Some(Value::Path(path)) => Some(path),
            _ => None,
        },
        Err(_) => None,
    };
    let iface = if unit.ends_with(".scope") {
        SCOPE
    } else {
        SERVICE
    };
    let usec = path.and_then(|path| {
        ask(
            bus,
            SYSTEMD,
            &path,
            PROPERTIES,
            "Get",
            &[Value::str(iface), Value::str("TimeoutStopUSec")],
        )
        .ok()?
        .first()?
        .as_u64()
    });
    timeout_of(usec)
}

/// Stops <unit> as `systemctl --user stop` does, which sends SIGTERM to every
/// process in it; one still stopping after the unit's stop timeout gets
/// SIGKILL (systemd may have sent it by then).
fn stop_unit(bus: &Bus, unit: &str) -> Result<(), String> {
    let grace = stop_timeout(bus, unit);
    let removed: Rc<RefCell<Vec<String>>> = Rc::default();
    let seen = removed.clone();
    // Before the call, so that a job that ends at once is not missed. No
    // Subscribe() is needed: systemd sends JobRemoved to the job's requester.
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

/// Waits until each of <fds> (a pid with its pidfd) has ended (a pidfd reads
/// as ready then), at most <within>; the ones still running.
fn wait_ended(mut fds: Vec<(u32, OwnedFd)>, within: Duration) -> Vec<(u32, OwnedFd)> {
    let deadline = Instant::now() + within;
    loop {
        if fds.is_empty() {
            return fds;
        }
        let mut polled: Vec<PollFd> = fds
            .iter()
            .map(|(_, f)| PollFd::new(f.as_raw_fd(), POLLIN))
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
/// <grace>, and to what they started in the meantime in their own cgroup.
fn end_processes(pids: &[(u32, u64)], grace: Duration) -> Result<(), String> {
    let fds: Vec<(u32, OwnedFd)> = pids
        .iter()
        .filter_map(|(pid, start)| Some((*pid, handle(*pid, *start)?)))
        .collect();
    for (_, fd) in &fds {
        signal(fd, SIGTERM);
    }
    let mut left = wait_ended(fds, grace);
    // What a stubborn one started after it was asked to end: under it, in
    // its cgroup still (one moved to a unit of its own, an app it opened, is
    // that app's).
    let now = Procs::read(Path::new("/proc"));
    let mut known: HashSet<u32> = pids.iter().map(|(pid, _)| *pid).collect();
    let mut started = Vec::new();
    for (pid, _) in &left {
        let Some(cgroup) = now.get(*pid).map(|p| p.cgroup.as_str()) else {
            continue;
        };
        let among: Vec<&Proc> = now.by_pid.values().filter(|p| p.cgroup == cgroup).collect();
        for child in now.tree(*pid, &among) {
            if !known.insert(child) {
                continue;
            }
            if let Some(fd) = now.get(child).and_then(|p| handle(child, p.start)) {
                started.push((child, fd));
            }
        }
    }
    left.extend(started);
    for (_, fd) in &left {
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
    run(verb, &Icon { id, title }, Bus::user, &mut tell)
}

/// `check` or `quit` for <icon>, on the bus <connect> gives. What did not
/// work goes to stderr, and for `quit` to <tell> as well, whatever it was:
/// the menu has closed as if the app had quit, so a Quit that did not (the
/// icon gone, or its title changed since the menu opened) is always said.
fn run(
    verb: &str,
    icon: &Icon,
    connect: impl FnOnce() -> nova_sd::Result<Bus>,
    tell: &mut dyn FnMut(Option<&str>, &str),
) -> i32 {
    match attempt(verb, icon, connect) {
        Ok(()) => 0,
        Err((name, why)) => {
            eprintln!("nova-tray-quit: {why}");
            if verb == "quit" {
                tell(name.as_deref(), &why);
            }
            1
        }
    }
}

/// What `run` does; the error is the app's name, when known, and why.
fn attempt(
    verb: &str,
    icon: &Icon,
    connect: impl FnOnce() -> nova_sd::Result<Bus>,
) -> Result<(), (Option<String>, String)> {
    let bus = connect().map_err(|e| (None, format!("no session bus: {e}")))?;
    // SAFETY: always succeeds.
    let uid = unsafe { getuid() };
    let folders = entry_folders();
    let found = find(
        &bus,
        Path::new("/proc"),
        icon,
        uid,
        std::process::id(),
        &folders,
    )
    .map_err(|why| (None, why))?;
    let name = name_of(&found.plan, &found.procs, &folders);
    if verb == "check" {
        println!("{}", name.unwrap_or_default());
        return Ok(());
    }
    let what = match &found.plan {
        Plan::Unit { unit, .. } => unit.clone(),
        Plan::Tree { pids } => format!("process {} and those under it", pids[0].0),
    };
    carry_out(&bus, &found.plan, found.holder).map_err(|why| (name, why))?;
    eprintln!("nova-tray-quit: ended {what}");
    Ok(())
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
            write_proc(
                &self.dir, pid, ppid, session, tty, start, cgroup, command, uid,
            );
            self
        }

        fn procs(&self) -> Procs {
            Procs::read(&self.dir)
        }
    }

    /// One process in the stand-in /proc at <root>.
    #[allow(clippy::too_many_arguments)]
    fn write_proc(
        root: &Path,
        pid: u32,
        ppid: u32,
        session: u32,
        tty: u64,
        start: u64,
        cgroup: &str,
        command: &str,
        uid: u32,
    ) {
        {
            let dir = root.join(pid.to_string());
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
        }
    }

    impl Drop for FakeProc {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    /// Desktop entries in a folder of the test's own.
    fn entries(list: &[(&str, &str)]) -> (PathBuf, Vec<PathBuf>) {
        let with: Vec<(&str, &str, &str)> =
            list.iter().map(|(id, name)| (*id, *name, "")).collect();
        entries_with(&with)
    }

    /// Entries with more lines of their own each.
    fn entries_with(list: &[(&str, &str, &str)]) -> (PathBuf, Vec<PathBuf>) {
        let dir = scratch("trayquit-entries");
        for (id, name, more) in list {
            fs::write(
                dir.join(format!("{id}.desktop")),
                format!("[Desktop Entry]\nType=Application\nName={name}\nExec={id}\n{more}"),
            )
            .unwrap();
        }
        (dir.clone(), vec![dir])
    }

    /// An icon whose Id and Title name no app.
    const ANY: Icon<'static> = Icon {
        id: "icon",
        title: "",
    };
    const STEAM: Icon<'static> = Icon {
        id: "steam",
        title: "Steam",
    };

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
        for holder in [83339, 83627, 83034] {
            assert_eq!(
                plan(&procs, holder, &STEAM, UID, &GUARDED, &folders),
                Ok(Plan::Unit {
                    unit: "app-Hyprland-steam-198c4fc7.scope".into(),
                    app: "steam".into()
                }),
                "the icon held by {holder}"
            );
        }
        // Held by a helper whose command names no entry, an icon that does
        // not name Steam is not Steam's.
        assert_eq!(
            plan(&procs, 83627, &ANY, UID, &GUARDED, &folders),
            Ok(Plan::Tree {
                pids: vec![(83627, 1006)]
            })
        );
        let ends = plan(&procs, 83339, &STEAM, UID, &GUARDED, &folders).unwrap();
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
            plan(&procs, 503, &ANY, UID, &GUARDED, &folders),
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
        let ends = plan(&procs2, 503, &ANY, UID, &GUARDED, &folders2).unwrap();
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
            plan(&procs, 521, &ANY, UID, &GUARDED, &[]),
            Ok(Plan::Tree {
                pids: vec![(520, 300), (521, 301)]
            })
        );
    }

    #[test]
    fn an_app_opened_from_a_link_in_another_ends_alone_by_its_own_name() {
        // A discord:// link clicked in the browser: Discord starts in the
        // browser's scope, under the browser or left to the service manager.
        let firefox = format!("{APPS}/app-graphical.slice/app-Hyprland-firefox-0f0e0d0c.scope");
        let discord = Icon {
            id: "chrome_status_icon_1",
            title: "Discord",
        };
        let (_dir, folders) = entries(&[("firefox", "Firefox"), ("discord", "Discord")]);
        for parent in [300, 827] {
            let fake = FakeProc::new();
            with_shell(&fake);
            fake.add(300, 827, 300, 0, 100, &firefox, "/usr/lib/firefox/firefox")
                .add(301, 300, 300, 0, 101, &firefox, "/usr/lib/firefox/firefox")
                .add(350, parent, 300, 0, 200, &firefox, "/opt/discord/Discord")
                .add(351, 350, 300, 0, 201, &firefox, "/opt/discord/Discord");
            let procs = fake.procs();
            for holder in [350, 351] {
                let ends = plan(&procs, holder, &discord, UID, &GUARDED, &folders).unwrap();
                assert_eq!(
                    ends,
                    Plan::Tree {
                        pids: vec![(350, 200), (351, 201)]
                    },
                    "Discord alone, the browser stays (parent {parent}, icon held by {holder})"
                );
                assert_eq!(name_of(&ends, &procs, &folders).as_deref(), Some("Discord"));
            }
            // With no entry of its own (an AppImage), still it alone, and no
            // name: never the browser's.
            let (_only, only_firefox) = entries(&[("firefox", "Firefox")]);
            let ends = plan(&procs, 351, &discord, UID, &GUARDED, &only_firefox).unwrap();
            assert_eq!(
                ends,
                Plan::Tree {
                    pids: vec![(350, 200), (351, 201)]
                },
                "parent {parent}"
            );
            assert_eq!(name_of(&ends, &procs, &only_firefox), None);
            // The browser's own icon is the browser's whole scope.
            let own = Icon {
                id: "firefox",
                title: "",
            };
            assert_eq!(
                plan(&procs, 300, &own, UID, &GUARDED, &folders),
                Ok(Plan::Unit {
                    unit: "app-Hyprland-firefox-0f0e0d0c.scope".into(),
                    app: "firefox".into()
                })
            );
        }
    }

    #[test]
    fn an_app_left_in_a_closed_terminals_scope_ends_alone() {
        // `setsid -f discord` and another program from foot, then foot
        // closed: the two are all its scope holds, and the first is not
        // foot's.
        let fake = FakeProc::new();
        with_shell(&fake);
        let foot = format!("{APPS}/app-graphical.slice/app-Hyprland-foot-0a0b0c0d.scope");
        fake.add(520, 827, 520, 0, 300, &foot, "/opt/discord/Discord")
            .add(521, 520, 520, 0, 301, &foot, "/opt/discord/Discord")
            .add(530, 827, 530, 0, 400, &foot, "/usr/bin/syncthing");
        let procs = fake.procs();
        let terminal = "Categories=System;TerminalEmulator;\n";
        let discord = Icon {
            id: "chrome_status_icon_1",
            title: "Discord",
        };
        let (_dir, folders) =
            entries_with(&[("foot", "Foot", terminal), ("discord", "Discord", "")]);
        let (_dir2, no_discord) = entries_with(&[("foot", "Foot", terminal)]);
        for (folders, said) in [(&folders, "with its entry"), (&no_discord, "without one")] {
            for holder in [520, 521] {
                assert_eq!(
                    plan(&procs, holder, &discord, UID, &GUARDED, folders),
                    Ok(Plan::Tree {
                        pids: vec![(520, 300), (521, 301)]
                    }),
                    "{said}, held by {holder}"
                );
            }
        }
    }

    #[test]
    fn an_app_no_entry_names_opened_from_another_ends_alone_and_never_its_opener() {
        // A tg:// link clicked in the browser: Telegram starts in the
        // browser's scope, under the browser, straight or through xdg-open.
        // Telegram's command (Telegram) names no entry
        // (org.telegram.desktop), nor does Chrome's (chrome, for
        // google-chrome).
        let telegram = Icon {
            id: "TelegramDesktop",
            title: "Telegram",
        };
        let chrome =
            format!("{APPS}/app-graphical.slice/app-Hyprland-google\\x2dchrome-0f0e0d0c.scope");
        let firefox = format!("{APPS}/app-graphical.slice/app-Hyprland-firefox-0f0e0d0c.scope");
        let (_dir, folders) = entries(&[
            ("google-chrome", "Google Chrome"),
            ("firefox", "Firefox"),
            ("org.telegram.desktop", "Telegram"),
        ]);
        for (unit, browser) in [
            (&chrome, "/opt/google/chrome/chrome"),
            (&firefox, "/usr/lib/firefox/firefox"),
        ] {
            let fake = FakeProc::new();
            with_shell(&fake);
            fake.add(300, 827, 300, 0, 100, unit, browser)
                .add(301, 300, 300, 0, 101, unit, browser)
                .add(350, 300, 300, 0, 200, unit, "/usr/bin/Telegram")
                .add(360, 300, 300, 0, 300, unit, "/bin/sh")
                .add(361, 360, 300, 0, 301, unit, "/usr/bin/Telegram");
            let procs = fake.procs();
            assert_eq!(
                plan(&procs, 350, &telegram, UID, &GUARDED, &folders),
                Ok(Plan::Tree {
                    pids: vec![(350, 200)]
                }),
                "Telegram alone, never {browser}"
            );
            assert_eq!(
                plan(&procs, 361, &telegram, UID, &GUARDED, &folders),
                Ok(Plan::Tree {
                    pids: vec![(360, 300), (361, 301)]
                }),
                "through xdg-open: from the one {browser} started"
            );
        }
        // Chrome's own icon is still Chrome's whole scope.
        let fake = FakeProc::new();
        with_shell(&fake);
        fake.add(300, 827, 300, 0, 100, &chrome, "/opt/google/chrome/chrome")
            .add(350, 300, 300, 0, 200, &chrome, "/usr/bin/Telegram");
        let own = Icon {
            id: "chrome_status_icon_1",
            title: "Google Chrome",
        };
        assert_eq!(
            plan(&fake.procs(), 300, &own, UID, &GUARDED, &folders),
            Ok(Plan::Unit {
                unit: "app-Hyprland-google\\x2dchrome-0f0e0d0c.scope".into(),
                app: "google-chrome".into()
            })
        );
    }

    #[test]
    fn apps_a_launcher_left_in_its_scope_end_alone() {
        // Two apps a launcher started in its own scope, then ended: neither
        // names an entry, and the first is no more the launcher than the
        // other.
        let fake = FakeProc::new();
        with_shell(&fake);
        let unit = format!("{APPS}/app-graphical.slice/app-Hyprland-fuzzel-0a0b0c0d.scope");
        fake.add(700, 827, 700, 0, 100, &unit, "/usr/bin/Telegram")
            .add(701, 700, 700, 0, 101, &unit, "/usr/bin/Telegram")
            .add(710, 827, 710, 0, 200, &unit, "/opt/Foo/foo");
        let (_dir, folders) = entries(&[("fuzzel", "Fuzzel")]);
        let procs = fake.procs();
        let telegram = Icon {
            id: "TelegramDesktop",
            title: "Telegram",
        };
        for holder in [700, 701] {
            let ends = plan(&procs, holder, &telegram, UID, &GUARDED, &folders).unwrap();
            assert_eq!(
                ends,
                Plan::Tree {
                    pids: vec![(700, 100), (701, 101)]
                },
                "Telegram alone, held by {holder}"
            );
            assert_eq!(name_of(&ends, &procs, &folders), None, "never Fuzzel");
        }
        assert_eq!(
            plan(&procs, 710, &ANY, UID, &GUARDED, &folders),
            Ok(Plan::Tree {
                pids: vec![(710, 200)]
            })
        );
    }

    #[test]
    fn a_terminal_known_by_a_reverse_dns_entry_is_a_terminal() {
        // A terminal started by its command (ghostty), whose entry is
        // com.mitchellh.ghostty.desktop; closed, it left a program alone in
        // its scope.
        let fake = FakeProc::new();
        with_shell(&fake);
        let unit = format!("{APPS}/app-graphical.slice/app-Hyprland-ghostty-0a0b0c0d.scope");
        fake.add(720, 827, 720, 0, 300, &unit, "/usr/bin/syncthing-gtk");
        let (_dir, folders) = entries_with(&[(
            "com.mitchellh.ghostty",
            "Ghostty",
            "Categories=System;TerminalEmulator;\n",
        )]);
        assert!(is_terminal("ghostty", &folders));
        assert_eq!(
            plan(&fake.procs(), 720, &ANY, UID, &GUARDED, &folders),
            Ok(Plan::Tree {
                pids: vec![(720, 300)]
            })
        );
    }

    #[test]
    fn a_helper_whose_title_counts_unread_ones_is_still_its_app() {
        // Slack's icon, held by a helper whose command names no entry, with
        // an Id that says nothing and the unread count in its Title.
        let fake = FakeProc::new();
        with_shell(&fake);
        let unit = format!("{APPS}/app-graphical.slice/app-Hyprland-slack-0a0b0c0d.scope");
        fake.add(730, 827, 730, 0, 100, &unit, "/usr/bin/slack")
            .add(731, 730, 730, 0, 101, &unit, "/usr/lib/slack/helper");
        let (_dir, folders) = entries(&[("slack", "Slack")]);
        let procs = fake.procs();
        for title in ["Slack (3)", "(12) Slack", "Slack [99+]"] {
            let icon = Icon {
                id: "chrome_status_icon_1",
                title,
            };
            assert_eq!(
                plan(&procs, 731, &icon, UID, &GUARDED, &folders),
                Ok(Plan::Unit {
                    unit: "app-Hyprland-slack-0a0b0c0d.scope".into(),
                    app: "slack".into()
                }),
                "{title}"
            );
        }
        // A count alone names nothing.
        let icon = Icon {
            id: "chrome_status_icon_1",
            title: "(3)",
        };
        assert_eq!(
            plan(&procs, 731, &icon, UID, &GUARDED, &folders),
            Ok(Plan::Tree {
                pids: vec![(731, 101)]
            })
        );
    }

    #[test]
    fn a_game_with_its_own_icon_under_steam_ends_alone_and_steam_stays() {
        let fake = FakeProc::new();
        with_shell(&fake);
        let unit = steam(&fake);
        fake.add(84000, 83339, 83315, 0, 2000, &unit, "reaper").add(
            84001,
            84000,
            83315,
            0,
            2001,
            &unit,
            "/games/Foo/foo.x86_64",
        );
        let (_dir, folders) = entries(&[("steam", "Steam")]);
        let procs = fake.procs();
        let game = Icon {
            id: "foo",
            title: "Foo",
        };
        assert_eq!(
            plan(&procs, 84001, &game, UID, &GUARDED, &folders),
            Ok(Plan::Tree {
                pids: vec![(84000, 2000), (84001, 2001)]
            }),
            "the game, from what Steam started it with"
        );
        // An entry of the game's own: the game, by its name.
        let (_dir2, with_game) = entries(&[("steam", "Steam"), ("foo.x86_64", "Foo")]);
        let ends = plan(&procs, 84001, &game, UID, &GUARDED, &with_game).unwrap();
        assert_eq!(
            ends,
            Plan::Tree {
                pids: vec![(84001, 2001)]
            }
        );
        assert_eq!(name_of(&ends, &procs, &with_game).as_deref(), Some("Foo"));
        // Steam's own icon is still all of Steam, the game with it.
        assert_eq!(
            plan(&procs, 83339, &STEAM, UID, &GUARDED, &folders),
            Ok(Plan::Unit {
                unit: "app-Hyprland-steam-198c4fc7.scope".into(),
                app: "steam".into()
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
            plan(&procs, 600, &ANY, UID, &GUARDED, &[]),
            Ok(Plan::Unit {
                unit: "app-Hyprland-code-11223344.scope".into(),
                app: "code".into()
            })
        );
    }

    #[test]
    fn units_named_for_apps_by_flatpak_autostart_dbus_and_others_are_the_apps() {
        let (_dir, folders) = entries_with(&[
            ("org.gnome.Loupe", "Image Viewer", ""),
            ("discord", "Discord", ""),
            (
                "gnome-keyring-pkcs11",
                "Certificate and Key Storage",
                "NoDisplay=true\n",
            ),
        ]);
        let cases = [
            (format!("{APPS}/app-flatpak-org.telegram.desktop-12345.scope"), Some("org.telegram.desktop")),
            (format!("{APPS}/app-com.t3tools.T3Code-4167175.scope"), Some("com.t3tools.T3Code")),
            // An autostart entry's: the app's when its entry is one shown,
            // not the keyring's agent (NoDisplay), not one with no entry.
            (format!("{APPS}/app-discord@autostart.service"), Some("discord")),
            (format!("{APPS}/app-gnome\\x2dkeyring\\x2dpkcs11@autostart.service"), None),
            (format!("{APPS}/app-gone@autostart.service"), None),
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
        // A service the user enabled, a helper under it, and one it let go:
        // still the service's.
        let unit = format!("{APPS}/blueman-applet.service");
        fake.add(700, 827, 700, 0, 100, &unit, "/usr/bin/blueman-applet")
            .add(701, 700, 700, 0, 101, &unit, "/usr/bin/blueman-tray")
            .add(702, 827, 702, 0, 102, &unit, "/usr/bin/blueman-helper");
        let procs = fake.procs();
        let said = plan(&procs, 700, &ANY, UID, &GUARDED, &[]).unwrap_err();
        assert!(
            said.contains("blueman-applet.service") && said.contains("not an app"),
            "{said}"
        );
        assert!(
            plan(&procs, 701, &ANY, UID, &GUARDED, &[]).is_err(),
            "nor a process of its own tree"
        );
        let said = plan(&procs, 702, &ANY, UID, &GUARDED, &[]).unwrap_err();
        assert!(said.contains("not an app"), "nor one it let go of: {said}");
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
        assert!(plan(&fake.procs(), 800, &ANY, UID, &GUARDED, &[]).is_err());
    }

    #[test]
    fn an_app_hyprland_started_ends_alone_and_the_shell_never() {
        let fake = FakeProc::new();
        with_shell(&fake);
        let unit = format!("{SESSION}/wayland-wm@hyprland.desktop.service");
        fake.add(1200, 827, 1200, 0, 400, &unit, "/usr/bin/nm-applet");
        let procs = fake.procs();
        assert_eq!(
            plan(&procs, 1200, &ANY, UID, &GUARDED, &[]),
            Ok(Plan::Tree {
                pids: vec![(1200, 400)]
            })
        );
        let said = plan(&procs, SHELL, &ANY, UID, &GUARDED, &[]).unwrap_err();
        assert!(said.contains("shell or the session"), "{said}");
        assert!(
            plan(&procs, 964, &ANY, UID, &GUARDED, &[]).is_err(),
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
        for guarded in [&[99999, 41][..], &[99999]] {
            let said = plan(&fake.procs(), 40, &ANY, UID, guarded, &[]).unwrap_err();
            assert!(said.contains("shell or the session"), "{guarded:?}: {said}");
        }
    }

    #[test]
    fn quit_run_detached_never_ends_the_session_it_is_not_below() {
        // `quit` runs detached: none of the session is above it, and the
        // session is known by what it is.
        let fake = FakeProc::new();
        with_shell(&fake);
        let portal = format!("{SESSION}/xdg-desktop-portal-hyprland.service");
        fake.add(
            1300,
            827,
            1300,
            0,
            80,
            &portal,
            "/usr/lib/xdg-desktop-portal-hyprland",
        );
        let procs = fake.procs();
        for pid in [SHELL, 964, 900, 1300] {
            assert!(
                plan(&procs, pid, &ANY, UID, &[99999], &[]).is_err(),
                "{pid}"
            );
        }
        let said = plan(&procs, SHELL, &ANY, UID, &[99999], &[]).unwrap_err();
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
            let said = plan(&procs, pid, &ANY, UID, &GUARDED, &[]).unwrap_err();
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

    /// An object with properties and no methods: a watcher or an item; and
    /// what to do the first time one is read.
    struct Props(Vec<(&'static str, Value)>, Option<Box<dyn FnOnce() + Send>>);

    impl Handler for Props {
        fn call(&mut self, _: &Message, _: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
            Ok(vec![])
        }
        fn get(&mut self, _: &str, property: &str) -> Option<Value> {
            if let Some(first) = self.1.take() {
                first();
            }
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
        item_then(address, path, id, title, None)
    }

    /// An item that runs <first> when it is first asked.
    fn item_then(
        address: &str,
        path: &'static str,
        id: &'static str,
        title: &'static str,
        first: Option<Box<dyn FnOnce() + Send>>,
    ) -> String {
        serve(address, move |bus| {
            vec![bus
                .export(
                    path,
                    vec![Interface::new(ITEM)
                        .property("Id", "s")
                        .property("Title", "s")],
                    Props(
                        vec![("Id", Value::str(id)), ("Title", Value::str(title))],
                        first,
                    ),
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
                    Props(
                        vec![("RegisteredStatusNotifierItems", Value::strings(&registered))],
                        None,
                    ),
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
        let found = find(&bus, &fake.dir, &STEAM, UID, 99999, &[]).map(|f| (f.plan, f.holder));
        assert_eq!(
            found,
            Ok((
                Plan::Unit {
                    unit: "app-Hyprland-steam-0badc0de.scope".into(),
                    app: "steam".into()
                },
                (me, 10)
            ))
        );
        let gone = Icon {
            id: "gone",
            title: "",
        };
        assert_eq!(
            find(&bus, &fake.dir, &gone, UID, 99999, &[]).map(|f| f.plan),
            Err("no app shows this icon now".into())
        );
        assert!(
            find(&bus, &fake.dir, &STEAM, UID, me, &[]).is_err(),
            "never the process asking"
        );
    }

    #[test]
    fn proc_is_read_once_the_bus_has_answered() {
        no_real_buses();
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let a = &private.address;
        // The app's process shows in /proc only once its icon is asked: one
        // started while the menu was opening.
        let fake = FakeProc::new();
        let root = fake.dir.clone();
        let me = std::process::id();
        let late = item_then(
            a,
            ITEM_PATH,
            "late",
            "Late",
            Some(Box::new(move || {
                let unit = format!("{APPS}/app-graphical.slice/app-Hyprland-late-0badc0de.scope");
                write_proc(&root, me, 1, me, 0, 10, &unit, "late", UID);
            })),
        );
        watcher(a, vec![late]);
        let bus = Bus::connect(a).unwrap();
        crate::testing::wait_until("the watcher", || {
            bus.name_owner(WATCHER).ok().flatten().is_some()
        });
        let icon = Icon {
            id: "late",
            title: "Late",
        };
        assert_eq!(
            find(&bus, &fake.dir, &icon, UID, 99999, &[]).map(|f| f.plan),
            Ok(Plan::Unit {
                unit: "app-Hyprland-late-0badc0de.scope".into(),
                app: "late".into()
            })
        );
    }

    #[test]
    fn a_quit_that_fails_is_always_said_and_a_check_never() {
        no_real_buses();
        let icon = Icon {
            id: "steam",
            title: "Steam",
        };
        let told: RefCell<Vec<String>> = RefCell::default();
        let mut tell = |name: Option<&str>, why: &str| {
            assert_eq!(name, None, "no app was found to name");
            told.borrow_mut().push(why.to_owned());
        };
        let nowhere = || Bus::connect("unix:path=/nonexistent/nova-test-bus");
        assert_eq!(run("quit", &icon, nowhere, &mut tell), 1);
        assert_eq!(run("check", &icon, nowhere, &mut tell), 1);
        assert_eq!(told.borrow().len(), 1, "{:?}", told.borrow());
        assert!(told.borrow()[0].contains("no session bus"));
        let Some(private) = PrivateBus::start() else {
            return;
        };
        // A bus with no tray on it: the icon is not found.
        let a = private.address.clone();
        assert_eq!(run("quit", &icon, || Bus::connect(&a), &mut tell), 1);
        assert_eq!(run("check", &icon, || Bus::connect(&a), &mut tell), 1);
        assert_eq!(told.borrow().len(), 2, "{:?}", told.borrow());
        assert!(told.borrow()[1].contains("no tray"), "{:?}", told.borrow());
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
                Some("GetUnit") => Ok(vec![Value::path(format!(
                    "/org/freedesktop/systemd1/unit/{}",
                    unit.replace('.', "_2e")
                ))]),
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

    /// The units the stand-in has, with their stop timeouts.
    const STOP_TIMEOUTS: [(&str, u64); 2] =
        [("polite.scope", 300_000), ("stubborn.scope", 300_000)];

    fn systemd(address: &str, polite: Vec<&'static str>) -> Arc<Mutex<Vec<String>>> {
        let heard: Arc<Mutex<Vec<String>>> = Arc::default();
        let log = heard.clone();
        serve(address, move |bus| {
            let mut slots: Vec<nova_sd::Slot> = STOP_TIMEOUTS
                .iter()
                .map(|(unit, usec)| {
                    bus.export(
                        &format!(
                            "/org/freedesktop/systemd1/unit/{}",
                            unit.replace('.', "_2e")
                        ),
                        vec![Interface::new(SCOPE).property("TimeoutStopUSec", "t")],
                        Props(vec![("TimeoutStopUSec", Value::Uint64(*usec))], None),
                    )
                    .unwrap()
                })
                .collect();
            let slot = bus
                .export(
                    SYSTEMD_PATH,
                    vec![Interface::new(MANAGER)
                        .method("GetUnit", "s", "o")
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
            slots.push(slot);
            slots
        });
        heard
    }

    #[test]
    fn a_unit_is_stopped_and_what_will_not_stop_is_killed_after_its_stop_timeout() {
        no_real_buses();
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let heard = systemd(&private.address, vec!["polite.scope"]);
        let bus = Bus::connect(&private.address).unwrap();
        crate::testing::wait_until("systemd", || {
            bus.name_owner(SYSTEMD).ok().flatten().is_some()
        });
        // The stand-in's units stop within 300 ms.
        let grace = Duration::from_millis(300);
        let unit = |name: &str| Plan::Unit {
            unit: name.into(),
            app: "x".into(),
        };
        let me = std::process::id();
        let holder = (me, start_of(me));

        let started = Instant::now();
        assert_eq!(carry_out(&bus, &unit("polite.scope"), holder), Ok(()));
        assert!(
            started.elapsed() < grace,
            "an app that ends when asked is not waited for"
        );
        assert_eq!(
            *heard.lock().unwrap(),
            vec!["GetUnit polite.scope", "StopUnit polite.scope replace"]
        );

        heard.lock().unwrap().clear();
        let started = Instant::now();
        assert_eq!(carry_out(&bus, &unit("stubborn.scope"), holder), Ok(()));
        let took = started.elapsed();
        assert!(
            took >= grace && took < grace + AFTER_KILL,
            "one that does not end gets its unit's stop timeout: {took:?}"
        );
        assert_eq!(
            *heard.lock().unwrap(),
            vec![
                "GetUnit stubborn.scope",
                "StopUnit stubborn.scope replace",
                "KillUnit stubborn.scope all 9"
            ]
        );

        heard.lock().unwrap().clear();
        assert_eq!(
            carry_out(&bus, &unit("gone.scope"), holder),
            Ok(()),
            "a unit gone already is no failure"
        );
        assert_eq!(
            *heard.lock().unwrap(),
            vec!["GetUnit gone.scope", "StopUnit gone.scope replace"]
        );

        // The icon's process is not the one the plan was made from: the app
        // has quit, and its pid may be another's. Nothing is stopped.
        heard.lock().unwrap().clear();
        assert_eq!(
            carry_out(&bus, &unit("polite.scope"), (me, holder.1 + 1)),
            Ok(())
        );
        assert!(heard.lock().unwrap().is_empty());
    }

    #[test]
    fn a_unit_with_no_stop_timeout_gets_twenty_seconds() {
        assert_eq!(timeout_of(Some(90_000_000)), Duration::from_secs(90));
        assert_eq!(timeout_of(Some(5_000_000)), Duration::from_secs(5));
        for none in [None, Some(0), Some(u64::MAX)] {
            assert_eq!(timeout_of(none), NO_TIMEOUT, "{none:?}");
        }
        assert_eq!(NO_TIMEOUT, Duration::from_secs(20));
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

    #[test]
    fn what_a_process_starts_after_it_is_asked_to_end_is_killed_with_it() {
        let dir = scratch("trayquit-child");
        let file = dir.join("started");
        // Asked to end, it starts another and goes on.
        let script = format!(
            "trap 'sleep 60 & echo $! >{}' TERM; while :; do sleep 0.05; done",
            file.display()
        );
        let mut stubborn = Command::new("sh")
            .args(["-c", &script])
            .stdin(Stdio::null())
            .spawn()
            .unwrap();
        thread::sleep(Duration::from_millis(200));
        let s = stubborn.id();
        assert_eq!(
            end_processes(&[(s, start_of(s))], Duration::from_millis(400)),
            Ok(())
        );
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(stubborn.wait().unwrap().signal(), Some(SIGKILL));
        let started: u32 = fs::read_to_string(&file).unwrap().trim().parse().unwrap();
        // Killed, it is gone once whoever took it in has reaped it.
        let running = || {
            fs::read_to_string(format!("/proc/{started}/stat"))
                .ok()
                .and_then(|stat| {
                    Some(
                        stat.get(stat.rfind(')')? + 2..)?
                            .starts_with(['R', 'S', 'D']),
                    )
                })
                .unwrap_or(false)
        };
        let deadline = Instant::now() + AFTER_KILL;
        while running() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
        let left = running();
        if left {
            if let Some(fd) =
                read_proc(Path::new("/proc"), started).and_then(|p| handle(started, p.start))
            {
                signal(&fd, SIGKILL);
            }
        }
        let _ = fs::remove_dir_all(&dir);
        assert!(
            !left,
            "the process it started during the grace was left running"
        );
    }
}
