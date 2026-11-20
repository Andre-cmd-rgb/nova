//! The scope an app runs in: its name, and asking systemd for it.

use std::cell::RefCell;
use std::io::Read;
use std::rc::Rc;
use std::time::{Duration, Instant};

use nova_sd::{Bus, Value};

const SYSTEMD: &str = "org.freedesktop.systemd1";
const SYSTEMD_PATH: &str = "/org/freedesktop/systemd1";
const MANAGER: &str = "org.freedesktop.systemd1.Manager";

/// How long to wait for systemd in all: the call and then its job. A launch
/// comes from a key press, so one held up by a user manager that does not
/// answer starts the app without a scope after this, rather than not at all.
const PATIENCE: Duration = Duration::from_secs(3);

/// The slice of every app a person starts.
const SLICE: &str = "app-graphical.slice";

/// The length of a unit name, at most.
const NAME_MAX: usize = 255;

/// <text> as systemd's escaping makes it for a unit name: "/" is "-", letters,
/// digits and ":", "_" and "." stay, and every other byte of the text is
/// "\xNN".
pub fn escape(text: &str) -> String {
    let mut out = String::new();
    for ch in text.chars() {
        match ch {
            '/' => out.push('-'),
            '.' | '_' | ':' | '0'..='9' | 'A'..='Z' | 'a'..='z' => out.push(ch),
            _ => {
                let mut bytes = [0; 4];
                for byte in ch.encode_utf8(&mut bytes).bytes() {
                    out.push_str(&format!("\\x{byte:02x}"));
                }
            }
        }
    }
    out
}

/// <text> (escaped) cut to end before column <room>, <used> being taken
/// already, and never in the middle of an "\xNN".
fn cut(text: &str, mut used: usize, room: usize) -> String {
    let mut fragments: Vec<&str> = Vec::new();
    let mut start = 0;
    let mut at = 0;
    while at < text.len() {
        if text[at..].starts_with("\\x") && at + 4 <= text.len() {
            if start < at {
                fragments.push(&text[start..at]);
            }
            fragments.push(&text[at..at + 4]);
            at += 4;
            start = at;
        } else {
            at += 1;
        }
    }
    if start < text.len() {
        fragments.push(&text[start..]);
    }
    let mut out = String::new();
    for fragment in fragments {
        if fragment.len() + used < room {
            out.push_str(fragment);
            used += fragment.len();
        } else {
            if !fragment.starts_with("\\x") {
                out.push_str(&fragment[..room.saturating_sub(used).min(fragment.len())]);
            }
            break;
        }
    }
    out
}

/// A scope's name: app-<desktop>-<app>-<8 hex>.scope, from the first of the
/// desktops in XDG_CURRENT_DESKTOP and the app's own name, cut to fit the 255
/// characters a unit name has.
pub fn scope_name(desktop: &str, app: &str, random: &str) -> String {
    let first = desktop.split(':').find(|d| !d.is_empty()).unwrap_or("nova");
    let mut desktop = escape(first);
    let mut app = escape(app);
    // "app---DEADBEEF." and "scope".
    let fixed = 15 + 5;
    if fixed + desktop.len() > 127 {
        desktop = cut(&desktop, fixed, 127);
    }
    if fixed + desktop.len() + app.len() > NAME_MAX {
        app = cut(&app, fixed + desktop.len(), NAME_MAX);
    }
    format!("app-{desktop}-{app}-{random}.scope")
}

/// Eight hex digits, from the system's random numbers.
pub fn random_hex() -> String {
    let mut bytes = [0u8; 4];
    let read = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes));
    if read.is_err() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        bytes = (now ^ std::process::id().rotate_left(16)).to_le_bytes();
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// What the scope is for: its name, what to call it, and the entry it came from.
pub struct Scope {
    pub name: String,
    pub description: String,
    pub source_path: Option<String>,
}

fn property(name: &str, value: Value) -> Value {
    Value::Struct(vec![Value::str(name), Value::variant(value)])
}

