//! A CalDAV server small enough to read, for nova-calendar-sync's tests: what
//! iCloud, Google and the others answer, as far as the sync asks it. On
//! 127.0.0.1, in threads of the test.
//!
//!   let fake = Fake::new(Some("alice"), Some("pw"), None);     Basic auth
//!   let fake = Fake::new(None, None, Some("token"));           Google's way
//!   fake.add_calendar("home", "Home", &["VEVENT", "VTODO"], "#FF2968FF");
//!   fake.url(); fake.stop(); fake.start() (the same port again)
//!
//! Options a test turns, in fake.state(): sync_tokens (WebDAV
//! sync-collection, else only ctag and ETags), etag_on_put, home_url (the
//! calendar home at an address of its own, as iCloud puts it on a
//! partition), read_only on a calendar, moved ({path: address} redirected),
//! unlisted (calendars the home's listing leaves out), elsewhere (addresses
//! of calendars on another server it lists), withheld and vanished (items a
//! calendar-multiget leaves out, or answers 404), delay ({path: seconds}
//! before answering), feed_private (the feed asks for the password), trickle
//! (seconds between the feed's bytes), race (a change of the phone's that
//! gets in just before a PUT). Every request is in state().log as
//! (method, path), and its Authorization header in state().auths.
//!
//! HTTP/1.1 with keep-alive and a Content-Length on every answer, which is
//! all the sync's libcurl needs.

use super::codec::{
    base64, base64url, element_texts, form, quote, root_name, sha256, unquote, xml_escape,
};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::Duration;

pub struct Calendar {
    pub name: String,
    pub display: String,
    pub components: Vec<String>,
    pub color: String,
    pub read_only: bool,
    /// Resource name -> (ETag, text).
    pub items: BTreeMap<String, (String, String)>,
    /// (sequence, resource name), the name deleted when not in items.
    log: Vec<(u64, String)>,
    seq: u64,
    ctag: u64,
}

/// Google's endpoints: what the sign-in checks, and what it was asked.
pub struct OAuth {
    pub client_id: String,
    pub code: String,
    pub refresh: String,
    pub email: String,
    pub challenge: Option<String>,
    pub revoked: bool,
    /// The form of every request to /token.
    pub requests: Vec<HashMap<String, String>>,
}

impl OAuth {
    pub fn new(client_id: &str, code: &str, refresh: &str, email: &str) -> OAuth {
        OAuth {
            client_id: client_id.into(),
            code: code.into(),
            refresh: refresh.into(),
            email: email.into(),
            challenge: None,
            revoked: false,
            requests: Vec::new(),
        }
    }
}

pub struct State {
    pub user: String,
    pub password: String,
    pub bearer: Option<String>,
    pub calendars: Vec<Calendar>,
    pub sync_tokens: bool,
    pub etag_on_put: bool,
    pub home_url: Option<String>,
    pub moved: HashMap<String, String>,
    pub unlisted: BTreeSet<String>,
    pub elsewhere: Vec<String>,
    pub withheld: BTreeSet<String>,
    pub vanished: BTreeSet<String>,
    pub delay: HashMap<String, f64>,
    pub feed_private: bool,
    pub trickle: f64,
    pub log: Vec<(String, String)>,
    pub auths: Vec<Option<String>>,
    etags: u64,
    /// (ETag, text) served at /feed.ics.
    pub feed: Option<(String, String)>,
    pub oauth: Option<OAuth>,
    /// {"calendar/name": text}: the phone saves this just before the next PUT
    /// of that item arrives, so that the PUT meets an ETag that has moved.
    pub race: HashMap<String, String>,
}

impl State {
    pub fn calendar_mut(&mut self, name: &str) -> &mut Calendar {
        self.calendars
            .iter_mut()
            .find(|c| c.name == name)
            .unwrap_or_else(|| panic!("the fake has no calendar {name}"))
    }

    fn calendar(&self, name: &str) -> Option<&Calendar> {
        self.calendars.iter().find(|c| c.name == name)
    }

