//! Says when an app quits unexpectedly, with a button that opens it again.
//!
//! As a Mac does: an app whose windows a crash took away is named in a
//! notification, "Bambu Studio quit unexpectedly", with Reopen. A crash that
//! leaves the app's windows open (a browser's tab, a helper process) is the
//! app's own to show, and is not said; nor is one that comes after its window
//! was closed, as an app that crashes on its way out does.
//!
//! Two things are watched: Hyprland's windows, from its event socket, each
//! with its process; and this user's crashes, which systemd-coredump writes
//! into the journal. A window whose process had ended, or was dumping its
//! core, when the window closed went with its process; a crash of that
//! process, in either order and within a minute, is said. Each crash once,
//! and an app that crashes at every start once a minute.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner, PollFd, POLLIN};
use nova_sd::Journal;

use crate::common::Context;
use crate::hypr::{self, Events};
use crate::json::{self, Json};
use crate::say;

pub const DUTY: &str = "crash-watch";
/// systemd-coredump's message: a process has crashed.
const CRASH: &str = "fc2e22bc6ee647b6b90729ab34a250b1";
/// How long a crash and its windows' closing wait for each other.
const WITHIN: Duration = Duration::from_secs(60);
/// The glyph the notification shows: Nerd Font's alert.
const GLYPH: &str = "\u{f0026}";

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// A window opened: the list of windows is read again.
    Opened,
    /// A window closed, by its address (without 0x).
    Closed(String),
    /// A process crashed, by its pid as the journal has it.
    Crashed(String),
}

/// What the watch needs from the world: the windows, the processes, and a
/// way to say something.
pub trait World {
    /// Hyprland's windows: address (without 0x), process, class.
    fn windows(&mut self) -> Vec<(String, u32, String)>;
    /// Whether process <pid> has ended, or is ending in a crash.
    fn ended(&self, pid: u32) -> bool;
    /// Sends a notification with these words (nova-notification-send's).
    fn tell(&mut self, words: Vec<String>);
    /// Where desktop entries are, the user's folder first.
    fn entry_folders(&self) -> Vec<PathBuf>;
}

/// What is known: the windows open, and what is waiting for its other half.
#[derive(Default)]
pub struct Watch {
    windows: HashMap<String, (u32, String)>,
    /// Processes whose window went with them: class, when.
    gone: HashMap<u32, (String, Instant)>,
    /// Processes that crashed, when.
    crashed: HashMap<u32, Instant>,
    /// What was said, and when; by process and by app.
    told: HashMap<u32, Instant>,
    app_told: HashMap<String, Instant>,
}

impl Watch {
    pub fn refresh(&mut self, world: &mut dyn World) {
        self.windows = world
            .windows()
            .into_iter()
            .map(|(address, pid, class)| (address, (pid, class)))
            .collect();
    }

    pub fn handle(&mut self, event: Event, now: Instant, world: &mut dyn World) {
        // What is older than a minute is let go first, so that a crash meets
        // only a window that closed within the minute, however long it was
        // since the last event.
        self.forget(now);
        match event {
            Event::Opened => self.refresh(world),
            Event::Closed(address) => self.closed(&address, now, world),
            Event::Crashed(pid) => self.crash(&pid, now, world),
        }
    }

    /// A window closed: if its process went with it, a crash of that process says so.
    fn closed(&mut self, address: &str, now: Instant, world: &mut dyn World) {
        let Some((pid, class)) = self.windows.remove(address) else {
            return;
        };
        // One still running closed its window itself.
        if self.told.contains_key(&pid) || !world.ended(pid) {
            return;
        }
        self.gone.insert(pid, (class, now));
        if self.crashed.contains_key(&pid) {
            self.tell(pid, now, world);
        }
    }

