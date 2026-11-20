//! Google: OAuth 2.0 for an installed app (RFC 8252), the browser coming
//! back to this computer, with PKCE (RFC 7636); and the bearer token,
//! renewed when it runs out or is refused, kept in the keyring.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::digest::{b64url, random, sha256, unb64url};
use crate::http::Http;
use crate::json::{self, Json};
use crate::store::{read_file, secret_store};
use crate::{now, settings, url, SyncError};

const SCOPE: &str = "openid email https://www.googleapis.com/auth/calendar";

/// The OAuth client Google sign-in uses: the user's own, else Nova's.
pub fn client() -> Option<Json> {
    let s = settings();
    for path in [
        s.config_home.join("nova/calendar-google.json"),
        s.nova_path.join("calendar/google.json"),
    ] {
        let Some(c) = read_file(&path)
            .ok()
            .flatten()
            .and_then(|t| json::parse(&t))
        else {
            continue;
        };
        if c.is_object() && c.is("client_id") {
            return Some(c);
        }
    }
    None
}

fn form_post(address: &str, fields: &[(&str, &str)]) -> Result<(u16, Json), SyncError> {
    let mut http = Http::new(None, address);
    let resp = http.request(
        "POST",
        address,
        Some(&url::encode(fields)),
        &[
            ("Content-Type", "application/x-www-form-urlencoded"),
            ("Accept", "application/json"),
        ],
    )?;
    let body = resp.text();
    let answer = json::parse(if body.is_empty() { "{}" } else { &body })
        .filter(Json::is_object)
        .unwrap_or_else(Json::object);
    Ok((resp.status, answer))
}

/// expires_in, as a number or a string; an hour where it is neither.
fn seconds(v: Option<&Json>) -> i64 {
    match v {
        Some(Json::Int(n)) => *n,
        Some(Json::Float(f)) => *f as i64,
        Some(Json::Str(s)) => s.trim().parse().unwrap_or(3600),
        _ => 3600,
    }
}

pub struct GoogleAuth {
    /// The keyring's key for the tokens; none while signing in.
    key: Option<String>,
    pub tokens: Json,
    client: Json,
}

impl GoogleAuth {
    pub fn new(key: Option<String>, tokens: Json, client: Json) -> GoogleAuth {
        GoogleAuth {
            key,
            tokens,
            client,
        }
    }

    pub fn header(&mut self) -> Result<String, SyncError> {
        let expires = self
            .tokens
            .get("expires")
            .and_then(Json::as_f64)
            .unwrap_or(0.0);
        if !self.tokens.is("access_token") || expires < now() + 60.0 {
            self.refresh()?;
        }
        Ok(format!("Bearer {}", self.tokens.text("access_token")))
    }

    pub fn refresh(&mut self) -> Result<bool, SyncError> {
        let refresh = self.tokens.text("refresh_token").to_string();
        let client_id = self.client.text("client_id").to_string();
        let secret = self.client.text("client_secret").to_string();
        let mut fields = vec![
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh.as_str()),
            ("client_id", client_id.as_str()),
        ];
        if !secret.is_empty() {
            fields.push(("client_secret", secret.as_str()));
        }
        let (status, answer) = form_post(&settings().google_token, &fields)?;
        if status != 200 || !answer.is("access_token") {
            if matches!(
                answer.text("error"),
                "invalid_grant" | "unauthorized_client" | "invalid_client"
            ) {
                return Err(SyncError::signin("Google asks to sign in again."));
            }
            return Err(SyncError::error("Google did not give a new token."));
        }
        self.tokens
            .set("access_token", Json::str(answer.text("access_token")));
        self.tokens.set(
            "expires",
            Json::Float(now() + seconds(answer.get("expires_in")) as f64),
        );
        if let Some(key) = &self.key {
            secret_store(key, "Calendar: Google", &json::dumps(&self.tokens))?;
        }
        Ok(true)
    }
}

extern "C" {
    fn setsid() -> i32;
}

const PAGE_DONE: &str = "Signed in. You can close this tab and go back to the Calendar.";
const PAGE_CANCELED: &str = "Google sign-in was canceled. You can close this tab.";