    /// The (method, path) of every request so far to <path>, with its
    /// Authorization header.
    pub fn requests_to(&self, path: &str) -> Vec<(String, Option<String>)> {
        self.log
            .iter()
            .zip(&self.auths)
            .filter(|((_, p), _)| p == path)
            .map(|((m, _), a)| (m.clone(), a.clone()))
            .collect()
    }

    pub fn clear_log(&mut self) {
        self.log.clear();
        self.auths.clear();
    }
}

struct Shared {
    state: Mutex<State>,
    port: AtomicU16,
}

pub struct Fake {
    shared: Arc<Shared>,
    accepting: Mutex<Option<(Arc<AtomicBool>, JoinHandle<()>)>>,
}

struct Request {
    method: String,
    path: String,
    query: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl Request {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

enum Reply {
    Plain(u16, Vec<(String, String)>, Vec<u8>),
    /// A 200 sent a byte at a time, this many seconds apart.
    Trickle(Vec<u8>, f64),
}

fn reply(status: u16, data: impl Into<Vec<u8>>, headers: &[(&str, &str)]) -> Reply {
    Reply::Plain(
        status,
        headers
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        data.into(),
    )
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        207 => "Multi-Status",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        412 => "Precondition Failed",
        _ => "Status",
    }
}

const DAV_COLLECTION: &str = "<d:resourcetype><d:collection/></d:resourcetype>";
const NOT_FOUND: &str = "HTTP/1.1 404 Not Found";

impl Fake {
    pub fn new(user: Option<&str>, password: Option<&str>, bearer: Option<&str>) -> Fake {
        let fake = Fake {
            shared: Arc::new(Shared {
                state: Mutex::new(State {
                    user: user.unwrap_or("alice").into(),
                    password: password.unwrap_or("pw-SECRET-1").into(),
                    bearer: bearer.map(String::from),
                    calendars: Vec::new(),
                    sync_tokens: true,
                    etag_on_put: true,
                    home_url: None,
                    moved: HashMap::new(),
                    unlisted: BTreeSet::new(),
                    elsewhere: Vec::new(),
                    withheld: BTreeSet::new(),
                    vanished: BTreeSet::new(),
                    delay: HashMap::new(),
                    feed_private: false,
                    trickle: 0.0,
                    log: Vec::new(),
                    auths: Vec::new(),
                    etags: 0,
                    feed: None,
                    oauth: None,
                    race: HashMap::new(),
                }),
                port: AtomicU16::new(0),
            }),
            accepting: Mutex::new(None),
        };
        fake.start();
        fake
    }

    /// The options and the logs; hold it for a statement, not across a sync.
    pub fn state(&self) -> MutexGuard<'_, State> {
        self.shared.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn add_calendar(&self, name: &str, display: &str, components: &[&str], color: &str) {
        self.state().calendars.push(Calendar {
            name: name.into(),
            display: display.into(),
            components: components.iter().map(|c| c.to_string()).collect(),
            color: color.into(),
            read_only: false,
            items: BTreeMap::new(),
            log: Vec::new(),
            seq: 0,
            ctag: 0,
        });
    }

    pub fn port(&self) -> u16 {
        self.shared.port.load(Ordering::SeqCst)
    }

    pub fn url(&self) -> String {
        format!("http://127.0.0.1:{}/", self.port())
    }

    /// Listens, on the port it had before if it had one.
    pub fn start(&self) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, self.port()))
            .expect("the fake CalDAV server cannot listen");
        self.shared.port.store(
            listener.local_addr().expect("a bound address").port(),
            Ordering::SeqCst,
        );
        let stopped = Arc::new(AtomicBool::new(false));
        let (shared, flag) = (self.shared.clone(), stopped.clone());
        let handle = thread::spawn(move || {
            for stream in listener.incoming() {
                if flag.load(Ordering::SeqCst) {
                    return;
                }
                if let Ok(stream) = stream {
                    let shared = shared.clone();
                    thread::spawn(move || serve(&shared, stream));
                }
            }
        });
        *self.accepting.lock().unwrap_or_else(|e| e.into_inner()) = Some((stopped, handle));
    }

    /// Stops listening, so that the next connection is refused. A request
    /// being answered is answered.
    pub fn stop(&self) {
        let taken = self
            .accepting
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take();
        if let Some((stopped, handle)) = taken {
            stopped.store(true, Ordering::SeqCst);
            // The thread waits in accept: a connection wakes it.
            let _ = TcpStream::connect(SocketAddr::from((Ipv4Addr::LOCALHOST, self.port())));
            let _ = handle.join();
        }
    }
}

