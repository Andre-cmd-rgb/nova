//! What the sync keeps, and where: the calendar list, each calendar's state,
//! the status of each account, the locks, the calendars' files (swapped in
//! whole), and the secrets, in the login keyring through secret-tool.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::json::{self, Json};
use crate::{settings, SyncError};

// ---- files

pub fn ensure_dirs() -> io::Result<()> {
    let s = settings();
    for dir in [
        &s.data_dir,
        &s.state_dir,
        &s.config_path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default(),
    ] {
        if dir.as_os_str().is_empty() || dir.is_dir() {
            continue;
        }
        if let Some(parent) = dir.parent() {
            fs::create_dir_all(parent)?;
        }
        match fs::DirBuilder::new().mode(0o700).create(dir) {
            Err(e) if e.kind() != io::ErrorKind::AlreadyExists => return Err(e),
            _ => {}
        }
    }
    Ok(())
}

/// A file's text, none when it is not there; bytes that are not UTF-8 as
/// U+FFFD.
pub fn read_file(path: &Path) -> io::Result<Option<String>> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(String::from_utf8_lossy(&bytes).into_owned())),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// <text> in a new file beside <path>, private and on the disk; its name.
pub fn write_private(path: &Path, text: &str) -> io::Result<PathBuf> {
    let mut name = path.as_os_str().to_owned();
    name.push(format!(".{}.tmp", std::process::id()));
    let tmp = PathBuf::from(name);
    let mut f = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(text.as_bytes())?;
    f.sync_all()?;
    Ok(tmp)
}

/// <text> put at <path> in place of what was there.
pub fn replace(path: &Path, text: &str) -> io::Result<()> {
    let tmp = write_private(path, text)?;
    fs::rename(&tmp, path).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })
}

const AT_FDCWD: i32 = -100;
const RENAME_NOREPLACE: u32 = 1;
const RENAME_EXCHANGE: u32 = 2;

extern "C" {
    fn renameat2(
        olddirfd: i32,
        oldpath: *const i8,
        newdirfd: i32,
        newpath: *const i8,
        flags: u32,
    ) -> i32;
}

fn rename2(src: &Path, dst: &Path, flags: u32) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let a = std::ffi::CString::new(src.as_os_str().as_bytes())?;
    let b = std::ffi::CString::new(dst.as_os_str().as_bytes())?;
    // SAFETY: two NUL-terminated paths of ours.
    if unsafe { renameat2(AT_FDCWD, a.as_ptr(), AT_FDCWD, b.as_ptr(), flags) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn unsupported(e: &io::Error) -> bool {
    matches!(
        e.raw_os_error(),
        Some(38 /* ENOSYS */) | Some(22 /* EINVAL */)
    )
}

/// Puts <text> at <path>, if what is there is still <expected> (none: no
/// file). Returns none when it was, else what the shell wrote meanwhile,
/// which is left in place for the caller to merge.
pub fn swap_in(path: &Path, text: &str, expected: Option<&str>) -> io::Result<Option<String>> {
    let tmp = write_private(path, text)?;
    let result = swap(path, &tmp, expected);
    let _ = fs::remove_file(&tmp);
    result
}

fn swap(path: &Path, tmp: &Path, expected: Option<&str>) -> io::Result<Option<String>> {
    let Some(expected) = expected else {
        match rename2(tmp, path, RENAME_NOREPLACE) {
            Ok(()) => return Ok(None),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                return Ok(Some(read_file(path)?.unwrap_or_default()));
            }
            Err(e) if !unsupported(&e) => return Err(e),
            Err(_) => {}
        }
        if path.exists() {
            return Ok(Some(read_file(path)?.unwrap_or_default()));
        }
        fs::rename(tmp, path)?;
        return Ok(None);
    };
    match rename2(tmp, path, RENAME_EXCHANGE) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None), // deleted meanwhile: it stays so
        Err(e) if !unsupported(&e) => return Err(e),
        Err(_) => {
            let current = read_file(path)?;
            if current.as_deref() != Some(expected) {
                return Ok(current);
            }
            fs::rename(tmp, path)?;
            return Ok(None);
        }
    }
    let old = read_file(tmp)?;
    if old.as_deref() == Some(expected) {
        return Ok(None);
    }
    // The shell wrote between the read and the swap: its file goes back in
    // place, to be merged.
    rename2(tmp, path, RENAME_EXCHANGE)?;
    Ok(old)
}

