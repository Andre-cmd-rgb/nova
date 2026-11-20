//! nova-calendar: the Calendar's two-way sync
//! (src/shell/plugins/calendar/README.md): iCloud, Google and any CalDAV
//! server, and read-only subscriptions to an iCal link.
//!
//!   nova-calendar-sync [sync] [<id>]     every account and subscription, or one
//!   nova-calendar-sync add               an account, from a line of JSON on
//!       stdin: {"type": "icloud" | "caldav", "url", "user", "password"}, or
//!       {"type": "google"}, which signs in in the browser; prints the account
//!       and the calendars it found, as JSON
//!   nova-calendar-sync subscribe         {"url"}, a line on stdin; prints the
//!       calendar
//!   nova-calendar-sync remove <id>       an account or a subscription
//!   nova-calendar-sync set <id> shown=true|false color=<name> name=<text>
//!   nova-calendar-sync google            exits 0 when Google sign-in is set up
//!
//! Where things are:
//!   ~/.config/nova/calendars.json        the accounts and calendars: names,
//!       colours, shown or not; written here only, under a lock, and read by
//!       the shell. No secret is in it.
//!   ~/.local/share/nova/calendar/<id>.ics   a calendar's events and tasks,
//!       one iCalendar file as calendar.ics is, read and written by the shell
//!   ~/.local/state/nova/calendar-sync/   what the server last had of each
//!       item (its ETag and its text), the sync tokens, and status.json, how
//!       each account's last sync went
//!   the login keyring (secret-tool)      passwords, Google's tokens, and the
//!       addresses of subscriptions, which can be secrets themselves
//!
//! A sync compares three versions of each item: the server's, the file's, and
//! the one both had at the last sync. What changed on one side only goes to the
//! other; an edit made offline is only a difference from the last sync, so it
//! waits in the file until the server can be reached. The server's changes are
//! found with WebDAV sync-collection (RFC 6578) where it has a sync token, else
//! by its ctag and each item's ETag; every write says which ETag it replaces
//! (If-Match), or that it replaces nothing (If-None-Match), so a change made
//! meanwhile on the phone is never written over: it is merged instead.
//!
//! Changed on both sides, an item is merged property by property (a new title
//! here, a new time there); where both changed the same property differently,
//! the server's version stays the item and this computer's is kept beside it
//! as a copy, sent to the server too: nothing is lost, and the phone shows the
//! same as the computer. Deleted on one side and changed on the other, the
//! change wins.
//!
//! What looks broken deletes nothing. A file gone, emptied, or with most of
//! its items gone at once (FEW) sends nothing, and gets the server's items
//! back. A calendar the server stops listing goes, unless its file has changes
//! not yet sent: then it stays, marked gone, until the server lists it again or
//! the account is removed. An item the server leaves out of an answer is not
//! taken as deleted; only a 404 says so.
//!
//! The shell writes a calendar's file whole, and may write it while a sync
//! runs: the file is replaced by swapping it with the new one
//! (renameat2 RENAME_EXCHANGE), and what was swapped out is checked to be what
//! the sync read; if the shell wrote meanwhile, the sync merges that too.
//!
//! HTTP and TLS are libcurl's; the rest is the crate's own. Tests live in
//! tests/ (a CalDAV server of their own, on 127.0.0.1).

pub mod curl;
pub mod dav;
pub mod digest;
pub mod google;
pub mod http;
pub mod ical;
pub mod json;
pub mod store;
pub mod sync;
pub mod url;
pub mod xml;
pub mod zone;

use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::OnceLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use dav::{discover, href_key, list_calendars, nearest_color, PALETTE};
use google::GoogleAuth;
use http::{loopback, Auth, Http};
use ical::{calendar_of, is_item, parse, serialize, timezones, unescape, value, zone_ids};
use json::Json;
use store::{
    accounts, accounts_mut, calendars, calendars_mut, edit_config, ensure_dirs, load_config,
    load_state, new_id, read_file, save_state, save_status, secret_clear, secret_lookup,
    secret_store, state_path, Lock,
};
use sync::CalendarSync;