    /// A process crashed: said if its windows went with it.
    fn crash(&mut self, pid: &str, now: Instant, world: &mut dyn World) {
        if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) {
            return;
        }
        let Ok(pid) = pid.parse::<u32>() else { return };
        if self.told.contains_key(&pid) {
            return;
        }
        self.crashed.insert(pid, now);
        if self.gone.contains_key(&pid) {
            self.tell(pid, now, world);
        }
    }

    /// Says that the app of process <pid> quit, once, and once a minute an app.
    fn tell(&mut self, pid: u32, now: Instant, world: &mut dyn World) {
        self.told.insert(pid, now);
        let class = self
            .gone
            .get(&pid)
            .map(|(c, _)| c.clone())
            .unwrap_or_default();
        if class.is_empty() {
            return;
        }
        if self
            .app_told
            .get(&class)
            .is_some_and(|at| now.duration_since(*at) < WITHIN)
        {
            return;
        }
        self.app_told.insert(class.clone(), now);
        world.tell(notice(&class, &world.entry_folders()));
    }

    /// What is older than a minute waits no longer.
    fn forget(&mut self, now: Instant) {
        let fresh = |at: &Instant| now.duration_since(*at) < WITHIN;
        self.gone.retain(|_, (_, at)| fresh(at));
        self.crashed.retain(|_, at| fresh(at));
        self.told.retain(|_, at| fresh(at));
    }
}

/// The notification's words for an app of <class> that quit.
pub fn notice(class: &str, folders: &[PathBuf]) -> Vec<String> {
    let mut words: Vec<String> = vec!["-u".into(), "normal".into(), "-g".into(), GLYPH.into()];
    match entry_of(class, folders) {
        Some(file) => {
            let id = file
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            let name = entry_value(&file, "Name").filter(|n| !n.is_empty());
            if let Some(icon) = entry_value(&file, "Icon").filter(|i| !i.is_empty()) {
                words.extend(["-i".into(), icon]);
            }
            words.extend([
                "--button".into(),
                "Reopen".into(),
                format!("{} quit unexpectedly", name.as_deref().unwrap_or(class)),
                "--exec".into(),
            ]);
            words.extend(launch_words(&id));
        }
        None => words.push(format!("{class} quit unexpectedly")),
    }
    words
}

/// The desktop entries' folders, the user's first, as XDG has them.
pub fn entry_folders_from_env() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/share"));
    let dirs = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    std::iter::once(data_home.join("applications"))
        .chain(
            dirs.split(':')
                .filter(|d| !d.is_empty())
                .map(|d| Path::new(d).join("applications")),
        )
        .collect()
}

/// Every desktop entry in <folders>, a folder's in the order of their names,
/// the folders in theirs (the user's first). As XDG has it, an entry stands
/// for every one of its name in a later folder: one the user changed or hid
/// is the only one of that name, and the copy under it is not there.
pub fn entry_files(folders: &[PathBuf]) -> Vec<PathBuf> {
    let mut names = HashSet::new();
    let mut all = Vec::new();
    for folder in folders {
        let mut files: Vec<PathBuf> = fs::read_dir(folder)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e == "desktop") && p.is_file())
            .collect();
        files.sort();
        all.extend(
            files
                .into_iter()
                .filter(|f| f.file_name().is_some_and(|n| names.insert(n.to_owned()))),
        );
    }
    all
}