impl Drop for Fake {
    fn drop(&mut self) {
        self.stop();
    }
}

fn read_request(reader: &mut BufReader<TcpStream>) -> Option<Request> {
    let mut line = String::new();
    if reader.read_line(&mut line).ok()? == 0 {
        return None;
    }
    let mut parts = line.split_whitespace();
    let method = parts.next()?.to_string();
    let target = parts.next()?.to_string();
    let mut headers = Vec::new();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }
        let (k, v) = line.split_once(':')?;
        headers.push((k.trim().to_string(), v.trim().to_string()));
    }
    let length = headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.parse::<usize>().ok())
        .unwrap_or(0);
    let mut body = vec![0; length];
    reader.read_exact(&mut body).ok()?;
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    Some(Request {
        method,
        path: path.to_string(),
        query: query.to_string(),
        headers,
        body,
    })
}

fn serve(shared: &Shared, stream: TcpStream) {
    let _ = stream.set_nodelay(true);
    let Ok(read_half) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(read_half);
    let mut stream = stream;
    while let Some(request) = read_request(&mut reader) {
        let close = request
            .header("connection")
            .is_some_and(|c| c.eq_ignore_ascii_case("close"));
        if write_reply(&mut stream, shared.answer(&request)).is_err() || close {
            return;
        }
    }
}

fn write_reply(stream: &mut TcpStream, reply: Reply) -> std::io::Result<()> {
    let (status, headers, data, trickle) = match reply {
        Reply::Plain(status, headers, data) => (status, headers, data, 0.0),
        Reply::Trickle(data, seconds) => (200, Vec::new(), data, seconds),
    };
    let mut head = format!("HTTP/1.1 {status} {}\r\n", reason(status));
    for (k, v) in headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    head.push_str(&format!("Content-Length: {}\r\n\r\n", data.len()));
    stream.write_all(head.as_bytes())?;
    if trickle > 0.0 {
        for byte in &data {
            stream.write_all(&[*byte])?;
            stream.flush()?;
            thread::sleep(Duration::from_secs_f64(trickle));
        }
        return Ok(());
    }
    stream.write_all(&data)?;
    stream.flush()
}

impl Shared {
    fn answer(&self, request: &Request) -> Reply {
        let delay = {
            let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
            s.log.push((request.method.clone(), request.path.clone()));
            s.auths
                .push(request.header("authorization").map(String::from));
            s.delay.get(&request.path).copied().unwrap_or(0.0)
        };
        if delay > 0.0 {
            thread::sleep(Duration::from_secs_f64(delay));
        }
        let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
        s.respond(request)
    }
}

impl State {
    fn respond(&mut self, r: &Request) -> Reply {
        let path = r.path.as_str();
        if let Some(to) = self.moved.get(path) {
            return reply(307, "", &[("Location", to)]);
        }
        if path == "/token" && r.method == "POST" && self.oauth.is_some() {
            return self.token(r);
        }
        if path == "/auth" && self.oauth.is_some() {
            return self.sign_in(r);
        }
        if path == "/feed.ics" && !self.feed_private {
            return self.serve_feed(r);
        }
        if !self.authorized(r) {
            return reply(401, "", &[("WWW-Authenticate", "Basic realm=\"fake\"")]);
        }
        if path == "/feed.ics" {
            return self.serve_feed(r);
        }
        if path == "/.well-known/caldav" {
            return reply(301, "", &[("Location", "/")]);
        }
        if let Some(rest) = path.strip_prefix("/alice/cals/") {
            let (cal, resource) = match rest.split_once('/') {
                Some((cal, resource)) => (cal, Some(resource)),
                None => (rest, None),
            };
            if !cal.is_empty() && self.calendar(cal).is_some() {
                match resource {
                    Some(name) if !name.is_empty() && !name.contains('/') => {
                        return self.resource(r, cal, &unquote(name, false));
                    }
                    None | Some("") => return self.collection(r, cal),
                    _ => {}
                }
            }
        }
        if r.method == "PROPFIND" {
            if path == "/" || path == "/alice/" {
                return self.principal(path);
            }
            if path == "/alice/cals/" {
                return self.home(r);
            }
        }
        reply(404, "", &[])
    }