/// How a sync went wrong: no network, or the server out of reach
/// (offline); the password or the token refused (signin); or anything else.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kind {
    Offline,
    Signin,
    Error,
}

/// What went wrong, in words for the Calendar to show, and the changes made
/// here not yet sent.
#[derive(Debug, Clone)]
pub struct SyncError {
    pub kind: Kind,
    pub words: String,
    pub pending: usize,
}

impl SyncError {
    pub fn new(kind: Kind, words: impl Into<String>) -> SyncError {
        SyncError {
            kind,
            words: words.into(),
            pending: 0,
        }
    }

    pub fn error(words: impl Into<String>) -> SyncError {
        SyncError::new(Kind::Error, words)
    }

    pub fn signin(words: impl Into<String>) -> SyncError {
        SyncError::new(Kind::Signin, words)
    }

    pub fn offline(words: impl Into<String>) -> SyncError {
        SyncError::new(Kind::Offline, words)
    }

    fn kind_name(&self) -> &'static str {
        match self.kind {
            Kind::Offline => "offline",
            Kind::Signin => "signin",
            Kind::Error => "error",
        }
    }
}

pub struct Settings {
    pub config_home: PathBuf,
    pub config_path: PathBuf,
    pub data_dir: PathBuf,
    pub state_dir: PathBuf,
    pub nova_path: PathBuf,
    pub icloud_url: String,
    pub google_auth: String,
    pub google_token: String,
    pub google_caldav: String,
    pub sign_in_time: Duration,
    /// The longest a request may go with no byte moving.
    pub timeout: Duration,
    /// The longest an account's or a subscription's sync goes on: a server
    /// that answers a byte at a time does not hold the sync, and its lock,
    /// for hours.
    pub sync_time: Duration,
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn seconds_of(name: &str, default: f64) -> Duration {
    let s = env(name)
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|s| s.is_finite() && *s > 0.0);
    Duration::from_secs_f64(s.unwrap_or(default))
}

pub fn settings() -> &'static Settings {
    static SETTINGS: OnceLock<Settings> = OnceLock::new();
    SETTINGS.get_or_init(|| {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".into()));
        let dir = |variable: &str, fallback: &str| match std::env::var(variable) {
            Ok(v) if v.starts_with('/') => PathBuf::from(v),
            _ => home.join(fallback),
        };
        let config_home = dir("XDG_CONFIG_HOME", ".config");
        Settings {
            config_path: config_home.join("nova/calendars.json"),
            config_home,
            data_dir: dir("XDG_DATA_HOME", ".local/share").join("nova/calendar"),
            state_dir: dir("XDG_STATE_HOME", ".local/state").join("nova/calendar-sync"),
            nova_path: PathBuf::from(env("NOVA_PATH").unwrap_or_else(|| "/usr/share/nova".into())),
            icloud_url: env("NOVA_CALENDAR_ICLOUD")
                .unwrap_or_else(|| "https://caldav.icloud.com/".into()),
            google_auth: env("NOVA_CALENDAR_GOOGLE_AUTH")
                .unwrap_or_else(|| "https://accounts.google.com/o/oauth2/v2/auth".into()),
            google_token: env("NOVA_CALENDAR_GOOGLE_TOKEN")
                .unwrap_or_else(|| "https://oauth2.googleapis.com/token".into()),
            google_caldav: env("NOVA_CALENDAR_GOOGLE_CALDAV")
                .unwrap_or_else(|| "https://apidata.googleusercontent.com/caldav/v2/".into()),
            sign_in_time: seconds_of("NOVA_CALENDAR_SIGN_IN_SECONDS", 300.0),
            timeout: seconds_of("NOVA_CALENDAR_TIMEOUT", 30.0),
            sync_time: seconds_of("NOVA_CALENDAR_SYNC_SECONDS", 600.0),
        }
    })
}

