//! The computer the sync runs on (a scratch home, the keyring stubbed), the
//! phone that changes the server's calendars over HTTP, the shell that edits
//! the calendar's files, and the server: the fake one, or Radicale.

use super::codec::base64;
use super::fake::Fake;
use nova_calendar::ical::{self, Component, Group};
use nova_calendar::json::{self, Json};
use nova_calendar::store::read_file;
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

const SYNC: &str = env!("CARGO_BIN_EXE_nova-calendar-sync");
const SECRET_TOOL: &str = include_str!("secret-tool");

// ---- the computer

pub struct Done {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// A scratch computer for one scenario: its own folder, home and secrets.
/// Every check is printed, ok or FAIL; the scenario fails at its end when any
/// did.
pub struct Pc {
    pub dir: PathBuf,
    pub home: PathBuf,
    env: Vec<(String, String)>,
    failed: RefCell<Vec<String>>,
}

impl Pc {
    /// A computer whose secret-tool is the stub, which keeps secrets in
    /// files of the scratch folder.
    pub fn new(scenario: &str) -> Pc {
        let pc = Pc::bare(scenario);
        let stub = pc.dir.join("bin/secret-tool");
        fs::write(&stub, SECRET_TOOL).expect("the secret-tool stub is written");
        fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).expect("it is made runnable");
        pc
    }

    /// A computer with the real secret-tool, on the keyring of the D-Bus
    /// session this test was started in. It refuses any other: the user's
    /// own session must never be reached.
    pub fn with_keyring(scenario: &str) -> Pc {
        let mut pc = Pc::bare(scenario);
        let bus = std::env::var("DBUS_SESSION_BUS_ADDRESS")
            .expect("the keyring test runs in a D-Bus session of its own");
        pc.env.push(("DBUS_SESSION_BUS_ADDRESS".into(), bus));
        pc
    }