/// Signs in in the browser: the tokens, and the account's address.
pub fn sign_in(client: &Json) -> Result<(Json, String), SyncError> {
    let s = settings();
    let verifier = b64url(&random(48));
    let state = b64url(&random(24));
    let server = TcpListener::bind("127.0.0.1:0")
        .map_err(|_| SyncError::error("The browser could not be opened."))?;
    let port = server.local_addr().map(|a| a.port()).unwrap_or(0);
    let redirect = format!("http://127.0.0.1:{port}");
    let challenge = b64url(&sha256(verifier.as_bytes()));
    let address = format!(
        "{}?{}",
        s.google_auth,
        url::encode(&[
            ("client_id", client.text("client_id")),
            ("redirect_uri", &redirect),
            ("response_type", "code"),
            ("scope", SCOPE),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", &state),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ])
    );
    let browser = std::env::var("NOVA_CALENDAR_BROWSER")
        .ok()
        .filter(|b| !b.is_empty())
        .unwrap_or_else(|| "xdg-open".into());
    let mut command = Command::new(browser);
    command
        .arg(&address)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: setsid is async-signal-safe, the one call between fork and exec.
    unsafe {
        command.pre_exec(|| {
            setsid();
            Ok(())
        });
    }
    command
        .spawn()
        .map_err(|_| SyncError::error("The browser could not be opened."))?;
    server.set_nonblocking(true).ok();
    let deadline = Instant::now() + s.sign_in_time;
    let code = loop {
        let (mut conn, _) = match server.accept() {
            Ok(c) => c,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    return Err(SyncError::error("Google sign-in took too long."));
                }
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
            Err(_) => continue,
        };
        let _ = conn.set_nonblocking(false);
        let _ = conn.set_read_timeout(Some(Duration::from_secs(10)));
        let mut buf = [0u8; 8192];
        let Ok(n) = conn.read(&mut buf) else {
            continue;
        };
        let request: String = buf[..n].iter().map(|b| *b as char).collect();
        let target = if request.matches(' ').count() >= 2 {
            request.split(' ').nth(1).unwrap_or("/")
        } else {
            "/"
        };
        let query = url::parse_query(&url::split(target).map(|u| u.query).unwrap_or_default());
        let first = |k: &str| query.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        if first("state").unwrap_or_default() != state {
            let _ = conn.write_all(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
            continue;
        }
        let failed = first("error").is_some() || first("code").is_none();
        let words = if failed { PAGE_CANCELED } else { PAGE_DONE };
        let page = format!(
            "<!doctype html><meta charset=utf-8><title>Calendar</title><body style='font:16px sans-serif;margin:4em;text-align:center'>{words}</body>"
        );
        let _ = conn.write_all(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}",
                page.len()
            )
            .as_bytes(),
        );
        if failed {
            return Err(SyncError::signin("Google sign-in was canceled."));
        }
        break first("code").expect("checked");
    };
    drop(server);
    let secret = client.text("client_secret").to_string();
    let mut fields = vec![
        ("grant_type", "authorization_code"),
        ("code", code.as_str()),
        ("client_id", client.text("client_id")),
        ("code_verifier", verifier.as_str()),
        ("redirect_uri", redirect.as_str()),
    ];
    if !secret.is_empty() {
        fields.push(("client_secret", secret.as_str()));
    }
    let (status, answer) = form_post(&s.google_token, &fields)?;
    if status != 200 || !answer.is("refresh_token") {
        return Err(SyncError::signin("Google did not let the Calendar in."));
    }
    let email = answer
        .text("id_token")
        .split('.')
        .nth(1)
        .and_then(unb64url)
        .and_then(|b| String::from_utf8(b).ok())
        .and_then(|t| json::parse(&t))
        .map(|claims| claims.text("email").to_string())
        .unwrap_or_default();
    let mut tokens = Json::object();
    tokens.set("refresh_token", Json::str(answer.text("refresh_token")));
    tokens.set("access_token", Json::str(answer.text("access_token")));
    tokens.set(
        "expires",
        Json::Float(now() + seconds(answer.get("expires_in")) as f64),
    );
    Ok((tokens, email))
}