/// A lock of the state folder's, held until dropped.
pub struct Lock(#[allow(dead_code)] File);

impl Lock {
    pub fn take(name: &str) -> Result<Lock, SyncError> {
        let fail = |e: io::Error| {
            SyncError::error(format!("The Calendar's state could not be locked ({e})."))
        };
        ensure_dirs().map_err(fail)?;
        let f = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(settings().state_dir.join(name))
            .map_err(fail)?;
        f.lock().map_err(fail)?;
        Ok(Lock(f))
    }
}

// ---- the calendar list

pub fn default_config() -> Json {
    let mut local = Json::object();
    for (k, v) in [
        ("id", Json::str("local")),
        ("kind", Json::str("local")),
        ("name", Json::str("Calendar")),
        ("color", Json::str("accent")),
        ("shown", Json::Bool(true)),
        ("file", Json::str("calendar.ics")),
        ("events", Json::Bool(true)),
        ("tasks", Json::Bool(true)),
        ("readOnly", Json::Bool(false)),
    ] {
        local.set(k, v);
    }
    let mut c = Json::object();
    c.set("version", Json::Int(1));
    c.set("accounts", Json::Array(Vec::new()));
    c.set("calendars", Json::Array(vec![local]));
    c
}

fn not_a_list() -> SyncError {
    SyncError::error(format!(
        "{} is not a calendar list; fix it, or move it away",
        settings().config_path.display()
    ))
}

pub fn load_config() -> Result<Json, SyncError> {
    let text = read_file(&settings().config_path).map_err(|_| not_a_list())?;
    let Some(text) = text else {
        return Ok(default_config());
    };
    let mut config = json::parse(&text).ok_or_else(not_a_list)?;
    let lists = config.get("calendars").and_then(Json::as_array).is_some()
        && config.get("accounts").and_then(Json::as_array).is_some();
    if !config.is_object() || !lists {
        return Err(not_a_list());
    }
    let calendars = config
        .get_mut("calendars")
        .and_then(Json::as_array_mut)
        .expect("checked");
    // Only objects are calendars; anything else in the list is left out.
    calendars.retain(Json::is_object);
    if !calendars.iter().any(|c| c.text("id") == "local") {
        let local = default_config()
            .get("calendars")
            .and_then(Json::as_array)
            .expect("the default")[0]
            .clone();
        calendars.insert(0, local);
    }
    let accounts = config
        .get_mut("accounts")
        .and_then(Json::as_array_mut)
        .expect("checked");
    accounts.retain(Json::is_object);
    Ok(config)
}

pub fn save_config(config: &Json) -> io::Result<()> {
    ensure_dirs()?;
    replace(
        &settings().config_path,
        &(json::dumps_indented(config) + "\n"),
    )
}

/// The calendar list, read and changed under its lock, and written back
/// when <change> succeeds.
pub fn edit_config<T>(
    change: impl FnOnce(&mut Json) -> Result<T, SyncError>,
) -> Result<T, SyncError> {
    let _lock = Lock::take("config.lock")?;
    let mut config = load_config()?;
    let out = change(&mut config)?;
    save_config(&config)
        .map_err(|e| SyncError::error(format!("The calendar list could not be written ({e}).")))?;
    Ok(out)
}

pub fn calendars(config: &Json) -> &Vec<Json> {
    config
        .get("calendars")
        .and_then(Json::as_array)
        .expect("a loaded list has calendars")
}

pub fn calendars_mut(config: &mut Json) -> &mut Vec<Json> {
    config
        .get_mut("calendars")
        .and_then(Json::as_array_mut)
        .expect("a loaded list has calendars")
}

pub fn accounts(config: &Json) -> &Vec<Json> {
    config
        .get("accounts")
        .and_then(Json::as_array)
        .expect("a loaded list has accounts")
}

pub fn accounts_mut(config: &mut Json) -> &mut Vec<Json> {
    config
        .get_mut("accounts")
        .and_then(Json::as_array_mut)
        .expect("a loaded list has accounts")
}

// ---- state and status

pub fn state_path(calendar_id: &str) -> PathBuf {
    settings().state_dir.join(format!("{calendar_id}.json"))
}

/// What the server last had of one item.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub href: String,
    pub uid: String,
    pub etag: Option<String>,
    pub base: Option<String>,
    pub prev: Option<String>,
}