/// Seconds since 1970.
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

// ---- accounts

fn account_auth(account: &Json) -> Result<Auth, SyncError> {
    let secret = secret_lookup(account.text("id"))?;
    if account.text("type") == "google" {
        let client = google::client()
            .ok_or_else(|| SyncError::signin("Google sign-in is not set up on this computer."))?;
        let tokens = json::parse(&secret)
            .filter(Json::is_object)
            .ok_or_else(|| SyncError::signin("Google asks to sign in again."))?;
        return Ok(Auth::Google(GoogleAuth::new(
            Some(account.text("id").to_string()),
            tokens,
            client,
        )));
    }
    Ok(Auth::basic(account.text("user"), &secret))
}

fn colors_used(config: &Json) -> Vec<Option<String>> {
    calendars(config)
        .iter()
        .map(|c| c.get("color").and_then(Json::as_str).map(str::to_string))
        .collect()
}

fn add_calendars(config: &mut Json, account: &Json, found: Vec<Json>) -> Vec<Json> {
    let mut used = colors_used(config);
    let mut out = Vec::new();
    for mut info in found {
        let server_color = info
            .remove("serverColor")
            .and_then(|c| c.as_str().map(str::to_string))
            .unwrap_or_default();
        let color = nearest_color(&server_color, &used);
        used.push(Some(color.clone()));
        let cid = new_id();
        let name = info.text("name").to_string();
        for (k, v) in [
            ("id", Json::str(&cid)),
            ("account", Json::str(account.text("id"))),
            ("kind", Json::str("caldav")),
            ("color", Json::str(color)),
            ("shown", Json::Bool(true)),
            ("file", Json::str(format!("{cid}.ics"))),
            ("serverName", Json::str(name)),
        ] {
            info.set(k, v);
        }
        calendars_mut(config).push(info.clone());
        out.push(info);
    }
    out
}

