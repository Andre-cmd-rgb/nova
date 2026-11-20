//! The file picker apps get when they ask the desktop portal for a file to
//! open or a place to save: xdg-desktop-portal's FileChooser, served as
//! org.freedesktop.impl.portal.desktop.nova (nova.portal, and FileChooser=nova
//! in Nova's hyprland-portals.conf), shown by the shell's file-picker plugin.
//!
//! The portal calls OpenFile, SaveFile or SaveFiles with the request's
//! handle, the app's id, its window, a title and options; the answer is the
//! method's own: 0 and the files' file:// URIs, 1 for a cancel, 2 for
//! anything else. While it is asked, the request is an object at its handle
//! whose Close ends it (the app went, or gave up): the window goes, and the
//! answer is 2.
//!
//! The shell listens on $XDG_RUNTIME_DIR/nova/file-picker.sock, a connection
//! a pick: the duty sends one line ({"type":"pick", the mode, the title, the
//! folder to start in, the filters as globs, the choices, the places}) and
//! reads one back ({"type":"answer","paths":[...],...} or {"type":"cancel"});
//! closing the connection takes the window away. A MIME type in a filter is
//! turned into its globs here, from the shared MIME database, as GTK matches
//! it: with its aliases and its subtypes (text/plain is every text file).
//! Each app's last folder and the hidden files' switch are remembered.
//!
//! Without a shell to ask on, the request goes on to GTK's portal, whose
//! window asks instead.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, PollFd, POLLIN};
use nova_sd::{
    Bus, Deferred, Error, Interface, Message, Slot, Value, ERROR_INVALID_ARGS, NAME_QUEUE,
};

use crate::common::{write_atomically, Context, Waker};
use crate::json::{self, quote, Json};

pub const DUTY: &str = "file-chooser";

const NAME: &str = "org.freedesktop.impl.portal.desktop.nova";
const PATH: &str = "/org/freedesktop/portal/desktop";
const INTERFACE: &str = "org.freedesktop.impl.portal.FileChooser";
const REQUEST: &str = "org.freedesktop.impl.portal.Request";
/// GTK's portal, which asks when the shell cannot.
const GTK: &str = "org.freedesktop.impl.portal.desktop.gtk";
pub const SOCKET: &str = "file-picker.sock";

/// The longest answer the shell may give: many files chosen at once.
const LONGEST: u64 = 4 << 20;
/// How long the shell is waited for while it starts.
const PATIENCE: Duration = Duration::from_secs(3);
/// The apps whose last folder is remembered.
const REMEMBERED: usize = 50;

const SUCCESS: u32 = 0;
const CANCELLED: u32 = 1;
const ENDED: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Open,
    Save,
    Folder,
    SaveFiles,
}

impl Mode {
    fn word(self) -> &'static str {
        match self {
            Mode::Open => "open",
            Mode::Save => "save",
            Mode::Folder => "folder",
            Mode::SaveFiles => "save-files",
        }
    }
}

/// A filter as the app gave it (for the answer) and as globs (for the shell).
#[derive(Debug, Clone, PartialEq)]
pub struct Filter {
    pub name: String,
    pub globs: Vec<String>,
    pub given: Value,
}

/// One of the app's extra options: a list to choose from, or a switch (no
/// options, "true" or "false").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Choice {
    pub id: String,
    pub label: String,
    pub options: Vec<(String, String)>,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Place {
    pub label: String,
    pub path: String,
    pub glyph: &'static str,
}

/// What the window is asked.
#[derive(Debug, Clone, PartialEq)]
pub struct Pick {
    pub mode: Mode,
    pub multiple: bool,
    pub title: String,
    pub app: String,
    pub accept: String,
    pub folder: String,
    pub name: String,
    pub select: String,
    pub files: Vec<String>,
    pub filters: Vec<Filter>,
    pub filter: Option<usize>,
    pub choices: Vec<Choice>,
    pub places: Vec<Place>,
    pub hidden: bool,
}

fn strings(items: &[String]) -> String {
    format!(
        "[{}]",
        items.iter().map(|s| quote(s)).collect::<Vec<_>>().join(",")
    )
}

impl Pick {
    pub fn line(&self) -> String {
        let filters: Vec<String> = self
            .filters
            .iter()
            .map(|f| {
                format!(
                    r#"{{"name":{},"globs":{}}}"#,
                    quote(&f.name),
                    strings(&f.globs)
                )
            })
            .collect();
        let choices: Vec<String> = self
            .choices
            .iter()
            .map(|c| {
                let options: Vec<String> = c
                    .options
                    .iter()
                    .map(|(id, label)| {
                        format!(r#"{{"id":{},"label":{}}}"#, quote(id), quote(label))
                    })
                    .collect();
                format!(
                    r#"{{"id":{},"label":{},"options":[{}],"value":{}}}"#,
                    quote(&c.id),
                    quote(&c.label),
                    options.join(","),
                    quote(&c.value)
                )
            })
            .collect();
        let places: Vec<String> = self
            .places
            .iter()
            .map(|p| {
                format!(
                    r#"{{"label":{},"path":{},"glyph":{}}}"#,
                    quote(&p.label),
                    quote(&p.path),
                    quote(p.glyph)
                )
            })
            .collect();
        format!(
            concat!(
                r#"{{"type":"pick","mode":{},"multiple":{},"title":{},"app":{},"accept":{},"#,
                r#""folder":{},"name":{},"select":{},"files":{},"filters":[{}],"filter":{},"#,
                r#""choices":[{}],"places":[{}],"hidden":{}}}"#
            ),
            quote(self.mode.word()),
            self.multiple,
            quote(&self.title),
            quote(&self.app),
            quote(&self.accept),
            quote(&self.folder),
            quote(&self.name),
            quote(&self.select),
            strings(&self.files),
            filters.join(","),
            self.filter.map_or(-1, |f| f as i64),
            choices.join(","),
            places.join(","),
            self.hidden
        )
    }
}

// ---- the MIME database ---------------------------------------------------------

/// The shared MIME database's globs, aliases and subtypes.
#[derive(Debug, Default)]
pub struct Mime {
    globs: BTreeMap<String, Vec<String>>,
    aliases: HashMap<String, String>,
    parents: HashMap<String, Vec<String>>,
}

impl Mime {
    /// From each <dir>/mime of the data folders.
    pub fn load(data_dirs: &[PathBuf]) -> Mime {
        let mut mime = Mime::default();
        for dir in data_dirs.iter().map(|d| d.join("mime")) {
            let read = |name: &str| fs::read_to_string(dir.join(name)).unwrap_or_default();
            for line in read("globs2").lines().filter(|l| !l.starts_with('#')) {
                // weight:type:glob[:flags]
                let mut parts = line.splitn(4, ':');
                if let (Some(_), Some(kind), Some(glob)) =
                    (parts.next(), parts.next(), parts.next())
                {
                    let globs = mime.globs.entry(kind.to_owned()).or_default();
                    if !globs.iter().any(|g| g == glob) {
                        globs.push(glob.to_owned());
                    }
                }
            }
            for line in read("aliases").lines() {
                if let Some((alias, kind)) = line.split_once(' ') {
                    mime.aliases.insert(alias.to_owned(), kind.to_owned());
                }
            }
            for line in read("subclasses").lines() {
                if let Some((kind, parent)) = line.split_once(' ') {
                    mime.parents
                        .entry(kind.to_owned())
                        .or_default()
                        .push(parent.to_owned());
                }
            }
        }
        mime
    }

