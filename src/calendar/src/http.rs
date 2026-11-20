//! Requests to one server, its connections kept open, its redirects followed
//! for any method, for the sync's time limit at most. The password goes
//! only to that server, and only over TLS or to this computer: an address on
//! another server is refused, and so is a redirect to one but for a GET,
//! which is followed without the password.

use std::time::{Duration, Instant};

use crate::curl::{self, Easy};
use crate::google::GoogleAuth;
use crate::{settings, url, SyncError};

const MAX_BYTES: usize = 64 * 1024 * 1024;

pub enum Auth {
    Basic(String),
    Google(GoogleAuth),
}

impl Auth {
    pub fn basic(user: &str, password: &str) -> Auth {
        Auth::Basic(format!(
            "Basic {}",
            crate::digest::base64(format!("{user}:{password}").as_bytes())
        ))
    }

    fn header(&mut self) -> Result<Option<String>, SyncError> {
        match self {
            Auth::Basic(v) => Ok(Some(v.clone())),
            Auth::Google(g) => g.header().map(Some),
        }
    }

    fn refresh(&mut self) -> Result<bool, SyncError> {
        match self {
            Auth::Basic(_) => Ok(false),
            Auth::Google(g) => g.refresh(),
        }
    }
}

pub fn loopback(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "::1") || host.starts_with("127.")
}

fn not_an_address() -> SyncError {
    SyncError::error("That is not a web address.")
}

/// Scheme, host and port, the port the scheme's own where none is given.
pub fn origin(address: &str) -> Result<(String, Option<String>, u16), SyncError> {
    let u = url::split(address).ok_or_else(not_an_address)?;
    let port = u.port().map_err(|_| not_an_address())?;
    let default = if u.scheme == "https" { 443 } else { 80 };
    Ok((
        u.scheme.clone(),
        u.hostname(),
        port.filter(|p| *p != 0).unwrap_or(default),
    ))
}

pub fn host_of(address: &str) -> String {
    match origin(address) {
        Ok((scheme, host, port)) => {
            let host = host.unwrap_or_default();
            if port == if scheme == "https" { 443 } else { 80 } {
                host
            } else {
                format!("{host}:{port}")
            }
        }
        Err(_) => address.to_string(),
    }
}

/// iCloud's CalDAV host, or one of the partitions accounts are on
/// (pNN-caldav.icloud.com).
fn icloud_host(host: &str) -> bool {
    let rest = match host.strip_prefix('p') {
        Some(r) => match r.find('-') {
            Some(i) if i > 0 && r[..i].bytes().all(|b| b.is_ascii_digit()) => &r[i + 1..],
            _ => host,
        },
        None => host,
    };
    rest == "caldav.icloud.com"
}

/// Whether what goes to the server at <a> may go to <b>: the same scheme,
/// host and port; the same host over TLS where <a> is plain HTTP; or two of
/// iCloud's CalDAV hosts, over TLS.
pub fn same_server(a: &str, b: &str) -> Result<bool, SyncError> {
    let (a, b) = (origin(a)?, origin(b)?);
    if a == b || (a.1 == b.1 && a.0 == "http" && a.2 == 80 && b.0 == "https" && b.2 == 443) {
        return Ok(true);
    }
    Ok(a.0 == "https"
        && b.0 == "https"
        && a.2 == 443
        && b.2 == 443
        && [&a, &b]
            .iter()
            .all(|o| icloud_host(o.1.as_deref().unwrap_or(""))))
}

fn elsewhere(address: &str) -> SyncError {
    SyncError::error(format!(
        "The server sent the Calendar to another server, {}.",
        host_of(address)
    ))
}

pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub url: String,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        let name = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| *k == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

pub struct Http {
    pub auth: Option<Auth>,
    origin: String,
    deadline: Instant,
    easy: Option<Easy>,
}

impl Http {
    pub fn new(auth: Option<Auth>, origin: &str) -> Http {
        Http {
            auth,
            origin: origin.to_string(),
            deadline: Instant::now() + settings().sync_time,
            easy: None,
        }
    }

    fn too_long() -> SyncError {
        SyncError::error("The server took too long to answer.")
    }