impl Entry {
    pub fn new(href: &str, uid: &str) -> Entry {
        Entry {
            href: href.to_string(),
            uid: uid.to_string(),
            etag: None,
            base: None,
            prev: None,
        }
    }

    fn from_json(v: &Json) -> Option<Entry> {
        let s = |k: &str| v.get(k).and_then(Json::as_str).map(str::to_string);
        Some(Entry {
            href: s("href")?,
            uid: s("uid")?,
            etag: s("etag"),
            base: s("base"),
            prev: s("prev"),
        })
    }

    fn to_json(&self) -> Json {
        let mut o = Json::object();
        o.set("href", Json::str(&self.href));
        o.set("uid", Json::str(&self.uid));
        o.set("etag", Json::opt(self.etag.clone()));
        o.set("base", Json::opt(self.base.clone()));
        o.set("prev", Json::opt(self.prev.clone()));
        o
    }
}

/// A calendar's state: its items (by the path of each on the server), and
/// the rest as it was read (the sync token, the ctag; a subscription's ETag
/// and date).
pub struct State {
    pub items: OMap<Entry>,
    pub fields: Json,
}

impl State {
    pub fn text(&self, key: &str) -> Option<String> {
        self.fields
            .get(key)
            .and_then(Json::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    }

    pub fn set(&mut self, key: &str, value: Option<String>) {
        self.fields.set(key, Json::opt(value));
    }
}

pub fn load_state(calendar_id: &str) -> State {
    let fields = read_file(&state_path(calendar_id))
        .ok()
        .flatten()
        .and_then(|t| json::parse(&t))
        .filter(Json::is_object)
        .unwrap_or_else(Json::object);
    let mut items = OMap::new();
    if let Some(Json::Object(entries)) = fields.get("items") {
        for (k, v) in entries {
            if let Some(e) = Entry::from_json(v) {
                items.insert(k, e);
            }
        }
    }
    let mut fields = fields;
    fields.remove("items");
    State { items, fields }
}

pub fn save_state(calendar_id: &str, state: &State) -> io::Result<()> {
    ensure_dirs()?;
    let mut out = Json::object();
    out.set(
        "items",
        Json::Object(
            state
                .items
                .iter()
                .map(|(k, e)| (k.to_string(), e.to_json()))
                .collect(),
        ),
    );
    if let Json::Object(fields) = &state.fields {
        for (k, v) in fields {
            out.set(k, v.clone());
        }
    }
    replace(&state_path(calendar_id), &json::dumps(&out))
}

pub fn save_status(key: &str, status: Option<Json>) -> Result<(), SyncError> {
    let _lock = Lock::take("status.lock")?;
    let path = settings().state_dir.join("status.json");
    let mut everything = read_file(&path)
        .ok()
        .flatten()
        .and_then(|t| json::parse(&t))
        .filter(Json::is_object)
        .unwrap_or_else(Json::object);
    match status {
        None => {
            everything.remove(key);
        }
        Some(s) => everything.set(key, s),
    }
    replace(&path, &(json::dumps_indented(&everything) + "\n"))
        .map_err(|e| SyncError::error(format!("The sync's status could not be written ({e}).")))
}

pub fn new_id() -> String {
    crate::digest::hex(&crate::digest::random(4))
}

// ---- an ordered map, as Python's dict is

/// Values by key, in the order the keys came; one removed and given again
/// comes last.
#[derive(Debug, Clone, Default)]
pub struct OMap<V> {
    slots: Vec<Option<(String, V)>>,
    index: std::collections::HashMap<String, usize>,
}

impl<V> OMap<V> {
    pub fn new() -> Self {
        OMap {
            slots: Vec::new(),
            index: std::collections::HashMap::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.index.len()
    }

    pub fn is_empty(&self) -> bool {
        self.index.is_empty()
    }

    pub fn contains(&self, key: &str) -> bool {
        self.index.contains_key(key)
    }

    pub fn get(&self, key: &str) -> Option<&V> {
        let i = *self.index.get(key)?;
        self.slots[i].as_ref().map(|(_, v)| v)
    }

    pub fn get_mut(&mut self, key: &str) -> Option<&mut V> {
        let i = *self.index.get(key)?;
        self.slots[i].as_mut().map(|(_, v)| v)
    }

    pub fn insert(&mut self, key: &str, value: V) {
        match self.index.get(key) {
            Some(&i) => self.slots[i] = Some((key.to_string(), value)),
            None => {
                self.index.insert(key.to_string(), self.slots.len());
                self.slots.push(Some((key.to_string(), value)));
            }
        }
    }

    pub fn remove(&mut self, key: &str) -> Option<V> {
        let i = self.index.remove(key)?;
        self.slots[i].take().map(|(_, v)| v)
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &V)> {
        self.slots.iter().flatten().map(|(k, v)| (k.as_str(), v))
    }

    pub fn keys(&self) -> Vec<String> {
        self.iter().map(|(k, _)| k.to_string()).collect()
    }

    pub fn values(&self) -> impl Iterator<Item = &V> {
        self.iter().map(|(_, v)| v)
    }
}

// ---- secrets: the login keyring, through secret-tool, a secret on its
//      stdin and never on a command line

const SECRET_SERVICE: &str = "nova-calendar";

/// secret-tool run with <input>, a minute at most: its exit and output.
fn secret_tool(args: &[&str], input: Option<&[u8]>) -> Option<(bool, Vec<u8>)> {
    let mut child = Command::new("secret-tool")
        .args(args)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    if let (Some(data), Some(mut stdin)) = (input, child.stdin.take()) {
        let _ = stdin.write_all(data);
    }
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        let _ = stdout.read_to_end(&mut out);
        out
    });
    let deadline = Instant::now() + Duration::from_secs(60);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    let out = reader.join().unwrap_or_default();
    Some((status.success(), out))
}