    fn authorized(&self, r: &Request) -> bool {
        let got = r.header("authorization").unwrap_or("");
        match &self.bearer {
            Some(bearer) => got == format!("Bearer {bearer}"),
            None => {
                got == format!(
                    "Basic {}",
                    base64(format!("{}:{}", self.user, self.password).as_bytes())
                )
            }
        }
    }

    fn multistatus(&self, responses: &[String], extra: &str) -> Reply {
        let xml = format!(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\" \
             xmlns:c=\"urn:ietf:params:xml:ns:caldav\" xmlns:cs=\"http://calendarserver.org/ns/\" \
             xmlns:a=\"http://apple.com/ns/ical/\">{}{extra}</d:multistatus>",
            responses.concat()
        );
        reply(
            207,
            xml,
            &[("Content-Type", "application/xml; charset=utf-8")],
        )
    }

    fn response(&self, href: &str, props: &[String]) -> String {
        format!(
            "<d:response><d:href>{}</d:href><d:propstat><d:prop>{}</d:prop>\
             <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>",
            xml_escape(href),
            props.concat()
        )
    }

    fn gone(&self, href: &str) -> String {
        format!(
            "<d:response><d:href>{}</d:href><d:status>{NOT_FOUND}</d:status></d:response>",
            xml_escape(href)
        )
    }

    fn principal(&self, path: &str) -> Reply {
        let home = self.home_url.as_deref().unwrap_or("/alice/cals/");
        let mut props = vec![
            "<d:current-user-principal><d:href>/alice/</d:href></d:current-user-principal>"
                .to_string(),
        ];
        if path == "/alice/" {
            props.push(format!(
                "<c:calendar-home-set><d:href>{home}</d:href></c:calendar-home-set>"
            ));
        }
        self.multistatus(&[self.response(path, &props)], "")
    }

    fn home(&self, r: &Request) -> Reply {
        let mut out = vec![self.response("/alice/cals/", &[DAV_COLLECTION.into()])];
        if r.header("depth") != Some("1") {
            return self.multistatus(&out, "");
        }
        out.push(self.response(
            "/alice/cals/inbox/",
            &["<d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype>".into()],
        ));
        for c in &self.calendars {
            if !self.unlisted.contains(&c.name) {
                out.push(self.response(&format!("/alice/cals/{}/", c.name), &self.props(c)));
            }
        }
        for href in &self.elsewhere {
            out.push(self.response(
                href,
                &[
                    "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>".into(),
                    "<d:displayname>Elsewhere</d:displayname>".into(),
                ],
            ));
        }
        self.multistatus(&out, "")
    }

    fn props(&self, c: &Calendar) -> Vec<String> {
        let privileges = format!(
            "<d:privilege><d:read/></d:privilege>{}",
            if c.read_only {
                ""
            } else {
                "<d:privilege><d:write/></d:privilege>"
            }
        );
        let comps: String = c
            .components
            .iter()
            .map(|n| format!("<c:comp name=\"{n}\"/>"))
            .collect();
        let mut props = vec![
            "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>".to_string(),
            format!("<d:displayname>{}</d:displayname>", xml_escape(&c.display)),
            format!("<a:calendar-color>{}</a:calendar-color>", c.color),
            format!(
                "<c:supported-calendar-component-set>{comps}</c:supported-calendar-component-set>"
            ),
            format!("<d:current-user-privilege-set>{privileges}</d:current-user-privilege-set>"),
            format!("<cs:getctag>c{}</cs:getctag>", c.ctag),
        ];
        if self.sync_tokens {
            props.push(format!(
                "<d:sync-token>http://fake/sync/{}</d:sync-token>",
                c.seq
            ));
        }
        props
    }