/// The desktop entry of a window's class, as a file: one named after it (any
/// case), one whose StartupWMClass it is, or a reverse-DNS one whose last part
/// it is (com.bambulab.BambuStudio for BambuStudio). Hidden entries are none.
pub fn entry_of(class: &str, folders: &[PathBuf]) -> Option<PathBuf> {
    let lower = class.to_lowercase();
    let listed = entry_files(folders);
    let wmclass = format!("StartupWMClass={class}");
    for pass in 0..3 {
        for file in &listed {
            let id = file
                .file_stem()
                .map(|s| s.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            let text = || fs::read_to_string(file).unwrap_or_default();
            let fits = match pass {
                0 => id == lower,
                1 => text().lines().any(|l| l == wmclass),
                _ => id.ends_with(&format!(".{lower}")),
            };
            if fits && !text().lines().any(|l| l == "Hidden=true") {
                return Some(file.clone());
            }
        }
    }
    None
}

/// A key's value in an entry's [Desktop Entry] group.
pub fn entry_value(file: &Path, key: &str) -> Option<String> {
    let text = fs::read_to_string(file).ok()?;
    let mut group = "";
    let prefix = format!("{key}=");
    for line in text.lines() {
        if line.starts_with('[') {
            group = line;
        } else if group == "[Desktop Entry]" {
            if let Some(value) = line.strip_prefix(&prefix) {
                return Some(value.to_owned());
            }
        }
    }
    None
}

/// What opens an entry again, as the menu opens it (AppSearch.launchWords).
pub fn launch_words(id: &str) -> Vec<String> {
    let plain = id
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'));
    if plain {
        vec!["nova-launch".into(), "--".into(), format!("{id}.desktop")]
    } else {
        vec![
            "nova-launch".into(),
            "--".into(),
            "gtk-launch".into(),
            format!("{id}.desktop"),
        ]
    }
}

/// Whether the process whose status file is at <proc>/<pid>/status has
/// ended: gone, a zombie, or writing its core.
pub fn ended(proc: &Path, pid: u32) -> bool {
    let Ok(status) = fs::read_to_string(proc.join(pid.to_string()).join("status")) else {
        return true;
    };
    status.contains("\nState:\tZ") || status.contains("\nCoreDumping:\t1")
}

/// Hyprland's window list, as `hyprctl -j clients` gives it.
pub fn parse_clients(answer: &str) -> Vec<(String, u32, String)> {
    let Some(doc) = json::parse(answer) else {
        return vec![];
    };
    doc.as_array()
        .unwrap_or_default()
        .iter()
        .filter_map(|client| {
            let address = client.get("address")?.as_str()?;
            let address = address.strip_prefix("0x").unwrap_or(address).to_owned();
            let pid = client.get("pid")?.as_f64()?;
            if pid < 0.0 || pid.fract() != 0.0 || pid > u32::MAX as f64 {
                return None;
            }
            let class = client
                .get("class")
                .and_then(Json::as_str)
                .unwrap_or_default();
            let class = if class.is_empty() {
                client
                    .get("initialClass")
                    .and_then(Json::as_str)
                    .unwrap_or_default()
            } else {
                class
            };
            Some((address, pid as u32, class.to_owned()))
        })
        .collect()
}

/// The event a line of Hyprland's is, for this watch.
pub fn event_of(line: &str) -> Option<Event> {
    match hypr::split(line) {
        ("openwindow", _) => Some(Event::Opened),
        ("closewindow", address) => Some(Event::Closed(address.to_owned())),
        _ => None,
    }
}

struct Session<'a> {
    ctx: &'a Context,
    hypr: PathBuf,
    folders: Vec<PathBuf>,
}

impl World for Session<'_> {
    fn windows(&mut self) -> Vec<(String, u32, String)> {
        hypr::request(&self.hypr, "j/clients")
            .map(|answer| parse_clients(&answer))
            .unwrap_or_default()
    }

    fn ended(&self, pid: u32) -> bool {
        ended(&self.ctx.proc, pid)
    }

    fn tell(&mut self, words: Vec<String>) {
        // A shell that is not there to show it (the shell itself went)
        // leaves the watch running.
        let mut argv = vec!["nova-notification-send"];
        argv.extend(words.iter().map(String::as_str));
        self.ctx.spawn(&argv, true);
    }

    fn entry_folders(&self) -> Vec<PathBuf> {
        self.folders.clone()
    }
}

/// Where this user's crashes are read from.
#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    /// The user's journal file, the one journald writes to now, which is
    /// where systemd-coredump's messages about this user's processes go.
    /// Only it is read: every archived file a whole journal opens would be
    /// pages of this process's (about 4 MB of them here).
    Active(PathBuf),
    /// Every journal file this user may read, where there is no file of the
    /// user's own (journald's SplitMode=none).
    Everything,
}

/// The user's journal file, in the persistent journal or the volatile one.
pub fn user_journal(uid: u32) -> Option<PathBuf> {
    let machine = fs::read_to_string("/etc/machine-id").ok()?;
    ["/var/log/journal", "/run/log/journal"]
        .iter()
        .map(|base| {
            Path::new(base)
                .join(machine.trim())
                .join(format!("user-{uid}.journal"))
        })
        .find(|file| file.exists())
}

fn inode(path: &Path) -> Option<u64> {
    std::os::unix::fs::MetadataExt::ino(&fs::metadata(path).ok()?).into()
}

/// This user's crashes, as systemd-coredump writes them into the journal.
pub struct Crashes {
    journal: Journal,
    source: Source,
    /// The active file's inode, which a rotation changes.
    inode: Option<u64>,
}

impl Crashes {
    /// The crashes from now on.
    pub fn open(source: Source) -> Result<Crashes, String> {
        let mut crashes = Crashes::opened(source)?;
        crashes.journal.seek_end().map_err(|e| e.to_string())?;
        Ok(crashes)
    }