    fn bare(scenario: &str) -> Pc {
        let dir =
            std::env::temp_dir().join(format!("nova-calsync.{}.{scenario}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let home = dir.join("home");
        fs::create_dir_all(dir.join("bin")).expect("the scratch folder is made");
        fs::create_dir_all(&home).expect("the scratch home is made");
        let var = |k: &str, v: String| (k.to_string(), v);
        let env = vec![
            var("HOME", home.display().to_string()),
            var("PATH", format!("{}:/usr/bin", dir.join("bin").display())),
            var("LANG", "C.UTF-8".into()),
            var("TZ", "Europe/Rome".into()),
            var(
                "NOVA_TEST_SECRETS",
                dir.join("secrets").display().to_string(),
            ),
            var("NOVA_CALENDAR_TIMEOUT", "5".into()),
            var("NOVA_PATH", dir.join("nova").display().to_string()),
        ];
        Pc {
            dir,
            home,
            env,
            failed: RefCell::new(Vec::new()),
        }
    }

    pub fn set_env(&mut self, name: &str, value: &str) {
        self.env.retain(|(k, _)| k != name);
        self.env.push((name.into(), value.into()));
    }

    pub fn check(&self, ok: bool, what: impl AsRef<str>) {
        let what = what.as_ref();
        println!("{} {what}", if ok { "ok  " } else { "FAIL" });
        if !ok {
            self.failed.borrow_mut().push(what.to_string());
        }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(SYNC);
        command
            .args(args)
            .env_clear()
            .envs(self.env.iter().map(|(k, v)| (k, v)));
        command
    }

    /// The program run with <args>, and <request> on its stdin.
    pub fn run(&self, args: &[&str], request: Option<&str>) -> Done {
        let mut child = self
            .command(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("the sync runs");
        let mut stdin = child.stdin.take().expect("its stdin");
        let _ = stdin.write_all(request.unwrap_or("").as_bytes());
        drop(stdin);
        let read = |mut pipe: Box<dyn Read + Send>| {
            thread::spawn(move || {
                let mut text = String::new();
                let mut bytes = Vec::new();
                let _ = pipe.read_to_end(&mut bytes);
                text.push_str(&String::from_utf8_lossy(&bytes));
                text
            })
        };
        let out = read(Box::new(child.stdout.take().expect("its stdout")));
        let err = read(Box::new(child.stderr.take().expect("its stderr")));
        let start = Instant::now();
        let status = loop {
            if let Some(status) = child.try_wait().expect("the sync is waited for") {
                break status;
            }
            if start.elapsed() > Duration::from_secs(120) {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the sync ran for two minutes: {args:?}");
            }
            thread::sleep(Duration::from_millis(5));
        };
        Done {
            code: status.code().unwrap_or(-1),
            stdout: out.join().unwrap_or_default(),
            stderr: err.join().unwrap_or_default(),
        }
    }

    /// A sync started and left running.
    pub fn start_sync(&self) -> Child {
        self.command(&["sync"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("the sync runs")
    }

    pub fn sync(&self) -> Done {
        let done = self.run(&["sync"], None);
        if !done.stderr.is_empty() {
            println!("  sync said: {}", done.stderr.trim());
        }
        done
    }

    fn json_at(&self, relative: &str) -> Json {
        let text = fs::read_to_string(self.home.join(relative))
            .unwrap_or_else(|e| panic!("{relative} cannot be read: {e}"));
        json::parse(&text).unwrap_or_else(|| panic!("{relative} is not JSON"))
    }

    pub fn config(&self) -> Json {
        self.json_at(".config/nova/calendars.json")
    }

    pub fn list_path(&self) -> PathBuf {
        self.home.join(".config/nova/calendars.json")
    }

    pub fn status(&self) -> Json {
        self.json_at(".local/state/nova/calendar-sync/status.json")
    }

    /// The status of an account or a subscription; an empty one for none.
    pub fn status_of(&self, id: &str) -> Json {
        self.status().get(id).cloned().unwrap_or_else(Json::object)
    }

    pub fn calendars(&self) -> Vec<Json> {
        self.config()
            .get("calendars")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default()
    }

    pub fn calendar(&self, name: &str) -> Json {
        self.calendars()
            .into_iter()
            .find(|c| c.text("name") == name)
            .unwrap_or_else(|| panic!("no calendar named {name}"))
    }

    /// The id of the first account.
    pub fn account(&self) -> String {
        self.config()
            .get("accounts")
            .and_then(Json::as_array)
            .and_then(|a| a.first())
            .map(|a| a.text("id").to_string())
            .expect("an account")
    }

    pub fn folder(&self) -> PathBuf {
        self.home.join(".local/share/nova/calendar")
    }

    pub fn path(&self, name: &str) -> PathBuf {
        self.folder().join(self.calendar(name).text("file"))
    }

    /// The names of the files in the calendars' folder, sorted.
    pub fn files(&self) -> Vec<String> {
        let mut files: Vec<String> = fs::read_dir(self.folder())
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        files.sort();
        files
    }

    /// A calendar's file as text, as the sync reads it.
    pub fn text(&self, name: &str) -> String {
        read_file(&self.path(name))
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    /// The items of a calendar's file by UID.
    pub fn items(&self, name: &str) -> Items {
        let mut root = ical::parse(&self.text(name));
        Items(
            ical::groups(ical::calendar_of(&mut root))
                .into_iter()
                .collect(),
        )
    }

    /// The file changed as the shell changes it: read, edited, written whole.
    pub fn edit(&self, name: &str, change: impl FnOnce(&mut Component)) {
        let path = self.path(name);
        let mut root = ical::parse(&read_file(&path).ok().flatten().unwrap_or_default());
        change(ical::calendar_of(&mut root));
        fs::write(&path, ical::serialize(&root.children)).expect("the file is written");
    }

    pub fn add_quietly(&self, server: &Server) -> Done {
        self.run(
            &["add"],
            Some(&request(&[
                ("type", "caldav"),
                ("url", &server.url()),
                ("user", &server.user),
                ("password", &server.password),
            ])),
        )
    }

    pub fn add(&self, server: &Server) -> Json {
        let done = self.add_quietly(server);
        self.check(
            done.code == 0,
            format!("the account is added ({})", done.stderr.trim()),
        );
        json::parse(if done.stdout.is_empty() {
            "{}"
        } else {
            &done.stdout
        })
        .unwrap_or_else(Json::object)
    }

    /// The secrets the stub keeps, whatever their keys.
    pub fn secrets(&self) -> Vec<String> {
        fs::read_dir(self.dir.join("secrets"))
            .map(|d| {
                d.flatten()
                    .filter_map(|e| fs::read_to_string(e.path()).ok())
                    .collect()
            })
            .unwrap_or_default()
    }
}

impl Drop for Pc {
    fn drop(&mut self) {
        let failed = self.failed.borrow().clone();
        if std::thread::panicking() {
            eprintln!("the scratch computer is left in {}", self.dir.display());
        } else if failed.is_empty() {
            let _ = fs::remove_dir_all(&self.dir);
        } else {
            eprintln!("the scratch computer is left in {}", self.dir.display());
            panic!(
                "{} check(s) failed:\n  {}",
                failed.len(),
                failed.join("\n  ")
            );
        }
    }
}

/// A line of JSON with these fields, as the shell sends the program.
pub fn request(fields: &[(&str, &str)]) -> String {
    json::dumps(&Json::Object(
        fields
            .iter()
            .map(|(k, v)| (k.to_string(), Json::str(*v)))
            .collect(),
    ))
}

// ---- the items of a file

pub struct Items(pub BTreeMap<String, Group>);

impl Items {
    pub fn get(&self, uid: &str) -> Option<&Group> {
        self.0.get(uid)
    }

    pub fn contains(&self, uid: &str) -> bool {
        self.0.contains_key(uid)
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn uids(&self) -> Vec<String> {
        self.0.keys().cloned().collect()
    }

    /// The UIDs of the items titled <title>.
    pub fn titled(&self, title: &str) -> Vec<String> {
        self.0
            .iter()
            .filter(|(_, g)| summary(Some(g)).as_deref() == Some(title))
            .map(|(u, _)| u.clone())
            .collect()
    }
}

pub fn summary(group: Option<&Group>) -> Option<String> {
    group
        .and_then(|g| g.first())
        .map(|c| ical::unescape(ical::value(c, "SUMMARY")))
}

pub fn vcal(components: &[&str], zones: &str) -> String {
    format!(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Phone//EN\r\n{zones}{}END:VCALENDAR\r\n",
        components.concat()
    )
}

pub fn vevent(uid: &str, summary: &str, start: &str, end: &str, extra: &[&str]) -> String {
    let mut lines = vec![
        "BEGIN:VEVENT".to_string(),
        format!("UID:{uid}"),
        "DTSTAMP:20261101T000000Z".into(),
        format!("DTSTART{start}"),
        format!("DTEND{end}"),
        format!("SUMMARY:{summary}"),
    ];
    lines.extend(extra.iter().map(|l| l.to_string()));
    lines.push("END:VEVENT".into());
    lines.join("\r\n") + "\r\n"
}

pub fn new_component(cal: &mut Component, text: &str) {
    cal.children.extend(ical::parse(text).children);
}

/// <name> (with its parameters) in place of every property of that name in
/// the item <uid>, as the shell's setProp does.
pub fn set_prop(cal: &mut Component, uid: &str, name: &str, text: &str) {
    for c in cal.children.iter_mut() {
        if ical::unescape(ical::value(c, "UID")) != uid || ical::get(c, "RECURRENCE-ID").is_some() {
            continue;
        }
        let base = name.split(';').next().unwrap_or(name);
        let at = c
            .lines
            .iter()
            .position(|l| ical::prop_name(l) == base)
            .unwrap_or(c.lines.len());
        c.lines.retain(|l| ical::prop_name(l) != base);
        let at = at.min(c.lines.len());
        c.lines.insert(at, format!("{name}:{text}"));
        ical::set_line(c, "LAST-MODIFIED", "20261118T120000Z");
    }
}

pub fn remove_item(cal: &mut Component, uid: &str) {
    cal.children
        .retain(|c| ical::unescape(ical::value(c, "UID")) != uid);
}

pub const ROME: &str = "BEGIN:VTIMEZONE\r\nTZID:Europe/Rome\r\nBEGIN:DAYLIGHT\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\nTZNAME:CEST\r\n\
DTSTART:19700329T020000\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\nEND:DAYLIGHT\r\nBEGIN:STANDARD\r\nTZOFFSETFROM:+0200\r\n\
TZOFFSETTO:+0100\r\nTZNAME:CET\r\nDTSTART:19701025T030000\r\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n";

// ---- the servers

enum Kind {
    Fake(Fake),
    Radicale(Radicale),
}

/// The CalDAV server a scenario runs against.
pub struct Server {
    pub user: String,
    pub password: String,
    kind: Kind,
}

impl Server {
    /// The fake server, with its default account.
    pub fn fake() -> Server {
        Server::fake_as(None, None, None)
    }

    pub fn fake_as(user: Option<&str>, password: Option<&str>, bearer: Option<&str>) -> Server {
        let fake = Fake::new(user, password, bearer);
        let (user, password) = {
            let s = fake.state();
            (s.user.clone(), s.password.clone())
        };
        Server {
            user,
            password,
            kind: Kind::Fake(fake),
        }
    }

    /// The server the tests are asked to run on: Radicale where
    /// NOVA_TEST_RADICALE=1, else the fake one.
    pub fn any(pc: &Pc) -> Server {
        if std::env::var("NOVA_TEST_RADICALE").as_deref() != Ok("1") {
            return Server::fake();
        }
        Server {
            user: "alice".into(),
            password: "pw-SECRET-1".into(),
            kind: Kind::Radicale(Radicale::new(&pc.dir)),
        }
    }

    pub fn fake_server(&self) -> &Fake {
        match &self.kind {
            Kind::Fake(f) => f,
            Kind::Radicale(_) => panic!("this needs the fake server"),
        }
    }

    pub fn is_radicale(&self) -> bool {
        matches!(self.kind, Kind::Radicale(_))
    }

    pub fn port(&self) -> u16 {
        match &self.kind {
            Kind::Fake(f) => f.port(),
            Kind::Radicale(r) => r.port,
        }
    }

    pub fn url(&self) -> String {
        format!("http://127.0.0.1:{}/", self.port())
    }

    pub fn base(&self, cal: &str) -> String {
        match &self.kind {
            Kind::Fake(_) => format!("/alice/cals/{cal}/"),
            Kind::Radicale(_) => format!("/alice/{cal}/"),
        }
    }

    pub fn make_calendar(&self, name: &str, display: &str, comps: &[&str], color: &str) {
        match &self.kind {
            Kind::Fake(f) => f.add_calendar(name, display, comps, color),
            Kind::Radicale(_) => {
                let phone = Phone::new(self);
                phone.req(
                    "PROPFIND",
                    "/alice/",
                    Some("<d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>"),
                    &[("Depth", "0")],
                );
                let comps: String = comps
                    .iter()
                    .map(|c| format!("<c:comp name=\"{c}\"/>"))
                    .collect();
                let body = format!(
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?><c:mkcalendar xmlns:d=\"DAV:\" \
                     xmlns:c=\"urn:ietf:params:xml:ns:caldav\" xmlns:a=\"http://apple.com/ns/ical/\">\
                     <d:set><d:prop><d:displayname>{display}</d:displayname><a:calendar-color>{color}</a:calendar-color>\
                     <c:supported-calendar-component-set>{comps}</c:supported-calendar-component-set>\
                     </d:prop></d:set></c:mkcalendar>"
                );
                let (status, _, _) = phone.req("MKCALENDAR", &self.base(name), Some(&body), &[]);
                assert!(status == 200 || status == 201, "MKCALENDAR said {status}");
            }
        }
    }

    pub fn stop(&self) {
        match &self.kind {
            Kind::Fake(f) => f.stop(),
            Kind::Radicale(r) => r.stop(),
        }
    }

    pub fn start(&self) {
        match &self.kind {
            Kind::Fake(f) => f.start(),
            Kind::Radicale(r) => r.start(),
        }
    }
}

/// The radicale on PATH, run with a scratch storage.
struct Radicale {
    dir: PathBuf,
    port: u16,
    child: Mutex<Option<Child>>,
}

impl Radicale {
    fn new(scratch: &Path) -> Radicale {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("a free port");
        let port = listener.local_addr().expect("its address").port();
        drop(listener);
        let dir = scratch.join("radicale");
        fs::create_dir_all(&dir).expect("radicale's folder is made");
        fs::write(dir.join("users"), "alice:pw-SECRET-1\n").expect("its users");
        fs::write(
            dir.join("config"),
            format!(
                "[server]\nhosts = 127.0.0.1:{port}\n[auth]\ntype = htpasswd\nhtpasswd_filename = {d}/users\n\
                 htpasswd_encryption = plain\n[storage]\nfilesystem_folder = {d}/collections\n\
                 [rights]\ntype = owner_only\n[logging]\nlevel = warning\n",
                d = dir.display()
            ),
        )
        .expect("its config");
        let radicale = Radicale {
            dir,
            port,
            child: Mutex::new(None),
        };
        radicale.start();
        radicale
    }

    fn start(&self) {
        let log = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join("log"))
            .expect("radicale's log");
        let child = Command::new("radicale")
            .arg("--config")
            .arg(self.dir.join("config"))
            .stdout(Stdio::null())
            .stderr(log)
            .spawn()
            .expect("NOVA_TEST_RADICALE=1 needs radicale on PATH");
        *self.child.lock().unwrap_or_else(|e| e.into_inner()) = Some(child);
        for _ in 0..100 {
            if TcpStream::connect((Ipv4Addr::LOCALHOST, self.port)).is_ok() {
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }
        panic!("radicale did not start");
    }

    fn stop(&self) {
        if let Some(mut child) = self.child.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for Radicale {
    fn drop(&mut self) {
        self.stop();
    }
}

// ---- the phone

/// The phone, or the web: the server's calendars changed over HTTP.
pub struct Phone<'a> {
    server: &'a Server,
    bearer: Option<String>,
}

impl<'a> Phone<'a> {
    pub fn new(server: &'a Server) -> Phone<'a> {
        Phone {
            server,
            bearer: None,
        }
    }

    pub fn with_bearer(server: &'a Server, bearer: &str) -> Phone<'a> {
        Phone {
            server,
            bearer: Some(bearer.into()),
        }
    }

    /// (status, headers by lower-case name, body) of one request.
    pub fn req(
        &self,
        method: &str,
        path: &str,
        body: Option<&str>,
        headers: &[(&str, &str)],
    ) -> (u16, HashMap<String, String>, String) {
        let port = self.server.port();
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("the server is up");
        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
        let auth = match &self.bearer {
            Some(token) => format!("Bearer {token}"),
            None => format!(
                "Basic {}",
                base64(format!("{}:{}", self.server.user, self.server.password).as_bytes())
            ),
        };
        let mut head = format!(
            "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nAuthorization: {auth}\r\n"
        );
        for (k, v) in headers {
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        if let Some(body) = body {
            if !headers
                .iter()
                .any(|(k, _)| k.eq_ignore_ascii_case("content-type"))
            {
                head.push_str("Content-Type: application/xml; charset=utf-8\r\n");
            }
            head.push_str(&format!("Content-Length: {}\r\n", body.len()));
        }
        head.push_str("\r\n");
        stream
            .write_all(head.as_bytes())
            .expect("the request is sent");
        stream
            .write_all(body.unwrap_or("").as_bytes())
            .expect("the body is sent");
        let mut raw = Vec::new();
        let _ = stream.read_to_end(&mut raw);
        let split = raw
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .unwrap_or_else(|| panic!("{method} {path}: no answer"));
        let head = String::from_utf8_lossy(&raw[..split]).into_owned();
        let mut lines = head.lines();
        let status: u16 = lines
            .next()
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let headers: HashMap<String, String> = lines
            .filter_map(|l| l.split_once(':'))
            .map(|(k, v)| (k.trim().to_lowercase(), v.trim().to_string()))
            .collect();
        let mut data = raw[split + 4..].to_vec();
        if headers
            .get("transfer-encoding")
            .is_some_and(|t| t.contains("chunked"))
        {
            data = unchunk(&data);
        }
        (status, headers, String::from_utf8_lossy(&data).into_owned())
    }

    /// An item written; its ETag, if the server says one.
    pub fn put(&self, cal: &str, name: &str, text: &str) -> Option<String> {
        let path = format!("{}{name}", self.server.base(cal));
        let (status, headers, _) = self.req(
            "PUT",
            &path,
            Some(text),
            &[("Content-Type", "text/calendar; charset=utf-8")],
        );
        assert!(
            [200, 201, 204].contains(&status),
            "PUT {path} said {status}"
        );
        headers.get("etag").cloned()
    }

    pub fn delete(&self, cal: &str, name: &str) {
        let path = format!("{}{name}", self.server.base(cal));
        let (status, _, _) = self.req("DELETE", &path, None, &[]);
        assert!([200, 204].contains(&status), "DELETE {path} said {status}");
    }

    /// (path, text) of every item of a calendar.
    fn resources(&self, cal: &str) -> Vec<(String, String)> {
        let base = self.server.base(cal);
        let (_, _, body) = self.req(
            "PROPFIND",
            &base,
            Some("<d:propfind xmlns:d=\"DAV:\"><d:prop><d:getetag/></d:prop></d:propfind>"),
            &[("Depth", "1")],
        );
        let mut out = Vec::new();
        for href in super::codec::element_texts(&body, "href") {
            let path = href
                .split_once("://")
                .map_or(href.as_str(), |(_, r)| r.find('/').map_or("/", |i| &r[i..]))
                .to_string();
            if path.trim_end_matches('/') == base.trim_end_matches('/') {
                continue;
            }
            let (status, _, text) = self.req("GET", &path, None, &[]);
            if status == 200 {
                out.push((path, text));
            }
        }
        out
    }

    /// {uid: text} of every item in a calendar.
    pub fn all(&self, cal: &str) -> BTreeMap<String, String> {
        self.resources(cal)
            .into_iter()
            .map(|(path, text)| {
                let uid = text
                    .replace("\r\n", "\n")
                    .lines()
                    .find_map(|l| l.strip_prefix("UID:").map(|u| u.trim().to_string()))
                    .unwrap_or(path);
                (uid, text)
            })
            .collect()
    }

    /// The text of the item with this UID.
    pub fn item(&self, cal: &str, uid: &str) -> String {
        self.all(cal)
            .remove(uid)
            .unwrap_or_else(|| panic!("the server has no {uid} in {cal}"))
    }

    /// The resource's name the server keeps an item under.
    pub fn name_of(&self, cal: &str, uid: &str) -> String {
        let want = format!("UID:{uid}");
        self.resources(cal)
            .into_iter()
            .find(|(_, text)| text.contains(&want))
            .map(|(path, _)| path.rsplit('/').next().unwrap_or("").to_string())
            .unwrap_or_else(|| panic!("the server has no {uid} in {cal}"))
    }
}

fn unchunk(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut rest = data;
    while let Some(eol) = rest.windows(2).position(|w| w == b"\r\n") {
        let size =
            usize::from_str_radix(String::from_utf8_lossy(&rest[..eol]).trim(), 16).unwrap_or(0);
        if size == 0 || rest.len() < eol + 2 + size {
            break;
        }
        out.extend_from_slice(&rest[eol + 2..eol + 2 + size]);
        rest = rest.get(eol + 2 + size + 2..).unwrap_or(&[]);
    }
    out
}