    fn collection(&mut self, r: &Request, cal: &str) -> Reply {
        let c = self.calendar(cal).expect("a calendar that was found");
        let base = format!("/alice/cals/{}/", c.name);
        if r.method == "PROPFIND" {
            let mut out = vec![self.response(&base, &self.props(c))];
            if r.header("depth") == Some("1") {
                for (name, (etag, _)) in &c.items {
                    out.push(self.response(
                        &format!("{base}{}", quote(name, "/")),
                        &[
                            format!("<d:getetag>{}</d:getetag>", xml_escape(etag)),
                            "<d:resourcetype/>".into(),
                        ],
                    ));
                }
            }
            return self.multistatus(&out, "");
        }
        if r.method != "REPORT" {
            return reply(405, "", &[]);
        }
        let body = String::from_utf8_lossy(&r.body);
        match root_name(&body).as_deref() {
            Some("sync-collection") => {
                if !self.sync_tokens {
                    return reply(403, "", &[]);
                }
                let token = element_texts(&body, "sync-token")
                    .into_iter()
                    .next()
                    .unwrap_or_default();
                let since = token
                    .strip_prefix("http://fake/sync/")
                    .and_then(|n| n.parse::<i64>().ok());
                if !token.is_empty() && since.is_none() {
                    return reply(
                        403,
                        "<d:error xmlns:d=\"DAV:\"><d:valid-sync-token/></d:error>",
                        &[],
                    );
                }
                let names: BTreeSet<&String> = match since {
                    Some(since) => c
                        .log
                        .iter()
                        .filter(|(seq, _)| *seq as i64 > since)
                        .map(|(_, name)| name)
                        .collect(),
                    None => c.items.keys().collect(),
                };
                let mut out = Vec::new();
                for name in names {
                    let href = format!("{base}{}", quote(name, "/"));
                    match c.items.get(name) {
                        Some((etag, _)) => out.push(self.response(
                            &href,
                            &[format!("<d:getetag>{}</d:getetag>", xml_escape(etag))],
                        )),
                        None => out.push(self.gone(&href)),
                    }
                }
                let extra = format!("<d:sync-token>http://fake/sync/{}</d:sync-token>", c.seq);
                self.multistatus(&out, &extra)
            }
            Some("calendar-multiget") => {
                let mut out = Vec::new();
                for href in element_texts(&body, "href") {
                    let name = unquote(href.rsplit('/').next().unwrap_or(""), false);
                    if self.withheld.contains(&name) {
                        continue;
                    }
                    match c.items.get(&name) {
                        Some((etag, text)) if !self.vanished.contains(&name) => {
                            out.push(self.response(
                                &href,
                                &[
                                    format!("<d:getetag>{}</d:getetag>", xml_escape(etag)),
                                    format!(
                                        "<c:calendar-data>{}</c:calendar-data>",
                                        xml_escape(text)
                                    ),
                                ],
                            ));
                        }
                        _ => out.push(self.gone(&href)),
                    }
                }
                self.multistatus(&out, "")
            }
            _ => reply(400, "", &[]),
        }
    }

    fn resource(&mut self, r: &Request, cal: &str, name: &str) -> Reply {
        if r.method == "PUT" {
            if let Some(text) = self.race.remove(&format!("{cal}/{name}")) {
                self.etags += 1;
                let etag = format!("\"e{}\"", self.etags);
                let c = self.calendar_mut(cal);
                c.items.insert(name.to_string(), (etag, text));
                c.changed(name);
            }
        }
        let etag_on_put = self.etag_on_put;
        let new_etag = format!("\"e{}\"", self.etags + 1);
        let c = self.calendar_mut(cal);
        let current = c.items.get(name).cloned();
        if r.method == "GET" {
            return match current {
                None => reply(404, "", &[]),
                Some((etag, text)) => reply(
                    200,
                    text,
                    &[("ETag", &etag), ("Content-Type", "text/calendar")],
                ),
            };
        }
        let (matching, none) = (r.header("if-match"), r.header("if-none-match"));
        let stale =
            matching.is_some_and(|m| !m.is_empty() && current.as_ref().is_none_or(|(e, _)| e != m));
        if stale || (none == Some("*") && current.is_some()) {
            return reply(412, "", &[]);
        }
        match r.method.as_str() {
            "PUT" => {
                if c.read_only {
                    return reply(403, "", &[]);
                }
                c.items.insert(
                    name.to_string(),
                    (
                        new_etag.clone(),
                        String::from_utf8_lossy(&r.body).into_owned(),
                    ),
                );
                c.changed(name);
                self.etags += 1;
                let status = if current.is_some() { 204 } else { 201 };
                if etag_on_put {
                    reply(status, "", &[("ETag", &new_etag)])
                } else {
                    reply(status, "", &[])
                }
            }
            "DELETE" => {
                if c.read_only {
                    return reply(403, "", &[]);
                }
                if current.is_none() {
                    return reply(404, "", &[]);
                }
                c.items.remove(name);
                c.changed(name);
                reply(204, "", &[])
            }
            _ => reply(405, "", &[]),
        }
    }