    fn opened(source: Source) -> Result<Crashes, String> {
        let (mut journal, inode) = match &source {
            Source::Active(file) => (
                Journal::open_files(&[file]).map_err(|e| e.to_string())?,
                inode(file),
            ),
            Source::Everything => (Journal::open_local().map_err(|e| e.to_string())?, None),
        };
        // SAFETY: getuid cannot fail.
        let uid = unsafe { getuid() };
        journal
            .add_match("MESSAGE_ID", CRASH)
            .map_err(|e| e.to_string())?;
        journal
            .add_match("COREDUMP_UID", &uid.to_string())
            .map_err(|e| e.to_string())?;
        Ok(Crashes {
            journal,
            source,
            inode,
        })
    }

    pub fn poll_fd(&mut self) -> Result<PollFd, String> {
        self.journal.poll_fd().map_err(|e| e.to_string())
    }

    pub fn timeout(&mut self) -> Option<Duration> {
        self.journal.timeout()
    }

    /// The pids of the crashes written since the last look.
    pub fn take(&mut self) -> Result<Vec<String>, String> {
        self.journal.process().map_err(|e| e.to_string())?;
        let mut pids = self.read()?;
        // journald started a new file in the old one's place (a rotation):
        // everything in the new one came after what was read here.
        if let Source::Active(file) = &self.source {
            if inode(file).is_some_and(|now| Some(now) != self.inode) {
                let mut fresh = Crashes::opened(self.source.clone())?;
                fresh.journal.seek_head().map_err(|e| e.to_string())?;
                *self = fresh;
                pids.extend(self.read()?);
            }
        }
        Ok(pids)
    }

    fn read(&mut self) -> Result<Vec<String>, String> {
        let mut pids = Vec::new();
        while self.journal.next_entry().map_err(|e| e.to_string())? {
            pids.push(
                self.journal
                    .field("COREDUMP_PID")
                    .map_err(|e| e.to_string())?
                    .unwrap_or_default(),
            );
        }
        Ok(pids)
    }
}

extern "C" {
    fn getuid() -> u32;
}

/// Watches until Hyprland ends.
pub fn run(ctx: &Context) -> Result<(), String> {
    let Some(hypr) = ctx.hypr.clone() else {
        say!(DUTY, "not running inside a Hyprland session");
        return Ok(());
    };
    // SAFETY: getuid cannot fail.
    let source = user_journal(unsafe { getuid() }).map_or(Source::Everything, Source::Active);
    follow(ctx, &hypr, Crashes::open(source)?, entry_folders_from_env())
}