/// Puts this process in a new scope, as `systemd-run --scope` does: the unit
/// is made with this process as its member, in the app slice, and a launch
/// goes on once systemd has finished starting it. The error says why it did
/// not work.
pub fn enter(scope: &Scope) -> Result<(), String> {
    let deadline = Instant::now() + PATIENCE;
    let bus = Bus::user().map_err(|e| format!("could not reach the session bus: {e}"))?;
    enter_on(&bus, scope, deadline)
}

fn enter_on(bus: &Bus, scope: &Scope, deadline: Instant) -> Result<(), String> {
    // Before the call, so that a job that ends at once is not missed.
    let removed: Rc<RefCell<Vec<(String, String)>>> = Rc::default();
    let seen = removed.clone();
    let _slot = bus
        .match_signal(
            None,
            Some(SYSTEMD_PATH),
            Some(MANAGER),
            Some("JobRemoved"),
            move |signal| {
                if let Ok(args) = signal.args() {
                    if let (Some(Value::Path(job)), Some(Value::Str(result))) =
                        (args.get(1), args.get(3))
                    {
                        seen.borrow_mut().push((job.clone(), result.clone()));
                    }
                }
            },
        )
        .map_err(|e| format!("could not listen to systemd: {e}"))?;

    let mut properties = vec![
        property("Description", Value::str(&scope.description)),
        property("Slice", Value::str(SLICE)),
        property("CollectMode", Value::str("inactive-or-failed")),
        property(
            "PIDs",
            Value::Array("u".into(), vec![Value::Uint32(std::process::id())]),
        ),
    ];
    if let Some(path) = &scope.source_path {
        properties.push(property("SourcePath", Value::str(path)));
    }
    let reply = bus
        .call_timeout(
            SYSTEMD,
            SYSTEMD_PATH,
            MANAGER,
            "StartTransientUnit",
            &[
                Value::str(&scope.name),
                Value::str("fail"),
                Value::Array("(sv)".into(), properties),
                Value::Array("(sa(sv))".into(), vec![]),
            ],
            Some(
                deadline
                    .saturating_duration_since(Instant::now())
                    .max(Duration::from_millis(1)),
            ),
        )
        .map_err(|e| format!("systemd would not start {}: {e}", scope.name))?;
    let Some(Value::Path(job)) = reply.first() else {
        return Err(format!("systemd gave no job for {}", scope.name));
    };

    loop {
        bus.dispatch()
            .map_err(|e| format!("lost the session bus: {e}"))?;
        if let Some((_, result)) = removed.borrow().iter().find(|(path, _)| path == job) {
            return if result == "done" {
                Ok(())
            } else {
                Err(format!(
                    "systemd ended the job of {} as {result}",
                    scope.name
                ))
            };
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(format!("systemd did not finish starting {}", scope.name));
        }
        bus.wait(Some(left))
            .map_err(|e| format!("lost the session bus: {e}"))?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escaping_follows_systemd() {
        assert_eq!(escape("org.gnome.Nautilus"), "org.gnome.Nautilus");
        assert_eq!(escape("a/b c"), "a-b\\x20c");
        assert_eq!(escape("\u{e9}"), "\\xc3\\xa9");
    }

    #[test]
    fn a_scope_is_named_by_desktop_and_app() {
        assert_eq!(
            scope_name("Hyprland:Nova", "firefox", "0123abcd"),
            "app-Hyprland-firefox-0123abcd.scope"
        );
        assert_eq!(scope_name("", "x", "00000000"), "app-nova-x-00000000.scope");
    }

    #[test]
    fn a_long_name_is_cut_to_fit_and_not_inside_an_escape() {
        let name = scope_name("Hyprland", &"a".repeat(400), "deadbeef");
        assert_eq!(name.len(), 255);
        assert!(name.ends_with("-deadbeef.scope"));
        let spaced = " ".repeat(100);
        let name = scope_name("Hyprland", &spaced, "deadbeef");
        assert!(name.len() <= 255);
        let body = name.strip_suffix("-deadbeef.scope").unwrap();
        assert!(body.ends_with("\\x20"));
        let long_desktop = scope_name(&"d".repeat(300), "x", "deadbeef");
        assert!(long_desktop.len() <= 255);
        assert!(long_desktop.ends_with("-x-deadbeef.scope"));
    }

    #[test]
    fn random_digits_are_eight_hex() {
        let a = random_hex();
        assert_eq!(a.len(), 8);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
