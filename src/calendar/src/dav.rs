//! WebDAV and CalDAV: what the server lists (RFC 4918's PROPFIND and its
//! multistatus), the account's principal and calendar home (RFC 5397,
//! RFC 4791, RFC 6764), and its calendars.

use crate::http::{same_server, Http, Response};
use crate::json::Json;
use crate::xml::{self, Element};
use crate::{url, SyncError};

pub const DAV: &str = "DAV:";
pub const CALDAV: &str = "urn:ietf:params:xml:ns:caldav";
pub const CS: &str = "http://calendarserver.org/ns/";
pub const APPLE: &str = "http://apple.com/ns/ical/";
pub const NS: &str = r#"xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:a="http://apple.com/ns/ical/""#;

pub fn q(ns: &str, local: &str) -> String {
    format!("{{{ns}}}{local}")
}

pub fn propfind_body(props: &[&str]) -> String {
    format!(
        r#"<?xml version="1.0" encoding="utf-8"?><d:propfind {NS}><d:prop>{}</d:prop></d:propfind>"#,
        props.concat()
    )
}

/// An answer that is not what was asked for, in words.
pub fn check(resp: &Response, write: bool) -> Result<(), SyncError> {
    let s = resp.status;
    if (s == 401 || s == 403) && !write {
        return Err(SyncError::signin(
            "The user name or the password was not accepted.",
        ));
    }
    if s == 404 {
        return Err(SyncError::error(
            "The server has no calendar at that address.",
        ));
    }
    if s >= 500 {
        return Err(SyncError::error(format!(
            "The server failed to answer ({s})."
        )));
    }
    if s >= 300 {
        return Err(SyncError::error(format!(
            "The server refused the request ({s})."
        )));
    }
    Ok(())
}

/// The properties of one response, by their names.
#[derive(Debug, Default)]
pub struct Props(Vec<(String, Element)>);

impl Props {
    pub fn get(&self, tag: &str) -> Option<&Element> {
        self.0.iter().find(|(k, _)| k == tag).map(|(_, e)| e)
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    fn put(&mut self, e: Element) {
        match self.0.iter_mut().find(|(k, _)| *k == e.tag) {
            Some((_, old)) => *old = e,
            None => self.0.push((e.tag.clone(), e)),
        }
    }

    /// A property's text, trimmed; "" where it has none.
    pub fn text(&self, tag: &str) -> String {
        self.get(tag)
            .map(|e| e.text.trim().to_string())
            .unwrap_or_default()
    }
}

pub struct Found {
    pub href: String,
    pub status: String,
    pub props: Props,
}

/// The responses of a 207, each href absolute; one on another server is
/// left out.
pub fn multistatus(resp: &Response) -> Result<(Vec<Found>, Element), SyncError> {
    let root = xml::parse(&resp.body)
        .ok_or_else(|| SyncError::error("The server's answer could not be read."))?;
    let mut out = Vec::new();
    for r in root.iter(&q(DAV, "response")) {
        let Some(href) = r.findtext(&q(DAV, "href")).filter(|h| !h.is_empty()) else {
            continue;
        };
        let href = url::join(&resp.url, href.trim());
        if !same_server(&resp.url, &href)? {
            continue;
        }
        let status = r.findtext(&q(DAV, "status")).unwrap_or("").to_string();
        let mut props = Props::default();
        for ps in r.findall(&q(DAV, "propstat")) {
            if !ps
                .findtext(&q(DAV, "status"))
                .unwrap_or("")
                .contains(" 200")
            {
                continue;
            }
            if let Some(prop) = ps.find(&q(DAV, "prop")) {
                for p in &prop.children {
                    props.put(p.clone());
                }
            }
        }
        out.push(Found {
            href,
            status,
            props,
        });
    }
    Ok((out, root))
}

pub fn propfind(
    http: &mut Http,
    address: &str,
    props: &[&str],
    depth: u8,
) -> Result<Vec<Found>, SyncError> {
    let depth = depth.to_string();
    let resp = http.request(
        "PROPFIND",
        address,
        Some(&propfind_body(props)),
        &[
            ("Depth", &depth),
            ("Content-Type", "application/xml; charset=utf-8"),
        ],
    )?;
    if resp.status != 207 {
        check(&resp, false)?;
        return Err(SyncError::error("The server is not a CalDAV server."));
    }
    Ok(multistatus(&resp)?.0)
}

/// An href as a key: its path, unquoted.
pub fn href_key(href: &str) -> String {
    url::unquote(&url::split(href).map(|s| s.path).unwrap_or_default())
}

fn child_href(props: &Props, tag: &str, base: &str) -> Option<String> {
    let h = props.get(tag)?.findtext(&q(DAV, "href"))?;
    (!h.is_empty()).then(|| url::join(base, h.trim()))
}

pub fn calendar_props() -> Vec<&'static str> {
    vec![
        "<d:resourcetype/>",
        "<d:displayname/>",
        "<a:calendar-color/>",
        "<a:calendar-order/>",
        "<c:supported-calendar-component-set/>",
        "<d:current-user-privilege-set/>",
        "<cs:getctag/>",
        "<d:sync-token/>",
    ]
}