    fn canonical<'a>(&'a self, kind: &'a str) -> &'a str {
        self.aliases.get(kind).map_or(kind, String::as_str)
    }

    /// Whether <kind> is <wanted> or one of its subtypes; "image/*" stands
    /// for every image type.
    fn is_a(&self, kind: &str, wanted: &str) -> bool {
        let mut seen = BTreeSet::new();
        let mut todo = vec![kind.to_owned()];
        while let Some(kind) = todo.pop() {
            let kind = self.canonical(&kind).to_owned();
            if !seen.insert(kind.clone()) {
                continue;
            }
            let matches = match wanted.strip_suffix("/*") {
                Some(major) => kind.split('/').next() == Some(major),
                None => kind == wanted,
            };
            if matches {
                return true;
            }
            // Every text type is text/plain to GTK, as the spec says.
            if wanted == "text/plain" && kind.starts_with("text/") {
                return true;
            }
            if let Some(parents) = self.parents.get(&kind) {
                todo.extend(parents.iter().cloned());
            }
        }
        false
    }

    /// The globs of <wanted> and its subtypes.
    pub fn globs_of(&self, wanted: &str) -> Vec<String> {
        if wanted == "*" || wanted == "*/*" || wanted == "application/octet-stream" {
            return vec!["*".into()];
        }
        let wanted = self.canonical(wanted);
        let mut out = Vec::new();
        for (kind, globs) in &self.globs {
            if self.is_a(kind, wanted) {
                for glob in globs {
                    if !out.contains(glob) {
                        out.push(glob.clone());
                    }
                }
            }
        }
        out
    }
}

// ---- the request ---------------------------------------------------------------

/// A NUL-terminated byte string (a path the portal sends as ay) as text.
fn bytes_text(value: Option<&Value>) -> String {
    let Some(mut bytes) = value.and_then(Value::as_bytes) else {
        return String::new();
    };
    while bytes.last() == Some(&0) {
        bytes.pop();
    }
    String::from_utf8(bytes).unwrap_or_default()
}

/// A label without GTK's mnemonic underscores.
fn unmnemonic(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '_' {
            if chars.peek() == Some(&'_') {
                out.push('_');
                chars.next();
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// A filter, (sa(us)): its name, and its patterns (0 a glob, 1 a MIME type).
fn filter(value: &Value, mime: &dyn Fn() -> Rc<Mime>) -> Option<Filter> {
    let Value::Struct(fields) = value.unvariant() else {
        return None;
    };
    let name = fields.first()?.as_str()?.to_owned();
    let mut globs = Vec::new();
    for rule in fields.get(1)?.as_list()? {
        let Value::Struct(rule) = rule else { continue };
        let (Some(kind), Some(pattern)) = (
            rule.first().and_then(Value::as_u64),
            rule.get(1).and_then(Value::as_str),
        ) else {
            continue;
        };
        let found = match kind {
            0 => vec![pattern.to_owned()],
            1 => mime().globs_of(pattern),
            _ => continue,
        };
        for glob in found {
            if !glob.is_empty()
                && !glob.contains('/')
                && !globs.contains(&glob)
                && globs.len() < 2000
            {
                globs.push(glob);
            }
        }
    }
    // A filter nothing is known of shows everything rather than nothing.
    if globs.is_empty() {
        globs.push("*".into());
    }
    let name = if name.trim().is_empty() {
        globs.join(", ")
    } else {
        name
    };
    Some(Filter {
        name,
        globs,
        given: value.unvariant().clone(),
    })
}

fn choices(value: Option<&Value>) -> Vec<Choice> {
    let mut out = Vec::new();
    for choice in value
        .and_then(Value::as_list)
        .unwrap_or(&[])
        .iter()
        .take(64)
    {
        let Value::Struct(fields) = choice else {
            continue;
        };
        let text = |i: usize| {
            fields
                .get(i)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned()
        };
        let (id, label, initial) = (text(0), text(1), text(3));
        if id.is_empty() || out.iter().any(|c: &Choice| c.id == id) {
            continue;
        }
        let options: Vec<(String, String)> = fields
            .get(2)
            .and_then(Value::as_list)
            .unwrap_or(&[])
            .iter()
            .filter_map(|o| match o {
                Value::Struct(pair) => Some((
                    pair.first()?.as_str()?.to_owned(),
                    pair.get(1)?.as_str()?.to_owned(),
                )),
                _ => None,
            })
            .filter(|(id, _)| !id.is_empty())
            .take(64)
            .collect();
        let value = if options.is_empty() {
            if initial == "true" { "true" } else { "false" }.to_owned()
        } else if options.iter().any(|(o, _)| *o == initial) {
            initial
        } else {
            options[0].0.clone()
        };
        out.push(Choice {
            id,
            label: unmnemonic(&label),
            options,
            value,
        });
    }
    out
}

/// What is remembered between picks.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Memory {
    pub hidden: bool,
    /// The last folder of each app, the latest first.
    pub folders: Vec<(String, String)>,
}

impl Memory {
    pub fn read(path: &Path) -> Memory {
        let text = fs::read_to_string(path).unwrap_or_default();
        let mut memory = Memory::default();
        for line in text.lines() {
            if let Some(hidden) = line.strip_prefix("hidden=") {
                memory.hidden = hidden == "1";
            } else if let Some((app, folder)) = line.split_once('\t') {
                memory.folders.push((app.to_owned(), folder.to_owned()));
            }
        }
        memory
    }

    pub fn write(&self, path: &Path) -> io::Result<()> {
        let mut text = format!("hidden={}\n", u8::from(self.hidden));
        for (app, folder) in &self.folders {
            text.push_str(&format!("{app}\t{folder}\n"));
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        write_atomically(path, &text)
    }

    fn folder(&self, app: &str) -> Option<&str> {
        self.folders
            .iter()
            .find(|(a, _)| a == app)
            .map(|(_, f)| f.as_str())
    }

    fn keep(&mut self, app: &str, folder: &str) {
        if app.contains('\t') || app.contains('\n') || folder.contains('\n') {
            return;
        }
        self.folders.retain(|(a, _)| a != app);
        self.folders.insert(0, (app.to_owned(), folder.to_owned()));
        self.folders.truncate(REMEMBERED);
    }
}

/// Where the picker's sidebar goes: home, the user's folders, GTK's
/// bookmarks, the drives mounted, and the whole computer.
pub fn places(home: &Path, config: &Path, mountinfo: &str, user: &str) -> Vec<Place> {
    let mut out: Vec<Place> = Vec::new();
    let mut add = |label: String, path: String, glyph: &'static str| {
        if !out.iter().any(|p| p.path == path) && Path::new(&path).is_dir() {
            out.push(Place { label, path, glyph });
        }
    };
    let home_text = home.to_string_lossy().into_owned();
    add("Home".into(), home_text.clone(), "home");
    let dirs = fs::read_to_string(config.join("user-dirs.dirs")).unwrap_or_default();
    let named: HashMap<String, String> = dirs
        .lines()
        .filter_map(|l| {
            let (key, value) = l.trim().split_once('=')?;
            let key = key.strip_prefix("XDG_")?.strip_suffix("_DIR")?;
            let value = value.trim().trim_matches('"').replace("$HOME", &home_text);
            Some((key.to_owned(), value))
        })
        .collect();
    for (key, label, glyph) in [
        ("DESKTOP", "Desktop", "desktop"),
        ("DOCUMENTS", "Documents", "documents"),
        ("DOWNLOAD", "Downloads", "downloads"),
        ("MUSIC", "Music", "music"),
        ("PICTURES", "Pictures", "pictures"),
        ("VIDEOS", "Videos", "videos"),
    ] {
        let path = named
            .get(key)
            .cloned()
            .unwrap_or_else(|| format!("{home_text}/{label}"));
        if path != home_text {
            add(label.into(), path, glyph);
        }
    }
    let bookmarks = fs::read_to_string(config.join("gtk-3.0/bookmarks")).unwrap_or_default();
    for line in bookmarks.lines() {
        let (uri, label) = line.split_once(' ').unwrap_or((line, ""));
        let Some(path) = uri.strip_prefix("file://").map(unpercent) else {
            continue;
        };
        let label = if label.trim().is_empty() {
            Path::new(&path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.clone())
        } else {
            label.trim().to_owned()
        };
        add(label, path, "bookmark");
    }
    let media = [format!("/run/media/{user}/"), "/media/".to_owned()];
    for line in mountinfo.lines() {
        let Some(point) = line.split(' ').nth(4).map(unoctal) else {
            continue;
        };
        if media
            .iter()
            .any(|m| point.starts_with(m.as_str()) && point.len() > m.len())
        {
            let label = Path::new(&point)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            add(label, point, "drive");
        }
    }
    add("Computer".into(), "/".into(), "computer");
    out
}

/// mountinfo's \040 and the like.
fn unoctal(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\'
            && i + 3 < bytes.len()
            && bytes[i + 1..i + 4]
                .iter()
                .all(|b| (b'0'..=b'7').contains(b))
        {
            out.push(
                (bytes[i + 1] - b'0') * 64 + (bytes[i + 2] - b'0') * 8 + (bytes[i + 3] - b'0'),
            );
            i += 4;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn unpercent(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16).map(|d| d as u8);
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A path as a file:// URI: every byte but the unreserved ones and "/"
/// percent-encoded.
pub fn uri(path: &str) -> String {
    let mut out = String::from("file://");
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"/-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// The portal's call, read: what the window is asked.
pub struct Request<'a> {
    pub mode: Mode,
    pub app_id: &'a str,
    pub title: &'a str,
    pub options: &'a Value,
}

pub fn pick(
    request: &Request,
    mime: &dyn Fn() -> Rc<Mime>,
    memory: &Memory,
    places: Vec<Place>,
    app: String,
    home: &str,
) -> Pick {
    let o = request.options;
    let flag = |key: &str| o.get(key).and_then(Value::as_bool).unwrap_or(false);
    let mut mode = request.mode;
    if mode == Mode::Open && flag("directory") {
        mode = Mode::Folder;
    }
    let mut filters: Vec<Filter> = o
        .get("filters")
        .and_then(Value::as_list)
        .unwrap_or(&[])
        .iter()
        .take(64)
        .filter_map(|f| filter(f, mime))
        .collect();
    if mode == Mode::Folder || mode == Mode::SaveFiles {
        filters.clear();
    }
    let current = o.get("current_filter").and_then(|f| filter(f, mime));
    let mut chosen = None;
    if let Some(current) = current.filter(|_| mode == Mode::Open || mode == Mode::Save) {
        chosen = filters.iter().position(|f| f.name == current.name);
        if chosen.is_none() && filters.is_empty() {
            filters.push(current);
            chosen = Some(0);
        }
    }
    if chosen.is_none() && !filters.is_empty() {
        chosen = Some(0);
    }
    let is_dir = |p: &str| !p.is_empty() && p.starts_with('/') && Path::new(p).is_dir();
    let current_file = if mode == Mode::Save {
        bytes_text(o.get("current_file"))
    } else {
        String::new()
    };
    let mut name = if mode == Mode::Save {
        o.get("current_name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned()
    } else {
        String::new()
    };
    let mut folder = bytes_text(o.get("current_folder"));
    let mut select = String::new();
    if current_file.starts_with('/') {
        let file = Path::new(&current_file);
        if let Some(parent) = file.parent().map(|p| p.to_string_lossy().into_owned()) {
            if !is_dir(&folder) {
                folder = parent;
            }
        }
        if name.is_empty() {
            name = file
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
        }
        select = current_file.clone();
    }
    if !is_dir(&folder) {
        folder = memory
            .folder(request.app_id)
            .filter(|f| is_dir(f))
            .unwrap_or(home)
            .to_owned();
    }
    let files: Vec<String> = if mode == Mode::SaveFiles {
        o.get("files")
            .and_then(Value::as_list)
            .unwrap_or(&[])
            .iter()
            .map(|f| bytes_text(Some(f)))
            .filter_map(|f| {
                Path::new(&f)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
            })
            .collect()
    } else {
        Vec::new()
    };
    let accept = o
        .get("accept_label")
        .and_then(Value::as_str)
        .map(unmnemonic)
        .unwrap_or_default();
    Pick {
        mode,
        multiple: matches!(mode, Mode::Open | Mode::Folder) && flag("multiple"),
        title: unmnemonic(request.title).trim().to_owned(),
        app,
        accept: accept.trim().to_owned(),
        folder,
        name,
        select,
        files,
        filters,
        filter: chosen,
        choices: choices(o.get("choices")),
        places,
        hidden: memory.hidden,
    }
}

/// SaveFiles' names in <folder>: each of <files>, or "name(1).ext" and on
/// where one is there already, as GTK's portal does.
pub fn save_names(folder: &str, files: &[String], exists: &dyn Fn(&str) -> bool) -> Vec<String> {
    let mut taken: Vec<String> = Vec::new();
    for file in files {
        let (stem, rest) = match file.find('.') {
            Some(0) | None => (file.as_str(), ""),
            Some(i) => (&file[..i], &file[i..]),
        };
        let mut path = format!("{folder}/{file}");
        let mut n = 1;
        while exists(&path) || taken.contains(&path) {
            path = format!("{folder}/{stem}({n}){rest}");
            n += 1;
        }
        taken.push(path);
    }
    taken
}

/// The window's answer as the portal's results; none for one that does not
/// fit what was asked.
pub fn results(
    pick: &Pick,
    answer: &Json,
    exists: &dyn Fn(&str) -> bool,
) -> Option<(Vec<(&'static str, Value)>, String)> {
    let paths: Vec<String> = answer
        .get("paths")?
        .as_array()?
        .iter()
        .filter_map(|p| p.as_str().map(str::to_owned))
        .filter(|p| p.starts_with('/') && !p.contains('\0'))
        .collect();
    let fits = match pick.mode {
        Mode::Open | Mode::Folder => !paths.is_empty() && (pick.multiple || paths.len() == 1),
        Mode::Save | Mode::SaveFiles => paths.len() == 1,
    };
    if !fits {
        return None;
    }
    let (uris, kept) = match pick.mode {
        Mode::SaveFiles => {
            let names = save_names(&paths[0], &pick.files, exists);
            (
                names.iter().map(|p| uri(p)).collect::<Vec<_>>(),
                paths[0].clone(),
            )
        }
        Mode::Folder => (paths.iter().map(|p| uri(p)).collect(), paths[0].clone()),
        _ => {
            let folder = Path::new(&paths[0])
                .parent()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            (paths.iter().map(|p| uri(p)).collect(), folder)
        }
    };
    let mut out = vec![("uris", Value::strings(&uris))];
    let said = answer.get("choices");
    let chosen: Vec<Value> = pick
        .choices
        .iter()
        .map(|c| {
            let given = said
                .and_then(|s| s.get(&c.id))
                .and_then(Json::as_str)
                .unwrap_or("");
            let valid = if c.options.is_empty() {
                given == "true" || given == "false"
            } else {
                c.options.iter().any(|(id, _)| id == given)
            };
            let value = if valid { given } else { c.value.as_str() };
            Value::Struct(vec![Value::str(c.id.clone()), Value::str(value)])
        })
        .collect();
    if !chosen.is_empty() {
        out.push(("choices", Value::Array("(ss)".into(), chosen)));
    }
    if pick.mode != Mode::SaveFiles {
        let index = answer
            .get("filter")
            .and_then(Json::as_f64)
            .filter(|i| *i >= 0.0)
            .map(|i| i as usize);
        if let Some(filter) = index.or(pick.filter).and_then(|i| pick.filters.get(i)) {
            out.push(("current_filter", filter.given.clone()));
        }
    }
    if pick.mode == Mode::Open || pick.mode == Mode::Folder {
        out.push(("writable", Value::Bool(true)));
    }
    Some((out, kept))
}

// ---- the duty --------------------------------------------------------------------

/// How the window's pick ended.
#[derive(Debug)]
enum Outcome {
    NoShell,
    Cancelled,
    Answer(Json),
    Failed,
}

/// A pick being answered.
struct Pending {
    deferred: Option<Deferred>,
    member: String,
    args: Vec<Value>,
    pick: Pick,
    app_id: String,
    /// The request's object, for its Close.
    _request: Option<Slot>,
    forwarded: bool,
}

enum Call {
    Start(u64),
    Close(u64),
}

#[derive(Default)]
struct State {
    pending: HashMap<u64, Pending>,
    calls: Vec<Call>,
    count: u64,
}

/// Where the duty finds what it reads.
#[derive(Clone)]
pub struct Setup {
    pub home: PathBuf,
    pub config: PathBuf,
    pub state: PathBuf,
    pub data_dirs: Vec<PathBuf>,
    pub user: String,
    pub patience: Duration,
}

impl Setup {
    fn from_env() -> Setup {
        let env = |key: &str| {
            std::env::var_os(key)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        let home = env("HOME").unwrap_or_else(|| PathBuf::from("/"));
        Setup {
            config: env("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config")),
            state: env("XDG_STATE_HOME").unwrap_or_else(|| home.join(".local/state")),
            data_dirs: crate::share::data_dirs(),
            user: std::env::var("USER").unwrap_or_default(),
            home,
            patience: PATIENCE,
        }
    }

    fn memory(&self) -> PathBuf {
        self.state.join("nova/file-picker")
    }
}

fn mode_of(member: &str) -> Option<Mode> {
    match member {
        "OpenFile" => Some(Mode::Open),
        "SaveFile" => Some(Mode::Save),
        "SaveFiles" => Some(Mode::SaveFiles),
        _ => None,
    }
}

fn reply(deferred: Deferred, code: u32, results: Vec<(&str, Value)>) {
    let _ = deferred.reply(Ok(vec![Value::Uint32(code), Value::options(results)]));
}

fn handle(
    bus: &Bus,
    state: &Rc<RefCell<State>>,
    setup: &Setup,
    call: &Message,
    args: Vec<Value>,
) -> Result<Vec<Value>, Error> {
    let member = call.member().unwrap_or("").to_owned();
    let mode = mode_of(&member).ok_or_else(|| Error::bus(ERROR_INVALID_ARGS, "no such method"))?;
    let handle = args
        .first()
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let app_id = args.get(1).and_then(Value::as_str).unwrap_or("").to_owned();
    let title = args.get(3).and_then(Value::as_str).unwrap_or("").to_owned();
    let empty = Value::options(Vec::<(&str, Value)>::new());
    let options = args.get(4).unwrap_or(&empty);
    let request = Request {
        mode,
        app_id: &app_id,
        title: &title,
        options,
    };
    let mime: RefCell<Option<Rc<Mime>>> = RefCell::new(None);
    let load = || {
        mime.borrow_mut()
            .get_or_insert_with(|| Rc::new(Mime::load(&setup.data_dirs)))
            .clone()
    };
    let mountinfo = fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    let app = if app_id.is_empty() {
        String::new()
    } else {
        crate::share::app_name(&app_id, &setup.data_dirs)
    };
    let app = if app == app_id && app_id.contains('.') {
        String::new()
    } else {
        app
    };
    let pick = pick(
        &request,
        &load,
        &Memory::read(&setup.memory()),
        places(&setup.home, &setup.config, &mountinfo, &setup.user),
        app,
        &setup.home.to_string_lossy(),
    );
    let deferred = call.defer()?;
    let mut s = state.borrow_mut();
    s.count += 1;
    let id = s.count;
    let weak = Rc::downgrade(state);
    let request = bus
        .export(
            &handle,
            vec![Interface::new(REQUEST).method("Close", "", "")],
            move |_: &Message, _: Vec<Value>| {
                if let Some(state) = weak.upgrade() {
                    state.borrow_mut().calls.push(Call::Close(id));
                }
                Ok(vec![])
            },
        )
        .ok();
    s.pending.insert(
        id,
        Pending {
            deferred: Some(deferred),
            member,
            args,
            pick,
            app_id,
            _request: request,
            forwarded: false,
        },
    );
    s.calls.push(Call::Start(id));
    Ok(vec![])
}

/// One pick on the shell's window, on its own thread.
fn ask(
    socket: PathBuf,
    id: u64,
    line: String,
    patience: Duration,
    streams: Arc<Mutex<HashMap<u64, UnixStream>>>,
) -> Outcome {
    let since = Instant::now();
    let stream = loop {
        match UnixStream::connect(&socket) {
            Ok(stream) => break stream,
            Err(_) if since.elapsed() < patience => thread::sleep(Duration::from_millis(100)),
            Err(_) => return Outcome::NoShell,
        }
    };
    if let Ok(clone) = stream.try_clone() {
        streams.lock().unwrap().insert(id, clone);
    }
    let outcome = (|| {
        (&stream).write_all(format!("{line}\n").as_bytes()).ok()?;
        let mut answer = Vec::new();
        BufReader::new(&stream)
            .take(LONGEST)
            .read_until(b'\n', &mut answer)
            .ok()?;
        let doc = std::str::from_utf8(&answer).ok().and_then(json::parse)?;
        match doc.get("type").and_then(Json::as_str) {
            Some("answer") => Some(Outcome::Answer(doc)),
            Some("cancel") => Some(Outcome::Cancelled),
            _ => None,
        }
    })()
    .unwrap_or(Outcome::Failed);
    streams.lock().unwrap().remove(&id);
    let _ = stream.shutdown(Shutdown::Both);
    outcome
}

struct Chooser<'a> {
    ctx: &'a Context,
    bus: &'a Bus,
    setup: Setup,
    state: Rc<RefCell<State>>,
    outcomes: Sender<(u64, Outcome)>,
    waker: Arc<Waker>,
    streams: Arc<Mutex<HashMap<u64, UnixStream>>>,
}

impl Chooser<'_> {
    fn take(&self, call: Call) {
        match call {
            Call::Start(id) => self.start(id),
            Call::Close(id) => self.close(id),
        }
    }

    fn start(&self, id: u64) {
        let Some(line) = self.state.borrow().pending.get(&id).map(|p| p.pick.line()) else {
            return;
        };
        let socket = self.ctx.runtime.join(SOCKET);
        let (outcomes, waker, streams, patience) = (
            self.outcomes.clone(),
            self.waker.clone(),
            self.streams.clone(),
            self.setup.patience,
        );
        let spawned = thread::Builder::new()
            .name("file-picker".into())
            .stack_size(256 * 1024)
            .spawn(move || {
                let outcome = ask(socket, id, line, patience, streams);
                let _ = outcomes.send((id, outcome));
                waker.wake();
            });
        if spawned.is_err() {
            self.finish(id, ENDED, Vec::new());
        }
    }

    /// The request's Close: the window goes, and the answer is 2.
    fn close(&self, id: u64) {
        let Some(pending) = self.state.borrow_mut().pending.remove(&id) else {
            return;
        };
        if let Some(stream) = self.streams.lock().unwrap().remove(&id) {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if pending.forwarded {
            let handle = pending.args.first().and_then(Value::as_str).unwrap_or("");
            let _ = self.bus.call_no_reply(GTK, handle, REQUEST, "Close", &[]);
        }
        if let Some(deferred) = pending.deferred {
            reply(deferred, ENDED, Vec::new());
        }
    }

    fn finish(&self, id: u64, code: u32, results: Vec<(&str, Value)>) {
        let Some(pending) = self.state.borrow_mut().pending.remove(&id) else {
            return;
        };
        if let Some(deferred) = pending.deferred {
            reply(deferred, code, results);
        }
    }

    fn outcome(&self, id: u64, outcome: Outcome) {
        match outcome {
            Outcome::NoShell => self.forward(id),
            Outcome::Cancelled => self.finish(id, CANCELLED, Vec::new()),
            Outcome::Failed => self.finish(id, ENDED, Vec::new()),
            Outcome::Answer(doc) => {
                let answered = {
                    let s = self.state.borrow();
                    let Some(pending) = s.pending.get(&id) else {
                        return;
                    };
                    let exists = |p: &str| Path::new(p).symlink_metadata().is_ok();
                    results(&pending.pick, &doc, &exists)
                        .map(|(r, kept)| (r, kept, pending.app_id.clone()))
                };
                let Some((results, kept, app_id)) = answered else {
                    return self.finish(id, ENDED, Vec::new());
                };
                let mut memory = Memory::read(&self.setup.memory());
                memory.hidden = doc
                    .get("hidden")
                    .map(|h| matches!(h, Json::Bool(true)))
                    .unwrap_or(memory.hidden);
                memory.keep(&app_id, &kept);
                if let Err(e) = memory.write(&self.setup.memory()) {
                    eprintln!("{DUTY}: could not remember the folder: {e}");
                }
                self.finish(id, SUCCESS, results);
            }
        }
    }

    /// No shell: GTK's portal asks, and its answer is the answer.
    fn forward(&self, id: u64) {
        let mut s = self.state.borrow_mut();
        let Some(pending) = s.pending.get_mut(&id) else {
            return;
        };
        pending.forwarded = true;
        let weak = Rc::downgrade(&self.state);
        let sent = self.bus.call_async(
            GTK,
            PATH,
            INTERFACE,
            &pending.member,
            &pending.args,
            // A window waits for its user as long as it takes.
            Some(Duration::from_micros(u64::MAX)),
            move |answer| {
                let Some(state) = weak.upgrade() else { return };
                let Some(pending) = state.borrow_mut().pending.remove(&id) else {
                    return;
                };
                if let Some(deferred) = pending.deferred {
                    match answer {
                        Ok(values) => {
                            let _ = deferred.reply(Ok(values));
                        }
                        Err(_) => reply(deferred, ENDED, Vec::new()),
                    }
                }
            },
        );
        if sent.is_err() {
            drop(s);
            self.finish(id, ENDED, Vec::new());
        }
    }
}

pub fn serve(bus: &Bus, ctx: &Context, setup: Setup) -> Result<(), String> {
    let waker = Arc::new(Waker::new().map_err(|e| format!("cannot make a waker: {e}"))?);
    let (outcomes, ended) = mpsc::channel();
    let state: Rc<RefCell<State>> = Rc::default();
    let (handler_state, handler_bus, handler_setup) = (state.clone(), bus.clone(), setup.clone());
    let _object = bus
        .export(
            PATH,
            vec![Interface::new(INTERFACE)
                .method("OpenFile", "osssa{sv}", "ua{sv}")
                .method("SaveFile", "osssa{sv}", "ua{sv}")
                .method("SaveFiles", "osssa{sv}", "ua{sv}")],
            move |call: &Message, args: Vec<Value>| {
                handle(&handler_bus, &handler_state, &handler_setup, call, args)
            },
        )
        .map_err(|e| format!("cannot put the file chooser on the bus: {e}"))?;
    bus.request_name(NAME, NAME_QUEUE)
        .map_err(|e| format!("cannot ask for {NAME}: {e}"))?;
    let chooser = Chooser {
        ctx,
        bus,
        setup,
        state: state.clone(),
        outcomes,
        waker: waker.clone(),
        streams: Arc::default(),
    };
    loop {
        let mut fds = [bus.poll_fd(), PollFd::new(waker.fd(), POLLIN)];
        if let Err(e) = poll(&mut fds, bus.timeout()) {
            return Err(format!("could not wait: {e}"));
        }
        if let Err(e) = bus.dispatch() {
            return Err(format!("the session bus went: {e}"));
        }
        let calls = std::mem::take(&mut state.borrow_mut().calls);
        for call in calls {
            chooser.take(call);
        }
        if fds[1].ready() {
            waker.drain();
            while let Ok((id, outcome)) = ended.try_recv() {
                chooser.outcome(id, outcome);
            }
        }
    }
}

pub fn run(ctx: &Context) -> Result<(), String> {
    let bus = Bus::user().map_err(|e| e.to_string())?;
    serve(&bus, ctx, Setup::from_env())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::context;
    use nova_sd::testing::{scratch, PrivateBus};
    use std::os::unix::net::UnixListener;

    fn rule(kind: u32, pattern: &str) -> Value {
        Value::Struct(vec![Value::Uint32(kind), Value::str(pattern)])
    }

    fn filter_value(name: &str, rules: Vec<Value>) -> Value {
        Value::Struct(vec![Value::str(name), Value::Array("(us)".into(), rules)])
    }

    fn filters_value(filters: Vec<Value>) -> Value {
        Value::Array("(sa(us))".into(), filters)
    }

    fn path_bytes(path: &str) -> Value {
        let mut bytes: Vec<Value> = path.bytes().map(Value::Byte).collect();
        bytes.push(Value::Byte(0));
        Value::Array("y".into(), bytes)
    }

    fn mime_dir(dir: &Path) -> PathBuf {
        let data = dir.join("data");
        fs::create_dir_all(data.join("mime")).unwrap();
        fs::write(
            data.join("mime/globs2"),
            "# generated\n50:text/plain:*.txt\n50:text/x-python:*.py\n50:text/rust:*.rs\n50:image/png:*.png\n\
             50:image/jpeg:*.jpg\n50:image/jpeg:*.jpeg\n50:application/pdf:*.pdf\n50:application/x-shellscript:*.sh\n",
        )
        .unwrap();
        fs::write(
            data.join("mime/aliases"),
            "application/x-pdf application/pdf\n",
        )
        .unwrap();
        fs::write(
            data.join("mime/subclasses"),
            "text/x-python text/plain\napplication/x-shellscript text/plain\n",
        )
        .unwrap();
        data
    }

    #[test]
    fn mime_types_are_their_globs_with_aliases_and_subtypes() {
        let dir = scratch("fc-mime");
        let mime = Mime::load(&[mime_dir(&dir)]);
        let mut text = mime.globs_of("text/plain");
        text.sort();
        assert_eq!(text, ["*.py", "*.rs", "*.sh", "*.txt"]);
        assert_eq!(mime.globs_of("image/*"), ["*.jpg", "*.jpeg", "*.png"]);
        assert_eq!(mime.globs_of("application/x-pdf"), ["*.pdf"]);
        assert_eq!(mime.globs_of("application/octet-stream"), ["*"]);
        assert!(mime.globs_of("audio/flac").is_empty());
    }

    #[test]
    fn filters_and_choices_are_read_as_the_portal_sends_them() {
        let dir = scratch("fc-filters");
        let mime = Rc::new(Mime::load(&[mime_dir(&dir)]));
        let load = || mime.clone();
        let f = filter(
            &filter_value(
                "Images",
                vec![rule(1, "image/png"), rule(0, "*.[gG][iI][fF]")],
            ),
            &load,
        )
        .unwrap();
        assert_eq!(
            (f.name.as_str(), f.globs.clone()),
            (
                "Images",
                vec!["*.png".to_string(), "*.[gG][iI][fF]".to_string()]
            )
        );
        let f = filter(&filter_value("", vec![rule(0, "*.md")]), &load).unwrap();
        assert_eq!(f.name, "*.md");
        let f = filter(&filter_value("Sound", vec![rule(1, "audio/flac")]), &load).unwrap();
        assert_eq!(f.globs, ["*"]);

        let given = Value::Array(
            "(ssa(ss)s)".into(),
            vec![
                Value::Struct(vec![
                    Value::str("encoding"),
                    Value::str("_Encoding"),
                    Value::Array(
                        "(ss)".into(),
                        vec![
                            Value::Struct(vec![Value::str("utf8"), Value::str("UTF-8")]),
                            Value::Struct(vec![Value::str("latin1"), Value::str("Western")]),
                        ],
                    ),
                    Value::str("nonsense"),
                ]),
                Value::Struct(vec![
                    Value::str("bom"),
                    Value::str("Byte order mark"),
                    Value::Array("(ss)".into(), vec![]),
                    Value::str("true"),
                ]),
                Value::Struct(vec![
                    Value::str("bom"),
                    Value::str("Twice"),
                    Value::Array("(ss)".into(), vec![]),
                    Value::str(""),
                ]),
            ],
        );
        let read = choices(Some(&given));
        assert_eq!(read.len(), 2, "an id given twice is once");
        assert_eq!(
            (read[0].label.as_str(), read[0].value.as_str()),
            ("Encoding", "utf8")
        );
        assert_eq!((read[1].options.len(), read[1].value.as_str()), (0, "true"));
    }

    #[test]
    fn places_are_home_the_users_folders_bookmarks_and_drives() {
        let dir = scratch("fc-places");
        let home = dir.join("home");
        for d in [
            "Desktop",
            "Docs",
            "Downloads",
            "Pictures",
            "Projects",
            "My Stuff",
        ] {
            fs::create_dir_all(home.join(d)).unwrap();
        }
        let config = home.join(".config");
        fs::create_dir_all(config.join("gtk-3.0")).unwrap();
        fs::write(
            config.join("user-dirs.dirs"),
            "XDG_DOCUMENTS_DIR=\"$HOME/Docs\"\nXDG_MUSIC_DIR=\"$HOME\"\n",
        )
        .unwrap();
        let h = home.display();
        fs::write(
            config.join("gtk-3.0/bookmarks"),
            format!("file://{h}/Projects Projects\nfile://{h}/My%20Stuff\nfile://{h}/Downloads Again\nsftp://x/ Server\n"),
        )
        .unwrap();
        let media = dir.join("run/media/ann/STICK ONE");
        fs::create_dir_all(&media).unwrap();
        let media_text = media.display().to_string().replace(' ', "\\040");
        let mountinfo = format!("36 35 98:0 / / rw - ext4 /dev/root rw\n40 35 8:17 / {media_text} rw - vfat /dev/sdb1 rw\n");
        // The test's media folder is not /run/media: the user name is the
        // scratch's path, so that it counts.
        let user = format!("{}/run/media/ann", dir.display()).replacen("/run/media/", "", 0);
        let found = places(&home, &config, &mountinfo, &user);
        let found: Vec<(&str, &str)> = found.iter().map(|p| (p.label.as_str(), p.glyph)).collect();
        assert_eq!(
            &found[..6],
            &[
                ("Home", "home"),
                ("Desktop", "desktop"),
                ("Documents", "documents"),
                ("Downloads", "downloads"),
                ("Pictures", "pictures"),
                ("Projects", "bookmark"),
            ]
        );
        assert!(found.contains(&("My Stuff", "bookmark")));
        assert_eq!(found.last(), Some(&("Computer", "computer")));
        assert_eq!(
            unoctal("/run/media/a/STICK\\040ONE"),
            "/run/media/a/STICK ONE"
        );
        assert_eq!(unpercent("/a%20b%zz%"), "/a b%zz%");
    }

    #[test]
    fn uris_and_save_names_are_the_portals() {
        assert_eq!(
            uri("/home/a/My File #1 ü.txt"),
            "file:///home/a/My%20File%20%231%20%C3%BC.txt"
        );
        let taken = ["/f/a.txt", "/f/a(1).txt", "/f/notes.tar.gz"];
        let exists = |p: &str| taken.contains(&p);
        assert_eq!(
            save_names(
                "/f",
                &[
                    "a.txt".into(),
                    "b".into(),
                    "notes.tar.gz".into(),
                    "b".into(),
                    ".hidden".into()
                ],
                &exists
            ),
            [
                "/f/a(2).txt",
                "/f/b",
                "/f/notes(1).tar.gz",
                "/f/b(1)",
                "/f/.hidden"
            ]
        );
    }

    fn setup(dir: &Path) -> Setup {
        let home = dir.join("home");
        fs::create_dir_all(home.join("Pictures")).unwrap();
        Setup {
            config: home.join(".config"),
            state: home.join(".local/state"),
            data_dirs: vec![mime_dir(dir)],
            user: "ann".into(),
            home,
            patience: Duration::from_millis(200),
        }
    }

    #[test]
    fn a_pick_says_what_the_app_asked() {
        let dir = scratch("fc-pick");
        let setup = setup(&dir);
        let mime = Rc::new(Mime::load(&setup.data_dirs));
        let load = || mime.clone();
        let home = setup.home.to_string_lossy().into_owned();
        let pictures = format!("{home}/Pictures");
        let options = Value::options(vec![
            ("directory", Value::Bool(false)),
            ("multiple", Value::Bool(true)),
            ("accept_label", Value::str("_Import")),
            (
                "filters",
                filters_value(vec![
                    filter_value("Text", vec![rule(1, "text/plain")]),
                    filter_value("Images", vec![rule(1, "image/*")]),
                ]),
            ),
            (
                "current_filter",
                filter_value("Images", vec![rule(1, "image/*")]),
            ),
            ("current_folder", path_bytes(&pictures)),
        ]);
        let request = Request {
            mode: Mode::Open,
            app_id: "org.gnome.Loupe",
            title: "Open Image",
            options: &options,
        };
        let p = pick(
            &request,
            &load,
            &Memory::default(),
            Vec::new(),
            "Image Viewer".into(),
            &home,
        );
        assert_eq!(
            (p.mode, p.multiple, p.accept.as_str(), p.folder.as_str()),
            (Mode::Open, true, "Import", pictures.as_str())
        );
        assert_eq!(p.filter, Some(1));
        let line = json::parse(&p.line()).unwrap();
        assert_eq!(line.get("mode").and_then(Json::as_str), Some("open"));
        assert_eq!(line.get("filter").and_then(Json::as_f64), Some(1.0));
        assert_eq!(
            line.get("filters")
                .and_then(Json::as_array)
                .map(|f| f.len()),
            Some(2)
        );
        assert_eq!(line.get("app").and_then(Json::as_str), Some("Image Viewer"));

        // A folder; nowhere given: where the app last was, else home.
        let options = Value::options(vec![
            ("directory", Value::Bool(true)),
            (
                "filters",
                filters_value(vec![filter_value("x", vec![rule(0, "*")])]),
            ),
        ]);
        let request = Request {
            mode: Mode::Open,
            app_id: "code",
            title: "",
            options: &options,
        };
        let mut memory = Memory::default();
        let p = pick(&request, &load, &memory, Vec::new(), String::new(), &home);
        assert_eq!(
            (p.mode, p.folder.as_str(), p.filters.len(), p.filter),
            (Mode::Folder, home.as_str(), 0, None)
        );
        memory.keep("code", &pictures);
        memory.keep("code", &pictures);
        assert_eq!(memory.folders.len(), 1);
        let p = pick(&request, &load, &memory, Vec::new(), String::new(), &home);
        assert_eq!(p.folder, pictures);

        // Saving over a file the app names: its folder, its name, chosen.
        let options = Value::options(vec![(
            "current_file",
            path_bytes(&format!("{pictures}/cat.png")),
        )]);
        let request = Request {
            mode: Mode::Save,
            app_id: "",
            title: "Save _As",
            options: &options,
        };
        let p = pick(
            &request,
            &load,
            &Memory::default(),
            Vec::new(),
            String::new(),
            &home,
        );
        assert_eq!(
            (p.title.as_str(), p.folder.as_str(), p.name.as_str()),
            ("Save As", pictures.as_str(), "cat.png")
        );
        assert_eq!(p.select, format!("{pictures}/cat.png"));

        let options = Value::options(vec![(
            "files",
            Value::Array(
                "ay".into(),
                vec![path_bytes("/tmp/one.txt"), path_bytes("two.txt")],
            ),
        )]);
        let request = Request {
            mode: Mode::SaveFiles,
            app_id: "",
            title: "",
            options: &options,
        };
        let p = pick(
            &request,
            &load,
            &Memory::default(),
            Vec::new(),
            String::new(),
            &home,
        );
        assert_eq!(p.files, ["one.txt", "two.txt"]);
    }

    #[test]
    fn the_answer_is_checked_against_the_pick() {
        let dir = scratch("fc-results");
        let setup = setup(&dir);
        let mime = Rc::new(Mime::load(&setup.data_dirs));
        let load = || mime.clone();
        let options = Value::options(vec![
            (
                "filters",
                filters_value(vec![
                    filter_value("Text", vec![rule(0, "*.txt")]),
                    filter_value("All", vec![rule(0, "*")]),
                ]),
            ),
            (
                "choices",
                Value::Array(
                    "(ssa(ss)s)".into(),
                    vec![Value::Struct(vec![
                        Value::str("bom"),
                        Value::str("BOM"),
                        Value::Array("(ss)".into(), vec![]),
                        Value::str("false"),
                    ])],
                ),
            ),
        ]);
        let request = Request {
            mode: Mode::Open,
            app_id: "",
            title: "",
            options: &options,
        };
        let p = pick(
            &request,
            &load,
            &Memory::default(),
            Vec::new(),
            String::new(),
            "/",
        );
        let answer = json::parse(r#"{"type":"answer","paths":["/d/a b.txt"],"filter":1,"choices":{"bom":"true"},"hidden":true}"#).unwrap();
        let (r, kept) = results(&p, &answer, &|_| false).unwrap();
        assert_eq!(kept, "/d");
        assert_eq!(r[0], ("uris", Value::strings(&["file:///d/a%20b.txt"])));
        assert_eq!(
            r[1],
            (
                "choices",
                Value::Array(
                    "(ss)".into(),
                    vec![Value::Struct(vec![Value::str("bom"), Value::str("true")])]
                )
            )
        );
        assert_eq!(r[2].0, "current_filter");
        assert_eq!(r[2].1, filter_value("All", vec![rule(0, "*")]));
        assert_eq!(r[3], ("writable", Value::Bool(true)));

        let two = json::parse(r#"{"type":"answer","paths":["/a","/b"]}"#).unwrap();
        assert!(
            results(&p, &two, &|_| false).is_none(),
            "two files where one was asked for"
        );
        let none = json::parse(r#"{"type":"answer","paths":[]}"#).unwrap();
        assert!(results(&p, &none, &|_| false).is_none());
        let relative = json::parse(r#"{"type":"answer","paths":["a.txt"]}"#).unwrap();
        assert!(results(&p, &relative, &|_| false).is_none());
        let bad_choice =
            json::parse(r#"{"type":"answer","paths":["/a"],"choices":{"bom":"maybe"}}"#).unwrap();
        let (r, _) = results(&p, &bad_choice, &|_| false).unwrap();
        assert_eq!(
            r[1].1,
            Value::Array(
                "(ss)".into(),
                vec![Value::Struct(vec![Value::str("bom"), Value::str("false")])]
            )
        );
    }

    #[test]
    fn memory_is_kept_between_picks() {
        let dir = scratch("fc-memory");
        let path = dir.join("state/nova/file-picker");
        let mut memory = Memory {
            hidden: true,
            folders: Vec::new(),
        };
        for n in 0..60 {
            memory.keep(&format!("app{n}"), &format!("/f{n}"));
        }
        memory.keep("bad\tid", "/x");
        memory.write(&path).unwrap();
        let read = Memory::read(&path);
        assert!(read.hidden);
        assert_eq!(read.folders.len(), REMEMBERED);
        assert_eq!(read.folders[0], ("app59".to_string(), "/f59".to_string()));
        assert_eq!(read.folder("app10"), Some("/f10"));
        assert_eq!(read.folder("app9"), None);
    }

    // ---- on a bus ----

    /// The shell's window: each pick heard, answered with the next answer
    /// (none: held open, its closing reported).
    struct Shell {
        heard: mpsc::Receiver<String>,
        closed: mpsc::Receiver<()>,
    }

    fn shell(runtime: &Path, answers: Vec<Option<&'static str>>) -> Shell {
        fs::create_dir_all(runtime).unwrap();
        let listener = UnixListener::bind(runtime.join(SOCKET)).unwrap();
        let (tx, heard) = mpsc::channel();
        let (closed_tx, closed) = mpsc::channel();
        thread::spawn(move || {
            for (stream, answer) in listener.incoming().zip(answers) {
                let stream = stream.unwrap();
                let mut line = String::new();
                BufReader::new(&stream).read_line(&mut line).unwrap();
                tx.send(line).unwrap();
                match answer {
                    Some(answer) => writeln!(&stream, "{answer}").unwrap(),
                    None => {
                        let mut rest = Vec::new();
                        let _ = (&stream).read_to_end(&mut rest);
                        closed_tx.send(()).unwrap();
                    }
                }
            }
        });
        Shell { heard, closed }
    }

    fn start(dir: &Path) -> Option<(PrivateBus, Context, Setup)> {
        let bus = PrivateBus::start()?;
        let ctx = context(dir);
        let setup = setup(dir);
        let (address, duty_ctx, duty_setup) = (bus.address.clone(), ctx.clone(), setup.clone());
        thread::spawn(move || {
            let bus = Bus::connect(&address).unwrap();
            let _ = serve(&bus, &duty_ctx, duty_setup);
        });
        let probe = Bus::connect(&bus.address).unwrap();
        let until = Instant::now() + Duration::from_secs(5);
        while probe.name_owner(NAME).unwrap().is_none() {
            assert!(Instant::now() < until, "the duty never held {NAME}");
            thread::sleep(Duration::from_millis(10));
        }
        Some((bus, ctx, setup))
    }

    fn args(handle: &str, options: Value) -> Vec<Value> {
        vec![
            Value::path(handle),
            Value::str(""),
            Value::str(""),
            Value::str("Open a File"),
            options,
        ]
    }

    fn no_options() -> Value {
        Value::options(Vec::<(&str, Value)>::new())
    }

    /// Calls <member> without waiting, and gives what to wait for its answer with.
    fn call_later(bus: &Bus, member: &str, args: Vec<Value>) -> Rc<RefCell<Option<Vec<Value>>>> {
        let answer = Rc::new(RefCell::new(None));
        let put = answer.clone();
        bus.call_async(
            NAME,
            PATH,
            INTERFACE,
            member,
            &args,
            Some(Duration::from_secs(10)),
            move |a| {
                *put.borrow_mut() = Some(a.unwrap());
            },
        )
        .unwrap();
        answer
    }

    fn wait_for(bus: &Bus, answer: &Rc<RefCell<Option<Vec<Value>>>>) -> Vec<Value> {
        let until = Instant::now() + Duration::from_secs(5);
        while answer.borrow().is_none() {
            assert!(Instant::now() < until, "no answer");
            bus.wait(Some(Duration::from_millis(20))).unwrap();
            bus.dispatch().unwrap();
        }
        answer.borrow_mut().take().unwrap()
    }

    #[test]
    fn an_app_opens_a_file_on_the_window_or_cancels() {
        let dir = scratch("fc-bus-open");
        let Some((bus, ctx, setup)) = start(&dir) else {
            return;
        };
        let shell = shell(
            &ctx.runtime,
            vec![
                Some(
                    r#"{"type":"answer","paths":["/home/ann/notes.txt"],"filter":-1,"choices":{},"hidden":true}"#,
                ),
                Some(r#"{"type":"cancel"}"#),
                Some(r#"{"type":"answer","paths":["/a","/b"]}"#),
            ],
        );
        let app = Bus::connect(&bus.address).unwrap();
        let answer = app
            .call(
                NAME,
                PATH,
                INTERFACE,
                "OpenFile",
                &args(
                    "/org/freedesktop/portal/desktop/request/1_1/a",
                    no_options(),
                ),
            )
            .unwrap();
        assert_eq!(answer[0], Value::Uint32(SUCCESS));
        assert_eq!(
            answer[1].get("uris"),
            Some(&Value::strings(&["file:///home/ann/notes.txt"]))
        );
        let line = shell.heard.recv().unwrap();
        assert!(
            line.starts_with(
                r#"{"type":"pick","mode":"open","multiple":false,"title":"Open a File""#
            ),
            "{line}"
        );
        let memory = Memory::read(&setup.memory());
        assert!(memory.hidden);
        assert_eq!(memory.folder(""), Some("/home/ann"));

        let answer = app
            .call(
                NAME,
                PATH,
                INTERFACE,
                "SaveFile",
                &args(
                    "/org/freedesktop/portal/desktop/request/1_1/b",
                    no_options(),
                ),
            )
            .unwrap();
        assert_eq!(answer[0], Value::Uint32(CANCELLED));
        assert!(shell.heard.recv().unwrap().contains(r#""mode":"save""#));

        // An answer that does not fit what was asked is no answer.
        let answer = app
            .call(
                NAME,
                PATH,
                INTERFACE,
                "OpenFile",
                &args(
                    "/org/freedesktop/portal/desktop/request/1_1/c",
                    no_options(),
                ),
            )
            .unwrap();
        assert_eq!(answer[0], Value::Uint32(ENDED));
    }

    #[test]
    fn closing_the_request_takes_the_window_away() {
        let dir = scratch("fc-bus-close");
        let Some((bus, ctx, _setup)) = start(&dir) else {
            return;
        };
        let shell = shell(&ctx.runtime, vec![None]);
        let app = Bus::connect(&bus.address).unwrap();
        let handle = "/org/freedesktop/portal/desktop/request/1_1/d";
        let answer = call_later(&app, "OpenFile", args(handle, no_options()));
        app.flush().unwrap();
        shell.heard.recv_timeout(Duration::from_secs(5)).unwrap();
        let closed = app.call(NAME, handle, REQUEST, "Close", &[]);
        assert!(closed.is_ok(), "{closed:?}");
        let answer = wait_for(&app, &answer);
        assert_eq!(answer[0], Value::Uint32(ENDED));
        shell.closed.recv_timeout(Duration::from_secs(5)).unwrap();
        // The request is gone with it.
        assert!(app.call(NAME, handle, REQUEST, "Close", &[]).is_err());
    }

    #[test]
    fn with_no_shell_gtks_portal_asks() {
        let dir = scratch("fc-bus-gtk");
        let Some((bus, _ctx, _setup)) = start(&dir) else {
            return;
        };
        let (heard_tx, heard) = mpsc::channel();
        let gtk_address = bus.address.clone();
        thread::spawn(move || {
            let gtk = Bus::connect(&gtk_address).unwrap();
            let _slot = gtk
                .export(
                    PATH,
                    vec![Interface::new(INTERFACE).method("OpenFile", "osssa{sv}", "ua{sv}")],
                    move |_: &Message, args: Vec<Value>| {
                        heard_tx.send(args[3].as_str().unwrap().to_owned()).unwrap();
                        Ok(vec![
                            Value::Uint32(0),
                            Value::options(vec![("uris", Value::strings(&["file:///from/gtk"]))]),
                        ])
                    },
                )
                .unwrap();
            assert!(gtk.request_name(GTK, 0).unwrap());
            loop {
                gtk.wait(None).unwrap();
                gtk.dispatch().unwrap();
            }
        });
        let app = Bus::connect(&bus.address).unwrap();
        let until = Instant::now() + Duration::from_secs(5);
        while app.name_owner(GTK).unwrap().is_none() {
            assert!(Instant::now() < until);
            thread::sleep(Duration::from_millis(10));
        }
        let answer = app
            .call(
                NAME,
                PATH,
                INTERFACE,
                "OpenFile",
                &args(
                    "/org/freedesktop/portal/desktop/request/1_1/e",
                    no_options(),
                ),
            )
            .unwrap();
        assert_eq!(heard.recv().unwrap(), "Open a File");
        assert_eq!(answer[0], Value::Uint32(0));
        assert_eq!(
            answer[1].get("uris"),
            Some(&Value::strings(&["file:///from/gtk"]))
        );
    }
}