    pub fn request(
        &mut self,
        method: &str,
        address: &str,
        body: Option<&str>,
        headers: &[(&str, &str)],
    ) -> Result<Response, SyncError> {
        if !same_server(&self.origin, address)? {
            return Err(elsewhere(address));
        }
        let mut method = method.to_string();
        let mut body = body.map(|b| b.as_bytes().to_vec());
        let mut address = address.to_string();
        let mut refreshed = false;
        let mut retried = false;
        for _ in 0..8 {
            let u = url::split(&address).ok_or_else(not_an_address)?;
            let Some(host) = u
                .hostname()
                .filter(|_| u.scheme == "http" || u.scheme == "https")
            else {
                return Err(not_an_address());
            };
            let port = u.port().map_err(|_| not_an_address())?;
            let own = same_server(&self.origin, &address)?;
            let mut h: Vec<(String, String)> =
                vec![("User-Agent".into(), "Nova-Calendar/1".into())];
            for (k, v) in headers {
                set_header(&mut h, k, v);
            }
            if own && (u.scheme == "https" || loopback(&host)) {
                if let Some(auth) = self.auth.as_mut() {
                    if let Some(value) = auth.header()?.filter(|v| !v.is_empty()) {
                        set_header(&mut h, "Authorization", &value);
                    }
                }
            }
            let host_part = if host.contains(':') {
                format!("[{host}]")
            } else {
                host.clone()
            };
            let target = format!(
                "{}://{}{}{}{}",
                u.scheme,
                host_part,
                port.map(|p| format!(":{p}")).unwrap_or_default(),
                if u.path.is_empty() { "/" } else { &u.path },
                if u.query.is_empty() {
                    String::new()
                } else {
                    format!("?{}", u.query)
                }
            );
            let now = Instant::now();
            if now > self.deadline {
                return Err(Http::too_long());
            }
            if self.easy.is_none() {
                self.easy = Some(
                    Easy::new()
                        .ok_or_else(|| SyncError::offline("The server could not be reached."))?,
                );
            }
            let easy = self.easy.as_mut().expect("made above");
            let answer = easy.perform(
                &method,
                &target,
                &h,
                body.as_deref(),
                self.deadline - now,
                settings().timeout,
                MAX_BYTES,
            );
            let answer = match answer {
                Ok(a) => a,
                Err(failed) => {
                    // A connection that went: a new one, once.
                    self.easy = None;
                    if failed.too_big {
                        return Err(SyncError::error("The server sent too much."));
                    }
                    if failed.code == curl::E_OPERATION_TIMEDOUT
                        && Instant::now() + Duration::from_millis(50) >= self.deadline
                    {
                        return Err(Http::too_long());
                    }
                    if !retried
                        && matches!(
                            failed.code,
                            curl::E_GOT_NOTHING | curl::E_SEND_ERROR | curl::E_RECV_ERROR
                        )
                    {
                        retried = true;
                        continue;
                    }
                    if failed.code == curl::E_PEER_FAILED_VERIFICATION {
                        return Err(SyncError::error("The server's certificate is not trusted."));
                    }
                    return Err(SyncError::offline("The server could not be reached."));
                }
            };
            let location = answer
                .headers
                .iter()
                .find(|(k, _)| k == "location")
                .map(|(_, v)| v.clone())
                .filter(|v| !v.is_empty());
            if let (301 | 302 | 303 | 307 | 308, Some(location)) = (answer.status, location) {
                address = url::join(&address, &location);
                if answer.status == 303 {
                    method = "GET".into();
                    body = None;
                }
                if body.is_some() && !same_server(&self.origin, &address)? {
                    return Err(elsewhere(&address));
                }
                continue;
            }
            if answer.status == 401 && self.auth.is_some() && !own {
                return Err(elsewhere(&address));
            }
            if answer.status == 401 && !refreshed {
                if let Some(auth) = self.auth.as_mut() {
                    if auth.refresh()? {
                        refreshed = true;
                        continue;
                    }
                }
            }
            return Ok(Response {
                status: answer.status,
                headers: answer.headers,
                body: answer.body,
                url: address,
            });
        }
        Err(SyncError::error(
            "The server sent the request round in circles.",
        ))
    }
}

/// A header set, in place of one of the same name in any case.
fn set_header(h: &mut Vec<(String, String)>, name: &str, value: &str) {
    match h.iter_mut().find(|(k, _)| k.eq_ignore_ascii_case(name)) {
        Some((_, v)) => *v = value.to_string(),
        None => h.push((name.to_string(), value.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn servers_that_may_have_the_password() {
        let ok = |a: &str, b: &str| same_server(a, b).unwrap();
        assert!(ok(
            "https://cal.example.com/",
            "https://cal.example.com:443/x"
        ));
        assert!(ok("http://cal.example.com/", "https://cal.example.com/x"));
        assert!(!ok("https://cal.example.com/", "http://cal.example.com/x"));
        assert!(!ok(
            "https://cal.example.com/",
            "https://evil.example.com/x"
        ));
        assert!(ok(
            "https://caldav.icloud.com/",
            "https://p42-caldav.icloud.com/1/calendars/"
        ));
        assert!(!ok(
            "https://caldav.icloud.com/",
            "https://p42-caldav.icloud.com.evil/"
        ));
        assert!(!ok(
            "https://caldav.icloud.com/",
            "https://px-caldav.icloud.com/"
        ));
        assert!(same_server("https://a/", "https://a:x/").is_err());
        assert_eq!(host_of("http://127.0.0.1:5232/x"), "127.0.0.1:5232");
        assert_eq!(host_of("https://Cal.Example.com/x"), "cal.example.com");
    }
}