    fn serve_feed(&self, r: &Request) -> Reply {
        let Some((etag, text)) = &self.feed else {
            return reply(404, "", &[]);
        };
        if r.header("if-none-match") == Some(etag.as_str()) {
            return reply(304, "", &[]);
        }
        if self.trickle <= 0.0 {
            return reply(
                200,
                text.as_str(),
                &[("ETag", etag), ("Content-Type", "text/calendar")],
            );
        }
        Reply::Trickle(text.clone().into_bytes(), self.trickle)
    }

    /// Google's sign-in page, signed in at once: back to the app with a code.
    fn sign_in(&mut self, r: &Request) -> Reply {
        let fields: HashMap<String, String> = form(&r.query).into_iter().collect();
        let oauth = self.oauth.as_mut().expect("Google's endpoints are set");
        oauth.challenge = fields.get("code_challenge").cloned();
        let back = format!(
            "{}/?code={}&state={}",
            fields.get("redirect_uri").map_or("", String::as_str),
            quote(&oauth.code, ""),
            quote(fields.get("state").map_or("", String::as_str), "")
        );
        reply(302, "", &[("Location", &back)])
    }

    /// Google's token endpoint: a code for the verifier its challenge was
    /// made from, and a refresh token for a new access token.
    fn token(&mut self, r: &Request) -> Reply {
        let fields: HashMap<String, String> = form(&String::from_utf8_lossy(&r.body))
            .into_iter()
            .collect();
        let access = self.bearer.clone().unwrap_or_default();
        let oauth = self.oauth.as_mut().expect("Google's endpoints are set");
        oauth.requests.push(fields.clone());
        let get = |k: &str| fields.get(k).map_or("", String::as_str);
        if get("client_id") != oauth.client_id {
            return reply(401, "{\"error\": \"invalid_client\"}", &[]);
        }
        let answer = match get("grant_type") {
            "authorization_code" => {
                let challenge = base64url(&sha256(get("code_verifier").as_bytes()));
                if get("code") != oauth.code || Some(&challenge) != oauth.challenge.as_ref() {
                    return reply(400, "{\"error\": \"invalid_grant\"}", &[]);
                }
                let claims = base64url(format!("{{\"email\": \"{}\"}}", oauth.email).as_bytes());
                format!(
                    "{{\"access_token\": \"{access}\", \"expires_in\": 3600, \"refresh_token\": \"{}\", \"id_token\": \"x.{claims}.y\"}}",
                    oauth.refresh
                )
            }
            "refresh_token" => {
                if get("refresh_token") != oauth.refresh || oauth.revoked {
                    return reply(400, "{\"error\": \"invalid_grant\"}", &[]);
                }
                format!("{{\"access_token\": \"{access}\", \"expires_in\": 3600}}")
            }
            _ => return reply(400, "{\"error\": \"unsupported_grant_type\"}", &[]),
        };
        reply(200, answer, &[("Content-Type", "application/json")])
    }
}

impl Calendar {
    fn changed(&mut self, name: &str) {
        self.seq += 1;
        self.ctag += 1;
        self.log.push((self.seq, name.to_string()));
    }
}