/// The first <n> characters.
pub fn chars(text: &str, n: usize) -> String {
    text.chars().take(n).collect()
}

/// A calendar the server lists, as the calendar list keeps it, with its
/// server's colour; none for what is not a calendar of events or tasks.
pub fn calendar_info(href: &str, props: &Props) -> Option<Json> {
    let rt = props.get(&q(DAV, "resourcetype"))?;
    rt.find(&q(CALDAV, "calendar"))?;
    let names: Vec<String> = match props.get(&q(CALDAV, "supported-calendar-component-set")) {
        Some(comps) => comps
            .findall(&q(CALDAV, "comp"))
            .map(|c| c.get("name").unwrap_or("").to_uppercase())
            .collect(),
        None => vec!["VEVENT".into(), "VTODO".into()],
    };
    let events = names.iter().any(|n| n == "VEVENT");
    let tasks = names.iter().any(|n| n == "VTODO");
    if !events && !tasks {
        return None;
    }
    let writable = match props.get(&q(DAV, "current-user-privilege-set")) {
        Some(privileges) => privileges.findall(&q(DAV, "privilege")).any(|p| {
            p.children.iter().any(|g| {
                [
                    q(DAV, "write"),
                    q(DAV, "write-content"),
                    q(DAV, "all"),
                    q(DAV, "bind"),
                ]
                .contains(&g.tag)
            })
        }),
        None => true,
    };
    let path = href_key(href);
    let path = path.trim_end_matches('/');
    let last = url::unquote(path.rsplit('/').next().unwrap_or(""));
    let name = Some(props.text(&q(DAV, "displayname")))
        .filter(|n| !n.is_empty())
        .or_else(|| (!last.is_empty()).then_some(last))
        .unwrap_or_else(|| "Calendar".into());
    let order_text = props.text(&q(APPLE, "calendar-order"));
    let order = if order_text.is_empty() {
        Json::Float(0.0)
    } else {
        match order_text.parse::<f64>() {
            Ok(f) => Json::Float(f),
            Err(_) => Json::Int(0),
        }
    };
    let mut info = Json::object();
    info.set(
        "href",
        Json::str(if href.ends_with('/') {
            href.to_string()
        } else {
            format!("{href}/")
        }),
    );
    info.set("name", Json::str(chars(&name, 80)));
    info.set(
        "serverColor",
        Json::str(props.text(&q(APPLE, "calendar-color"))),
    );
    info.set("events", Json::Bool(events));
    info.set("tasks", Json::Bool(tasks));
    info.set("readOnly", Json::Bool(!writable));
    info.set("order", order);
    Some(info)
}

pub struct Discovered {
    pub principal: Option<String>,
    pub home: String,
    pub calendars: Vec<Json>,
}