fn own_id(id: &str) -> bool {
    id.len() == 8 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A calendar's file and state, once it is gone from the list.
fn forget_calendar(c: &Json) {
    let id = c.text("id");
    if !own_id(id) {
        return;
    }
    let _ = std::fs::remove_file(settings().data_dir.join(format!("{id}.ics")));
    let _ = std::fs::remove_file(state_path(id));
}

/// New calendars made on the phone or the web come in, those deleted there
/// go, and a name changed there follows unless it was changed here. One gone
/// from the server with changes made here not sent stays, marked gone, and
/// syncs again if it comes back.
fn refresh_calendars(http: &mut Http, account: &Json) -> Result<Vec<Json>, SyncError> {
    let found = list_calendars(http, account.text("home"))?;
    if found.is_empty() {
        // Never so: a server's answer gone wrong.
        return Err(SyncError::error(
            "The server listed none of the account's calendars.",
        ));
    }
    let id = account.text("id").to_string();
    let (calendars_now, gone) = edit_config(|config| {
        let mut seen = Vec::new();
        let mut new = Vec::new();
        for info in found {
            let k = href_key(info.text("href"));
            seen.push(k.clone());
            let mine = calendars_mut(config)
                .iter_mut()
                .find(|c| c.text("account") == id && href_key(c.text("href")) == k);
            let Some(c) = mine else {
                new.push(info);
                continue;
            };
            if c.get("name") == c.get("serverName") {
                c.set("name", Json::str(info.text("name")));
            }
            c.remove("gone");
            for key in ["readOnly", "events", "tasks"] {
                c.set(key, info.get(key).cloned().unwrap_or(Json::Null));
            }
            c.set("serverName", Json::str(info.text("name")));
            c.set("href", Json::str(info.text("href")));
        }
        add_calendars(config, account, new);
        let mut gone = Vec::new();
        for c in calendars_mut(config).iter_mut() {
            if c.text("account") != id || seen.contains(&href_key(c.text("href"))) {
                continue;
            }
            let kept = CalendarSync::new(None, c)
                .count_pending()
                .map_or(true, |n| n > 0);
            if kept {
                c.set("gone", Json::Bool(true));
            } else {
                gone.push(c.text("id").to_string());
            }
        }
        let mut forgotten = Vec::new();
        calendars_mut(config).retain(|c| {
            let going = c.text("account") == id && gone.contains(&c.text("id").to_string());
            if going {
                forgotten.push(c.clone());
            }
            !going
        });
        let mine = calendars(config)
            .iter()
            .filter(|c| c.text("account") == id)
            .cloned()
            .collect();
        Ok((mine, forgotten))
    })?;
    for c in &gone {
        forget_calendar(c);
    }
    Ok(calendars_now)
}

/// The changes left to send, once the account's calendars are synced; one
/// calendar failing does not stop the others.
fn sync_account(account: &Json) -> Result<usize, SyncError> {
    let mut http = Http::new(Some(account_auth(account)?), account.text("url"));
    let mut cals: Vec<Json> = calendars(&load_config()?)
        .iter()
        .filter(|c| c.text("account") == account.text("id") && c.get("account").is_some())
        .cloned()
        .collect();
    let outcome = (|| -> Result<usize, SyncError> {
        cals = refresh_calendars(&mut http, account)?;
        let mut pending = 0;
        let mut failed: Option<SyncError> = None;
        for cal in &cals {
            let mut job = CalendarSync::new(Some(&mut http), cal);
            if cal.is("gone") {
                pending += job.count_pending().unwrap_or(0);
                failed = failed.or_else(|| {
                    Some(SyncError::error(format!(
                        "{} is gone from the server. The changes made to it here are kept on this computer.",
                        cal.text("name")
                    )))
                });
                continue;
            }
            if let Err(e) = job.run() {
                if e.kind != Kind::Error {
                    return Err(e);
                }
                failed = failed.or(Some(e));
            }
            pending += job.pending;
        }
        match failed {
            Some(mut e) => {
                e.pending = pending;
                Err(e)
            }
            None => Ok(pending),
        }
    })();
    match outcome {
        Err(mut e) if e.kind == Kind::Offline => {
            e.pending = cals
                .iter()
                .map(|c| CalendarSync::new(None, c).count_pending().unwrap_or(0))
                .sum();
            Err(e)
        }
        other => other,
    }
}

fn plain_url(address: &str) -> String {
    let Some(u) = url::split(address) else {
        return address.to_string();
    };
    let host = u.hostname().unwrap_or_default();
    let host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host
    };
    let port = match u.port() {
        Ok(Some(p)) if p != 0 => format!(":{p}"),
        _ => String::new(),
    };
    url::unsplit(&u.scheme, &format!("{host}{port}"), &u.path, &u.query, "")
}

fn url_auth(address: &str) -> Option<Auth> {
    let u = url::split(address)?;
    let user = u.username().filter(|n| !n.is_empty())?;
    Some(Auth::basic(
        &url::unquote(user),
        &url::unquote(u.password().unwrap_or("")),
    ))
}

/// Whether <text> starts as an iCalendar file does.
fn is_calendar(text: &str) -> bool {
    let t = text.strip_prefix('\u{feff}').unwrap_or(text).trim_start();
    t.get(..15)
        .is_some_and(|s| s.eq_ignore_ascii_case("BEGIN:VCALENDAR"))
}