/// Follows the Hyprland at <hypr> and the crashes in <journal> until Hyprland ends.
fn follow(
    ctx: &Context,
    hypr: &Path,
    mut crashes: Crashes,
    folders: Vec<PathBuf>,
) -> Result<(), String> {
    let mut events = Events::connect(hypr).map_err(|e| format!("Hyprland's events: {e}"))?;
    let mut session = Session {
        ctx,
        hypr: hypr.to_owned(),
        folders,
    };
    let mut watch = Watch::default();
    watch.refresh(&mut session);
    loop {
        let mut fds = [PollFd::new(events.fd(), POLLIN), crashes.poll_fd()?];
        poll(&mut fds, sooner(crashes.timeout(), None))
            .map_err(|e| format!("could not wait: {e}"))?;
        if fds[0].ready() {
            let Some(lines) = events
                .lines()
                .map_err(|e| format!("Hyprland's events: {e}"))?
            else {
                return Err("Hyprland's events ended".into());
            };
            for event in lines.iter().filter_map(|l| event_of(l)) {
                watch.handle(event, Instant::now(), &mut session);
            }
        }
        for pid in crashes.take()? {
            watch.handle(Event::Crashed(pid), Instant::now(), &mut session);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nova_sd::testing::scratch;

    /// Hyprland's windows, the processes, and what was said, all made up.
    struct Fake {
        windows: Vec<(String, u32, String)>,
        later: Option<Vec<(String, u32, String)>>,
        asked: usize,
        proc: PathBuf,
        folders: Vec<PathBuf>,
        said: Vec<String>,
    }

    impl Fake {
        fn new(dir: &Path) -> Fake {
            let user = dir.join("home/applications");
            let system = dir.join("system/applications");
            fs::create_dir_all(&user).unwrap();
            fs::create_dir_all(&system).unwrap();
            fs::create_dir_all(dir.join("proc")).unwrap();
            Fake {
                windows: vec![],
                later: None,
                asked: 0,
                proc: dir.join("proc"),
                folders: vec![user, system],
                said: vec![],
            }
        }

        fn windows(&mut self, list: &[(&str, u32, &str)]) {
            self.windows = list
                .iter()
                .map(|(a, p, c)| (a.to_string(), *p, c.to_string()))
                .collect();
        }

        /// A process that runs, or is in that state.
        fn running(&self, pid: u32, state: &str) {
            fs::create_dir_all(self.proc.join(pid.to_string())).unwrap();
            fs::write(
                self.proc.join(pid.to_string()).join("status"),
                format!("Name:\tapp\nUmask:\t0022\nState:\t{state}\nTgid:\t{pid}\n"),
            )
            .unwrap();
        }

        fn entry(&self, id: &str, lines: &[&str]) {
            fs::write(
                self.folders[1].join(format!("{id}.desktop")),
                format!("[Desktop Entry]\nType=Application\n{}\n", lines.join("\n")),
            )
            .unwrap();
        }
    }

    impl World for Fake {
        fn windows(&mut self) -> Vec<(String, u32, String)> {
            self.asked += 1;
            match (&self.later, self.asked) {
                (Some(later), n) if n > 1 => later.clone(),
                _ => self.windows.clone(),
            }
        }
        fn ended(&self, pid: u32) -> bool {
            ended(&self.proc, pid)
        }
        fn tell(&mut self, words: Vec<String>) {
            self.said.push(words.join(" "));
        }
        fn entry_folders(&self) -> Vec<PathBuf> {
            self.folders.clone()
        }
    }

    fn closed(a: &str) -> Event {
        Event::Closed(a.into())
    }
    fn core(p: &str) -> Event {
        Event::Crashed(p.into())
    }

    /// The watch from its start, through <events>, a second apart.
    fn watch(fake: &mut Fake, events: Vec<Event>) {
        let mut watch = Watch::default();
        watch.refresh(fake);
        let start = Instant::now();
        for (i, event) in events.into_iter().enumerate() {
            watch.handle(event, start + Duration::from_secs(i as u64), fake);
        }
    }

    #[test]
    fn an_app_whose_window_a_crash_took_away_is_said_with_reopen_as_the_menu_opens_it() {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fake.entry(
            "org.example.Sketch",
            &["Name=Sketch", "Icon=org.example.Sketch", "Name[de]=Skizze"],
        );
        fake.windows(&[("abc", 4242, "org.example.Sketch")]);
        watch(&mut fake, vec![closed("abc"), core("4242")]);
        assert_eq!(
            fake.said,
            vec!["-u normal -g \u{f0026} -i org.example.Sketch --button Reopen Sketch quit unexpectedly --exec nova-launch -- org.example.Sketch.desktop"]
        );
    }

    #[test]
    fn the_crash_may_come_first_and_a_window_may_close_dumping_its_core_or_a_zombie() {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fake.entry("sketch", &["Name=Sketch"]);
        fake.windows(&[("abc", 4242, "sketch"), ("def", 5151, "sketch")]);
        fake.running(5151, "Z (zombie)");
        watch(&mut fake, vec![core("4242"), closed("abc")]);
        assert_eq!(fake.said.len(), 1);

        fake.said.clear();
        fake.windows(&[("def", 5151, "other")]);
        fake.entry("other", &["Name=Other"]);
        watch(&mut fake, vec![closed("def"), core("5151")]);
        assert!(fake.said[0].contains("Other quit unexpectedly"));

        fake.said.clear();
        fs::write(
            fake.proc.join("5151/status"),
            "Name:\tapp\nState:\tD (disk sleep)\nCoreDumping:\t1\n",
        )
        .unwrap();
        watch(&mut fake, vec![closed("def"), core("5151")]);
        assert!(fake.said[0].contains("Other quit unexpectedly"));
    }

    #[test]
    fn a_crash_that_leaves_the_windows_open_as_a_browsers_tab_does_is_not_said() {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fake.entry("sketch", &["Name=Sketch"]);
        fake.windows(&[("abc", 4242, "sketch")]);
        fake.running(4242, "S (sleeping)");
        watch(&mut fake, vec![core("7777"), core("4242")]);
        assert!(fake.said.is_empty());
    }

    #[test]
    fn a_crash_after_the_window_was_closed_an_app_crashing_on_its_way_out_is_not_said() {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fake.entry("sketch", &["Name=Sketch"]);
        fake.windows(&[("abc", 4242, "sketch")]);
        fake.running(4242, "S (sleeping)");
        watch(&mut fake, vec![closed("abc"), core("4242")]);
        assert!(fake.said.is_empty());
    }

    #[test]
    fn a_window_that_closed_with_its_process_and_no_crash_is_a_quit_and_not_said() {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fake.windows(&[("abc", 4242, "sketch")]);
        watch(&mut fake, vec![closed("abc"), core("x"), core("")]);
        assert!(fake.said.is_empty());
    }

    #[test]
    fn a_process_with_several_windows_is_said_once_and_an_app_crashing_at_each_start_once_a_minute()
    {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fake.entry("sketch", &["Name=Sketch"]);
        fake.windows(&[
            ("abc", 4242, "sketch"),
            ("abd", 4242, "sketch"),
            ("abe", 4343, "sketch"),
        ]);
        watch(
            &mut fake,
            vec![
                closed("abc"),
                closed("abd"),
                core("4242"),
                core("4242"),
                closed("abe"),
                core("4343"),
            ],
        );
        assert_eq!(fake.said.len(), 1);
    }

    #[test]
    fn what_waits_more_than_a_minute_is_forgotten_and_a_minute_on_the_app_is_said_again() {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fake.windows(&[("abc", 1, "sketch"), ("abd", 2, "sketch")]);
        let mut watch = Watch::default();
        watch.refresh(&mut fake);
        let start = Instant::now();
        watch.handle(closed("abc"), start, &mut fake);
        // The crash, too late to be the window's.
        watch.handle(core("1"), start + Duration::from_secs(61), &mut fake);
        assert!(fake.said.is_empty());
        watch.handle(closed("abd"), start + Duration::from_secs(62), &mut fake);
        watch.handle(core("2"), start + Duration::from_secs(63), &mut fake);
        assert_eq!(
            fake.said,
            vec!["-u normal -g \u{f0026} sketch quit unexpectedly"]
        );
    }

    #[test]
    fn a_window_opened_after_the_start_is_known_by_its_process() {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fake.entry("sketch", &["Name=Sketch"]);
        fake.later = Some(vec![("abc".into(), 4242, "sketch".into())]);
        watch(
            &mut fake,
            vec![
                event_of("openwindow>>abc,1,sketch,A sketch").unwrap(),
                closed("abc"),
                core("4242"),
            ],
        );
        assert!(fake.said[0].contains("Sketch quit unexpectedly"));
    }

    #[test]
    fn the_entry_is_found_by_its_name_in_any_case_its_startupwmclass_or_the_last_part_of_its_id_the_users_first(
    ) {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fake.entry("com.bambulab.BambuStudio", &["Name=Bambu Studio"]);
        fake.entry(
            "google-chrome",
            &["Name=Google Chrome", "StartupWMClass=chrome-browser"],
        );
        fake.entry("kitty", &["Name=kitty"]);
        fake.entry("hidden", &["Name=Hidden", "Hidden=true"]);
        fs::write(
            fake.folders[0].join("Kitty.desktop"),
            "[Desktop Entry]\nName=My Kitty\n",
        )
        .unwrap();
        fake.windows(&[
            ("a1", 11, "BambuStudio"),
            ("a2", 12, "chrome-browser"),
            ("a3", 13, "KITTY"),
            ("a4", 14, "hidden"),
        ]);
        watch(
            &mut fake,
            vec![
                closed("a1"),
                core("11"),
                closed("a2"),
                core("12"),
                closed("a3"),
                core("13"),
                closed("a4"),
                core("14"),
            ],
        );
        assert!(fake.said[0].ends_with(
            "-g \u{f0026} --button Reopen Bambu Studio quit unexpectedly --exec nova-launch -- com.bambulab.BambuStudio.desktop"
        ));
        assert!(fake.said[1].ends_with(
            "Google Chrome quit unexpectedly --exec nova-launch -- google-chrome.desktop"
        ));
        assert!(fake.said[2]
            .ends_with("My Kitty quit unexpectedly --exec nova-launch -- Kitty.desktop"));
        assert_eq!(
            fake.said[3],
            "-u normal -g \u{f0026} hidden quit unexpectedly"
        );
    }

    #[test]
    fn an_id_uwsm_will_not_take_is_opened_through_gtk_launch() {
        let dir = scratch("crash");
        let mut fake = Fake::new(&dir);
        fs::write(
            fake.folders[1].join("Odd App.desktop"),
            "[Desktop Entry]\nName=Odd\nStartupWMClass=odd\n",
        )
        .unwrap();
        fake.windows(&[("abc", 4242, "odd")]);
        watch(&mut fake, vec![closed("abc"), core("4242")]);
        assert!(fake.said[0]
            .ends_with("Odd quit unexpectedly --exec nova-launch -- gtk-launch Odd App.desktop"));
    }

    #[test]
    fn hyprlands_window_list_is_read_with_the_initial_class_when_there_is_no_class() {
        let clients = parse_clients(
            r#"[{"address":"0xabc","pid":42,"class":"","initialClass":"steam"},
                {"address":"0xdef","pid":-1,"class":"x"},{"address":"0x1","pid":7,"class":"foot"}]"#,
        );
        assert_eq!(
            clients,
            vec![
                ("abc".into(), 42, "steam".into()),
                ("1".into(), 7, "foot".into())
            ]
        );
        assert!(parse_clients("not json").is_empty());
        assert_eq!(event_of("closewindow>>abc"), Some(closed("abc")));
        assert_eq!(event_of("workspace>>2"), None);
    }

    /// Hyprland's two sockets: its events, sent by the test, and its window
    /// list, answered from <clients>.
    fn hyprland(dir: &Path, clients: &'static str) -> std::os::unix::net::UnixListener {
        use std::io::{Read, Write};
        let hypr = dir.join("hypr");
        fs::create_dir_all(&hypr).unwrap();
        let requests = std::os::unix::net::UnixListener::bind(hypr.join(".socket.sock")).unwrap();
        std::thread::spawn(move || {
            for mut stream in requests.incoming().flatten() {
                let mut asked = [0u8; 64];
                let n = stream.read(&mut asked).unwrap_or(0);
                assert_eq!(&asked[..n], b"j/clients");
                let _ = stream.write_all(clients.as_bytes());
            }
        });
        std::os::unix::net::UnixListener::bind(hypr.join(".socket2.sock")).unwrap()
    }

    #[test]
    fn a_crash_from_the_journal_and_a_window_from_hyprlands_socket_are_said() {
        const REMOTE: &str = "/usr/lib/systemd/systemd-journal-remote";
        if !Path::new(REMOTE).exists() {
            return eprintln!("skipped: no systemd-journal-remote to write a journal with");
        }
        crate::testing::no_real_buses();
        let dir = scratch("crash");
        let journal_dir = dir.join("journal");
        fs::create_dir_all(&journal_dir).unwrap();
        // SAFETY: getuid cannot fail.
        let uid = unsafe { getuid() };
        let write = |at: u64, pid: &str, user: u32| {
            let export = format!(
                "__REALTIME_TIMESTAMP={}\n__MONOTONIC_TIMESTAMP={at}\n_BOOT_ID=0123456789abcdef0123456789abcdef\n\
                 MESSAGE=crashed\nMESSAGE_ID={CRASH}\nCOREDUMP_UID={user}\nCOREDUMP_PID={pid}\n\n",
                1_700_000_000_000_000 + at
            );
            fs::write(dir.join("entry.export"), export).unwrap();
            let written = std::process::Command::new(REMOTE)
                .arg(format!("--output={}/user.journal", journal_dir.display()))
                .arg(dir.join("entry.export"))
                .stderr(std::process::Stdio::null())
                .status()
                .unwrap();
            assert!(written.success());
        };
        // An old crash of the same process, from before the watch: not this one.
        write(1, "4242", uid);
        let journal_dir = journal_dir.clone();
        let mut ctx = crate::testing::context(&dir);
        crate::testing::stub(&dir, "nova-notification-send", "exit 0");
        ctx.hypr = Some(dir.join("hypr"));
        let events = hyprland(
            &dir,
            r#"[{"address":"0xabc","pid":4242,"class":"sketch","initialClass":"sketch"}]"#,
        );
        let folders = vec![dir.join("applications")];
        fs::create_dir_all(&folders[0]).unwrap();
        fs::write(
            folders[0].join("sketch.desktop"),
            "[Desktop Entry]\nName=Sketch\n",
        )
        .unwrap();
        let hypr = dir.join("hypr");
        // The journal is opened on the thread that reads it, as it must be.
        let watcher = std::thread::spawn(move || {
            let source = Source::Active(journal_dir.join("user.journal"));
            follow(&ctx, &hypr, Crashes::open(source).unwrap(), folders)
        });
        let (mut hyprland, _) = events.accept().unwrap();
        // The window goes, its process with it (4242 runs nowhere here)...
        std::io::Write::write_all(&mut hyprland, b"closewindow>>abc\n").unwrap();
        std::thread::sleep(Duration::from_millis(100));
        assert!(crate::testing::calls(&dir).is_empty());
        // ...another user's crash is not this user's...
        write(2, "4242", uid + 1);
        std::thread::sleep(Duration::from_millis(100));
        assert!(crate::testing::calls(&dir).is_empty());
        // ...and its crash comes.
        write(3, "4242", uid);
        crate::testing::wait_until("the notification", || {
            !crate::testing::calls(&dir).is_empty()
        });
        assert_eq!(
            crate::testing::calls(&dir),
            vec!["nova-notification-send -u normal -g \u{f0026} --button Reopen Sketch quit unexpectedly --exec nova-launch -- sketch.desktop"]
        );
        drop(hyprland);
        assert_eq!(
            watcher.join().unwrap().unwrap_err(),
            "Hyprland's events ended"
        );
    }

    #[test]
    fn crashes_are_followed_into_the_file_journald_starts_as_it_rotates_the_last() {
        const REMOTE: &str = "/usr/lib/systemd/systemd-journal-remote";
        if !Path::new(REMOTE).exists() {
            return eprintln!("skipped: no systemd-journal-remote to write a journal with");
        }
        let dir = scratch("rotation");
        let active = dir.join("user-1000.journal");
        // SAFETY: getuid cannot fail.
        let uid = unsafe { getuid() };
        let write = |at: u64, pid: &str| {
            let export = format!(
                "__REALTIME_TIMESTAMP={}\n__MONOTONIC_TIMESTAMP={at}\n_BOOT_ID=0123456789abcdef0123456789abcdef\n\
                 MESSAGE=crashed\nMESSAGE_ID={CRASH}\nCOREDUMP_UID={uid}\nCOREDUMP_PID={pid}\n\n",
                1_700_000_000_000_000 + at
            );
            fs::write(dir.join("entry.export"), export).unwrap();
            let written = std::process::Command::new(REMOTE)
                .arg(format!("--output={}", active.display()))
                .arg(dir.join("entry.export"))
                .stderr(std::process::Stdio::null())
                .status()
                .unwrap();
            assert!(written.success());
        };
        let wait_for = |crashes: &mut Crashes| -> Vec<String> {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let mut fds = [crashes.poll_fd().unwrap()];
                poll(&mut fds, Some(Duration::from_millis(50))).unwrap();
                let pids = crashes.take().unwrap();
                if !pids.is_empty() || Instant::now() > deadline {
                    return pids;
                }
            }
        };
        write(1, "1");
        let mut crashes = Crashes::open(Source::Active(active.clone())).unwrap();
        write(2, "2");
        assert_eq!(wait_for(&mut crashes), vec!["2"]);
        // journald archives the file and starts a new one under its name.
        fs::rename(&active, dir.join("user-1000@0001-0002.journal~")).unwrap();
        write(3, "3");
        assert_eq!(wait_for(&mut crashes), vec!["3"]);
        write(4, "4");
        assert_eq!(wait_for(&mut crashes), vec!["4"]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn entry_folders_follow_xdg_with_the_users_first() {
        // From the environment as it is; only the shape is checked.
        let folders = entry_folders_from_env();
        assert!(folders.len() >= 2);
        assert!(folders.iter().all(|f| f.ends_with("applications")));
    }
}