/// The calendars of the account at <address>: its principal, its calendar
/// home, and the calendars in it. A server's address alone is looked up at
/// /.well-known/caldav first.
pub fn discover(http: &mut Http, address: &str) -> Result<Discovered, SyncError> {
    let u = url::split(address).ok_or_else(|| SyncError::error("That is not a web address."))?;
    let start_at = format!("{}://{}", u.scheme, u.netloc);
    let starts = if u.path.is_empty() || u.path == "/" {
        vec![
            format!("{start_at}/.well-known/caldav"),
            format!("{start_at}/"),
        ]
    } else {
        vec![address.to_string()]
    };
    let mut principal: Option<String> = None;
    let mut home: Option<String> = None;
    let mut refused: Option<SyncError> = None;
    for start in &starts {
        let found = match propfind(
            http,
            start,
            &[
                "<d:current-user-principal/>",
                "<c:calendar-home-set/>",
                "<d:resourcetype/>",
            ],
            0,
        ) {
            Ok(f) => f,
            Err(e) if e.kind != crate::Kind::Error => return Err(e),
            Err(e) => {
                refused = Some(e);
                continue;
            }
        };
        for f in &found {
            principal =
                child_href(&f.props, &q(DAV, "current-user-principal"), &f.href).or(principal);
            home = child_href(&f.props, &q(CALDAV, "calendar-home-set"), &f.href).or(home);
            let is_calendar = f
                .props
                .get(&q(DAV, "resourcetype"))
                .is_some_and(|rt| rt.find(&q(CALDAV, "calendar")).is_some());
            if principal.is_none() && home.is_none() && is_calendar {
                // An address of one calendar: its folder is the home.
                home = Some(url::join(&f.href, ".."));
            }
        }
        if principal.is_some() || home.is_some() {
            break;
        }
    }
    if let (Some(p), None) = (&principal, &home) {
        for f in propfind(http, p, &["<c:calendar-home-set/>"], 0)? {
            home = child_href(&f.props, &q(CALDAV, "calendar-home-set"), &f.href).or(home);
        }
    }
    let Some(home) = home else {
        return Err(
            refused.unwrap_or_else(|| SyncError::error("No calendars were found at that address."))
        );
    };
    let calendars = list_calendars(http, &home)?;
    Ok(Discovered {
        principal,
        home,
        calendars,
    })
}

pub fn list_calendars(http: &mut Http, home: &str) -> Result<Vec<Json>, SyncError> {
    let mut out: Vec<Json> = propfind(http, home, &calendar_props(), 1)?
        .iter()
        .filter_map(|f| calendar_info(&f.href, &f.props))
        .collect();
    let order = |c: &Json| c.get("order").and_then(Json::as_f64).unwrap_or(0.0);
    out.sort_by(|a, b| {
        order(a)
            .partial_cmp(&order(b))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    Ok(out)
}

/// The theme's colours a calendar can have, by the names colors.toml gives
/// them; the shell paints each in the theme's own.
pub const PALETTE: [&str; 8] = [
    "accent", "red", "orange", "yellow", "green", "cyan", "blue", "magenta",
];
const HUES: [(&str, f64); 7] = [
    ("red", 0.0),
    ("orange", 30.0),
    ("yellow", 55.0),
    ("green", 120.0),
    ("cyan", 180.0),
    ("blue", 220.0),
    ("magenta", 290.0),
];
/// A calendar with no colour of its own takes the first not yet taken;
/// blue last, being the accent of many themes.
const NEW_COLORS: [&str; 7] = [
    "red", "green", "orange", "magenta", "cyan", "yellow", "blue",
];

/// The palette's colour nearest a server's (#RRGGBB[AA]); for a grey, or
/// none, the first not yet <used>.
pub fn nearest_color(text: &str, used: &[Option<String>]) -> String {
    let t = text.trim();
    let hex = t.strip_prefix('#').unwrap_or(t);
    if (hex.len() == 6 || hex.len() == 8) && hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        let ch = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex") as f64 / 255.0;
        let (r, g, b) = (ch(0), ch(2), ch(4));
        let hi = r.max(g).max(b);
        let lo = r.min(g).min(b);
        if hi - lo > 0.12 {
            let hue = if hi == r {
                60.0 * ((g - b) / (hi - lo)).rem_euclid(6.0)
            } else if hi == g {
                60.0 * ((b - r) / (hi - lo) + 2.0)
            } else {
                60.0 * ((r - g) / (hi - lo) + 4.0)
            };
            let distance = |h: f64| (h - hue).abs().min(360.0 - (h - hue).abs());
            let mut best = HUES[0];
            for h in HUES {
                if distance(h.1) < distance(best.1) {
                    best = h;
                }
            }
            return best.0.to_string();
        }
    }
    for name in NEW_COLORS {
        if !used.iter().any(|u| u.as_deref() == Some(name)) {
            return name.to_string();
        }
    }
    NEW_COLORS[used.len() % NEW_COLORS.len()].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colours() {
        assert_eq!(nearest_color("#FF2968FF", &[]), "red");
        assert_eq!(nearest_color("#1BADF8", &[]), "blue");
        assert_eq!(nearest_color("#63DA38", &[]), "green");
        assert_eq!(nearest_color("#cccccc", &[Some("red".into())]), "green");
        assert_eq!(nearest_color("", &[]), "red");
        let all: Vec<Option<String>> = NEW_COLORS.iter().map(|c| Some(c.to_string())).collect();
        assert_eq!(nearest_color("", &all), "red");
    }
}