pub fn normalize_url(text: &str, webcal: bool) -> Result<String, SyncError> {
    let mut address = text.trim().to_string();
    if address.is_empty() {
        return Err(SyncError::error("An address is needed."));
    }
    let has_scheme = address.split_once("://").is_some_and(|(s, _)| {
        s.starts_with(|c: char| c.is_ascii_alphabetic())
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c))
    });
    if !has_scheme {
        address = format!("https://{address}");
    }
    let bad = || SyncError::error("That is not a web address.");
    let mut u = url::split(&address).ok_or_else(bad)?;
    if webcal && (u.scheme == "webcal" || u.scheme == "webcals") {
        u.scheme = "https".into();
    }
    if !(u.scheme == "http" || u.scheme == "https")
        || u.hostname().is_none()
        || address
            .chars()
            .any(|c| c.is_whitespace() || c == '"' || c == '\\')
    {
        return Err(bad());
    }
    Ok(u.unsplit())
}

fn sync_subscription(cal: &Json) -> Result<(), SyncError> {
    let address = secret_lookup(cal.text("id"))?.trim().to_string();
    let mut state = load_state(cal.text("id"));
    let path = settings().data_dir.join(cal.text("file"));
    let mut headers: Vec<(&str, String)> = vec![("Accept", "text/calendar".into())];
    if path.exists() {
        if let Some(etag) = state.text("etag") {
            headers.push(("If-None-Match", etag));
        }
        if let Some(modified) = state.text("modified") {
            headers.push(("If-Modified-Since", modified));
        }
    }
    let mut http = Http::new(url_auth(&address), &address);
    let h: Vec<(&str, &str)> = headers.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let resp = http.request("GET", &plain_url(&address), None, &h)?;
    drop(http);
    if resp.status == 304 {
        return Ok(());
    }
    if resp.status != 200 {
        dav::check(&resp, false)?;
    }
    let text = resp.text();
    if !is_calendar(&text) {
        return Err(SyncError::error("The address does not give a calendar."));
    }
    let mut root = parse(&text);
    let cal_c = calendar_of(&mut root);
    let named: Vec<String> = timezones(cal_c).into_iter().map(|(k, _)| k).collect();
    let items: Vec<ical::Component> = cal_c
        .children
        .iter()
        .filter(|c| is_item(c))
        .cloned()
        .collect();
    let extra: Vec<ical::Component> = zone_ids(&items)
        .into_iter()
        .filter(|t| !named.contains(t))
        .filter_map(|t| zone::vtimezone(&t))
        .collect();
    let mut children: Vec<ical::Component> = cal_c
        .children
        .iter()
        .filter(|c| !is_item(c))
        .cloned()
        .collect();
    children.extend(extra);
    children.extend(items);
    cal_c.children = children;
    let new = serialize(std::slice::from_ref(cal_c));
    let write_error = |_| {
        SyncError::error(format!(
            "The file of {} could not be written.",
            cal.text("name")
        ))
    };
    if read_file(&path).ok().flatten().as_deref() != Some(new.as_str()) {
        ensure_dirs().map_err(write_error)?;
        store::replace(&path, &new).map_err(write_error)?;
    }
    state.set("etag", resp.header("etag").map(str::to_string));
    state.set("modified", resp.header("last-modified").map(str::to_string));
    save_state(cal.text("id"), &state).map_err(write_error)?;
    let name = unescape(value(cal_c, "X-WR-CALNAME")).trim().to_string();
    if !name.is_empty() {
        let id = cal.text("id").to_string();
        edit_config(|config| {
            for c in calendars_mut(config) {
                if c.text("id") == id && c.get("name") == c.get("serverName") {
                    let short = Json::str(dav::chars(&name, 80));
                    c.set("name", short.clone());
                    c.set("serverName", short);
                }
            }
            Ok(())
        })?;
    }
    Ok(())
}

// ---- commands

fn read_request() -> Result<Json, SyncError> {
    let mut line = String::new();
    let _ = std::io::stdin().lock().read_line(&mut line);
    let line = if line.trim().is_empty() {
        "{}"
    } else {
        line.as_str()
    };
    json::parse(line.trim_end_matches(['\n', '\r']))
        .filter(Json::is_object)
        .ok_or_else(|| SyncError::error("The request could not be read."))
}

fn print_line(text: &str) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{text}");
}