pub fn secret_store(key: &str, label: &str, secret: &str) -> Result<(), SyncError> {
    match secret_tool(
        &[
            "store",
            "--label",
            label,
            "service",
            SECRET_SERVICE,
            "id",
            key,
        ],
        Some(secret.as_bytes()),
    ) {
        Some((true, _)) => Ok(()),
        _ => Err(SyncError::error(
            "The password could not be kept in the keyring.",
        )),
    }
}

pub fn secret_lookup(key: &str) -> Result<String, SyncError> {
    match secret_tool(&["lookup", "service", SECRET_SERVICE, "id", key], None) {
        Some((true, out)) if !out.is_empty() => Ok(String::from_utf8_lossy(&out).into_owned()),
        _ => Err(SyncError::signin("The password is not in the keyring.")),
    }
}

pub fn secret_clear(key: &str) {
    let _ = secret_tool(&["clear", "service", SECRET_SERVICE, "id", key], None);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn omap_keeps_the_order() {
        let mut m = OMap::new();
        m.insert("b", 1);
        m.insert("a", 2);
        m.insert("b", 3);
        assert_eq!(m.keys(), vec!["b", "a"]);
        assert_eq!(m.remove("b"), Some(3));
        m.insert("b", 4);
        assert_eq!(m.keys(), vec!["a", "b"]);
        assert_eq!(m.len(), 2);
        assert_eq!(m.get("b"), Some(&4));
    }
}