fn cmd_add() -> Result<(), SyncError> {
    let request = read_request()?;
    let kind = request.text("type").to_string();
    let s = settings();
    let (address, user, mut secret, name, auth) = match kind.as_str() {
        "google" => {
            let client = google::client().ok_or_else(|| {
                SyncError::error("Google sign-in is not set up on this computer.")
            })?;
            let (tokens, email) = google::sign_in(&client)?;
            let name = if email.is_empty() {
                "Google".to_string()
            } else {
                email.clone()
            };
            (
                s.google_caldav.clone(),
                email,
                None,
                name,
                Auth::Google(GoogleAuth::new(None, tokens, client)),
            )
        }
        "icloud" | "caldav" => {
            let user = request.text("user").trim().to_string();
            let password = request.text("password").to_string();
            if user.is_empty() || password.is_empty() {
                return Err(SyncError::error("A user name and a password are needed."));
            }
            let address = if kind == "icloud" {
                s.icloud_url.clone()
            } else {
                normalize_url(request.text("url"), false)?
            };
            let u = url::split(&address)
                .ok_or_else(|| SyncError::error("That is not a web address."))?;
            let host = u.hostname().unwrap_or_default();
            if u.scheme != "https" && !loopback(&host) {
                return Err(SyncError::error(
                    "The address must start with https://, so that the password is not sent in the clear.",
                ));
            }
            let auth = Auth::basic(&user, &password);
            let name = if kind == "icloud" {
                "iCloud".to_string()
            } else {
                host
            };
            (address, user, Some(password), name, auth)
        }
        _ => {
            return Err(SyncError::error(
                "The account's type is not one the Calendar knows.",
            ))
        }
    };
    let mut http = Http::new(Some(auth), &address);
    let found = match discover(&mut http, &address) {
        Ok(f) => f,
        Err(e) if e.kind == Kind::Signin && kind == "icloud" => {
            return Err(SyncError::signin(
                "The Apple ID or the app-specific password was not accepted.",
            ));
        }
        Err(e) if kind != "google" || e.kind != Kind::Error || user.is_empty() => return Err(e),
        // Google's own address for the account: its principal, by the
        // address of its main calendar.
        Err(_) => discover(
            &mut http,
            &format!("{}{}/user", s.google_caldav, url::quote(&user, "/")),
        )?,
    };
    if let Some(Auth::Google(g)) = &http.auth {
        secret = Some(json::dumps(&g.tokens));
    }
    drop(http);
    if found.calendars.is_empty() {
        return Err(SyncError::error("The account has no calendars."));
    }
    let mut account = Json::object();
    account.set("id", Json::str(new_id()));
    account.set("type", Json::str(&kind));
    account.set("name", Json::str(&name));
    account.set("user", Json::str(&user));
    account.set("url", Json::str(&address));
    account.set("principal", Json::opt(found.principal.clone()));
    account.set("home", Json::str(&found.home));
    let calendars_found = found.calendars;
    let label = if !user.is_empty() && user != name {
        format!("Calendar: {name} ({user})")
    } else {
        format!("Calendar: {name}")
    };
    let secret = secret.unwrap_or_default();
    let (account, cals) = edit_config(|config| {
        let mine = account
            .get("principal")
            .filter(|p| p.truthy())
            .or(account.get("home"))
            .cloned();
        for a in accounts(config) {
            let theirs = a
                .get("principal")
                .filter(|p| p.truthy())
                .or(a.get("home"))
                .cloned();
            if a.text("type") == kind && a.get("user") == account.get("user") && theirs == mine {
                return Err(SyncError::error("This account is in the Calendar already."));
            }
        }
        secret_store(account.text("id"), &label, &secret)?;
        accounts_mut(config).push(account.clone());
        let cals = add_calendars(config, &account, calendars_found);
        Ok((account, cals))
    })?;
    let mut out = Json::object();
    out.set("account", account);
    out.set("calendars", Json::Array(cals));
    print_line(&json::dumps(&out));
    Ok(())
}

fn cmd_subscribe() -> Result<(), SyncError> {
    let request = read_request()?;
    let address = normalize_url(request.text("url"), true)?;
    let host = url::split(&address)
        .and_then(|u| u.hostname())
        .unwrap_or_default();
    let mut http = Http::new(url_auth(&address), &address);
    let resp = http.request(
        "GET",
        &plain_url(&address),
        None,
        &[("Accept", "text/calendar")],
    )?;
    drop(http);
    if resp.status != 200 {
        dav::check(&resp, false)?;
    }
    let text = resp.text();
    if !is_calendar(&text) {
        return Err(SyncError::error("The address does not give a calendar."));
    }
    let mut root = parse(&text);
    let named = dav::chars(
        unescape(value(calendar_of(&mut root), "X-WR-CALNAME")).trim(),
        80,
    );
    let name = if named.is_empty() {
        host.clone()
    } else {
        named
    };
    let cid = new_id();
    let entry = edit_config(|config| {
        let used = colors_used(config);
        secret_store(&cid, &format!("Calendar: subscription to {host}"), &address)?;
        let mut entry = Json::object();
        for (k, v) in [
            ("id", Json::str(&cid)),
            ("kind", Json::str("subscription")),
            ("name", Json::str(&name)),
            ("serverName", Json::str(&name)),
            ("host", Json::str(&host)),
            ("color", Json::str(nearest_color("", &used))),
            ("shown", Json::Bool(true)),
            ("readOnly", Json::Bool(true)),
            ("events", Json::Bool(true)),
            ("tasks", Json::Bool(false)),
            ("file", Json::str(format!("{cid}.ics"))),
        ] {
            entry.set(k, v);
        }
        calendars_mut(config).push(entry.clone());
        Ok(entry)
    })?;
    let _ = sync_subscription(&entry);
    let mut out = Json::object();
    out.set("calendar", entry);
    print_line(&json::dumps(&out));
    Ok(())
}

fn cmd_remove(target: &str) -> Result<(), SyncError> {
    // After a sync running now, which would write the calendars back.
    let _sync = Lock::take("sync.lock")?;
    let gone = edit_config(|config| {
        let gone: Vec<Json>;
        if let Some(at) = accounts(config).iter().position(|a| a.text("id") == target) {
            gone = calendars(config)
                .iter()
                .filter(|c| c.text("account") == target && c.get("account").is_some())
                .cloned()
                .collect();
            accounts_mut(config).remove(at);
        } else {
            gone = calendars(config)
                .iter()
                .filter(|c| c.text("id") == target && c.text("kind") == "subscription")
                .cloned()
                .collect();
            if gone.is_empty() {
                return Err(SyncError::error(format!(
                    "There is no account or subscription '{target}'."
                )));
            }
        }
        calendars_mut(config).retain(|c| !gone.contains(c));
        Ok(gone)
    })?;
    secret_clear(target);
    for c in &gone {
        forget_calendar(c);
    }
    save_status(target, None)
}

fn cmd_set(target: &str, pairs: &[String]) -> Result<(), SyncError> {
    edit_config(|config| {
        let cal = calendars_mut(config)
            .iter_mut()
            .find(|c| c.text("id") == target)
            .ok_or_else(|| SyncError::error(format!("There is no calendar '{target}'.")))?;
        for pair in pairs {
            let (key, val) = pair.split_once('=').unwrap_or((pair.as_str(), ""));
            match key {
                "shown" if val == "true" || val == "false" => {
                    cal.set("shown", Json::Bool(val == "true"))
                }
                "color" if PALETTE.contains(&val) => cal.set("color", Json::str(val)),
                "name" if !val.trim().is_empty() => {
                    cal.set("name", Json::str(dav::chars(val.trim(), 80)))
                }
                _ => {
                    return Err(SyncError::error(format!(
                        "'{pair}' is not a setting of a calendar."
                    )))
                }
            }
        }
        Ok(())
    })
}

fn cmd_sync(only: Option<&str>) -> Result<u8, SyncError> {
    ensure_dirs().map_err(|e| {
        SyncError::error(format!("The Calendar's folders could not be made ({e})."))
    })?;
    let _sync = Lock::take("sync.lock")?;
    let config = load_config()?;
    let mut jobs: Vec<(String, Json, bool)> = accounts(&config)
        .iter()
        .map(|a| (a.text("id").to_string(), a.clone(), true))
        .collect();
    jobs.extend(
        calendars(&config)
            .iter()
            .filter(|c| c.text("kind") == "subscription")
            .map(|c| (c.text("id").to_string(), c.clone(), false)),
    );
    let mut failed = false;
    for (key, item, is_account) in &jobs {
        if only.is_some_and(|o| o != key) {
            continue;
        }
        let mut status = Json::object();
        status.set("state", Json::str("ok"));
        status.set("at", Json::Int(now() as i64));
        let outcome = if *is_account {
            sync_account(item)
        } else {
            sync_subscription(item).map(|()| 0)
        };
        match outcome {
            Ok(pending) => status.set("pending", Json::Int(pending as i64)),
            Err(e) => {
                status.set("state", Json::str(e.kind_name()));
                status.set("message", Json::str(&e.words));
                status.set("pending", Json::Int(e.pending as i64));
                failed = failed || e.kind != Kind::Offline;
            }
        }
        save_status(key, Some(status))?;
    }
    // The files and states of calendars no longer in the list, read again
    // now: one added meanwhile is in it. Without a list, or with one that
    // cannot be read, nothing goes.
    let _config = Lock::take("config.lock")?;
    let s = settings();
    let known: Option<Vec<String>> = if s.config_path.exists() {
        load_config().ok().map(|c| {
            calendars(&c)
                .iter()
                .map(|c| c.text("id").to_string())
                .collect()
        })
    } else {
        None
    };
    if let Some(known) = known {
        for (folder, ext) in [(&s.data_dir, ".ics"), (&s.state_dir, ".json")] {
            let Ok(entries) = std::fs::read_dir(folder) else {
                continue;
            };
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if let Some(stem) = name.strip_suffix(ext) {
                    if own_id(stem) && !known.iter().any(|k| k == stem) {
                        let _ = std::fs::remove_file(entry.path());
                    }
                }
            }
        }
    }
    Ok(if failed { 1 } else { 0 })
}

const USAGE: &str =
    "Usage: nova calendar sync [<id>] | add | subscribe | remove <id> | set <id> <key>=<value>...";

fn run(args: &[String]) -> Result<u8, SyncError> {
    let command = args.first().map_or("sync", String::as_str);
    match command {
        "-h" | "--help" => {
            print_line(USAGE);
            return Ok(0);
        }
        "sync" => return cmd_sync(args.get(1).map(String::as_str)),
        _ => {}
    }
    ensure_dirs().map_err(|e| {
        SyncError::error(format!("The Calendar's folders could not be made ({e})."))
    })?;
    match (command, args.len()) {
        ("add", _) => cmd_add()?,
        ("subscribe", _) => cmd_subscribe()?,
        ("remove", 2) => cmd_remove(&args[1])?,
        ("set", n) if n >= 3 => cmd_set(&args[1], &args[2..])?,
        ("google", _) => return Ok(if google::client().is_some() { 0 } else { 1 }),
        _ => {
            eprintln!("nova-calendar-sync: unknown command '{command}'");
            return Ok(2);
        }
    }
    Ok(0)
}

/// The program: its arguments run, its exit status.
pub fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("{}", e.words);
            ExitCode::from(match e.kind {
                Kind::Signin => 3,
                Kind::Offline => 4,
                Kind::Error => 1,
            })
        }
    }
}
