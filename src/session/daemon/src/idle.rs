//! Keeps the screen awake while an app asks to (org.freedesktop.ScreenSaver).
//!
//! Video players, calls, games and file transfers ask the desktop to keep the
//! screen on through org.freedesktop.ScreenSaver: directly, or through the
//! desktop portal's Inhibit, which xdg-desktop-portal-gtk passes on to it. The
//! shell's idle timers only see Wayland's own idle inhibitors, so without this
//! the requests failed, and the screensaver and the lock came up in the middle
//! of a film.
//!
//! This owns that name for the session and keeps the requests that are held:
//! each until it is let go, or until the app that asked leaves the bus,
//! however it ends. While any is held, the file
//! $XDG_RUNTIME_DIR/nova/idle-inhibitors lists them, one "app<TAB>reason" a
//! line, and the shell's idle service, which watches it, counts no one away.
//! Lock locks the screen, as the interface has it.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::{Rc, Weak};

use nova_sd::poll::{poll, sooner};
use nova_sd::{Bus, Interface, Message, Slot, Value};

use crate::common::{remove, write_atomically, Context};
use crate::say;

pub const DUTY: &str = "idle-inhibitors";
pub const NAME: &str = "org.freedesktop.ScreenSaver";
const PATHS: [&str; 2] = ["/org/freedesktop/ScreenSaver", "/ScreenSaver"];

/// The file the shell's idle service watches.
pub fn listing(ctx: &Context) -> PathBuf {
    ctx.runtime.join("idle-inhibitors")
}

/// An app's words as one plain line: no tabs, newlines or control codes, at
/// most <limit> characters.
pub fn one_line(text: &str, limit: usize) -> String {
    let clean: String = text
        .chars()
        .map(|c| if printable(c) { c } else { ' ' })
        .collect();
    clean
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(limit)
        .collect()
}

/// What Python's str.isprintable() lets through, near enough: no control
/// codes, no invisible formatting (direction marks, zero widths), nothing
/// private or unassigned that would show as a box, no separators but the space.
fn printable(c: char) -> bool {
    !(c.is_control()
        || (c.is_whitespace() && c != ' ')
        || matches!(c as u32,
            0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x180E | 0x200B..=0x200F | 0x202A..=0x202E
            | 0x2060..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB | 0xE000..=0xF8FF | 0xF0000..=0x10FFFF
            | 0xE0001 | 0xE0020..=0xE007F))
}

/// The requests held now, in the order they came: cookie, sender, app, reason.
pub struct Held {
    path: PathBuf,
    requests: Vec<(u32, String, String, String)>,
    watches: HashMap<String, Slot>,
    cookie: u32,
}

impl Held {
    pub fn new(path: PathBuf) -> Held {
        Held {
            path,
            requests: Vec::new(),
            watches: HashMap::new(),
            cookie: 0,
        }
    }

    /// A new request's cookie: the next after the last, from 1 to 2^32-1 and
    /// round again, skipping those still held.
    fn next_cookie(&mut self) -> u32 {
        loop {
            self.cookie = self.cookie % 0xFFFF_FFFF + 1;
            if !self.requests.iter().any(|r| r.0 == self.cookie) {
                return self.cookie;
            }
        }
    }

    pub fn add(&mut self, sender: &str, app: &str, reason: &str) -> u32 {
        let cookie = self.next_cookie();
        let app = Some(one_line(app, 120))
            .filter(|a| !a.is_empty())
            .unwrap_or("an app".into());
        let reason = one_line(reason, 120);
        say!(DUTY, "held {cookie} for {app}: {reason}");
        self.requests.push((cookie, sender.into(), app, reason));
        self.publish();
        cookie
    }

    pub fn remove(&mut self, cookie: u32, sender: &str) {
        // Only the app that asked lets go of its own.
        let Some(at) = self
            .requests
            .iter()
            .position(|r| r.0 == cookie && r.1 == sender)
        else {
            return;
        };
        let (_, _, app, _) = self.requests.remove(at);
        say!(DUTY, "let go {cookie} by {app}");
        self.unwatch(sender);
        self.publish();
    }

    /// The app that was <sender> has left the bus: what it held goes with it.
    pub fn gone(&mut self, sender: &str) {
        let before = self.requests.len();
        self.requests.retain(|(cookie, holder, app, _)| {
            if holder == sender {
                say!(DUTY, "let go {cookie}: {app} left the bus");
            }
            holder != sender
        });
        self.unwatch(sender);
        if self.requests.len() != before {
            self.publish();
        }
    }

    fn unwatch(&mut self, sender: &str) {
        if !self.requests.iter().any(|r| r.1 == sender) {
            self.watches.remove(sender);
        }
    }

    pub fn clear(&mut self) {
        self.requests.clear();
        self.watches.clear();
        self.publish();
    }

    /// The listing, or no file while nothing is held.
    pub fn publish(&self) {
        let lines: String = self
            .lines()
            .iter()
            .map(|line| format!("{line}\n"))
            .collect();
        let written = if lines.is_empty() {
            remove(&self.path)
        } else {
            write_atomically(&self.path, &lines)
        };
        if let Err(e) = written {
            say!(DUTY, "could not write {}: {e}", self.path.display());
        }
    }

    pub fn lines(&self) -> Vec<String> {
        self.requests
            .iter()
            .map(|(_, _, app, reason)| format!("{app}\t{reason}"))
            .collect()
    }
}

fn interface() -> Interface {
    Interface::new(NAME)
        .method("Inhibit", "ss", "u")
        .method("UnInhibit", "u", "")
        .method("Lock", "", "")
        .method("GetActive", "", "b")
        .method("SetActive", "b", "b")
        .method("GetActiveTime", "", "u")
        .method("GetSessionIdleTime", "", "u")
        .method("SimulateUserActivity", "", "")
        .signal("ActiveChanged", "b")
}

/// Watches <sender> leave the bus, once per app however many it holds.
fn watch(held: &Rc<RefCell<Held>>, bus: &Bus, sender: &str) {
    if held.borrow().watches.contains_key(sender) {
        return;
    }
    let weak: Weak<RefCell<Held>> = Rc::downgrade(held);
    let who = sender.to_owned();
    match bus.watch_name(sender, move |owner| {
        if owner.is_none() {
            if let Some(held) = weak.upgrade() {
                held.borrow_mut().gone(&who);
            }
        }
    }) {
        Ok((slot, owner)) => {
            held.borrow_mut().watches.insert(sender.to_owned(), slot);
            // Gone already, before it could be watched.
            if owner.is_none() {
                held.borrow_mut().gone(sender);
            }
        }
        Err(e) => say!(DUTY, "could not watch {sender}: {e}"),
    }
}

/// Serves the name on <bus> until the bus goes.
pub fn serve(bus: &Bus, ctx: &Context) -> Result<(), String> {
    let path = listing(ctx);
    ctx.runtime_dir()
        .map_err(|e| format!("no runtime folder: {e}"))?;
    // A file left by a run that ended holds nothing any more.
    let _ = remove(&path);
    let held = Rc::new(RefCell::new(Held::new(path)));
    let mut objects = Vec::new();
    for object in PATHS {
        let held = held.clone();
        let ctx = ctx.clone();
        let handler = move |call: &Message, args: Vec<Value>| -> nova_sd::Result<Vec<Value>> {
            let sender = call.sender().unwrap_or_default().to_owned();
            Ok(match (call.member().unwrap_or_default(), args.as_slice()) {
                ("Inhibit", [app, reason]) => {
                    let app = app.as_str().unwrap_or_default();
                    let cookie =
                        held.borrow_mut()
                            .add(&sender, app, reason.as_str().unwrap_or_default());
                    watch(&held, &call.bus(), &sender);
                    vec![Value::Uint32(cookie)]
                }
                ("UnInhibit", [cookie]) => {
                    let cookie = cookie.as_u64().unwrap_or_default() as u32;
                    held.borrow_mut().remove(cookie, &sender);
                    vec![]
                }
                ("Lock", _) => {
                    ctx.spawn(&["nova-system-lock"], false);
                    vec![]
                }
                // The rest of the interface, as a screensaver that is not
                // showing: input is the shell's to see, and only the shell
                // starts the screensaver.
                ("GetActive" | "SetActive", _) => vec![Value::Bool(false)],
                ("GetActiveTime" | "GetSessionIdleTime", _) => vec![Value::Uint32(0)],
                _ => vec![],
            })
        };
        objects.push(
            bus.export(object, vec![interface()], handler)
                .map_err(|e| e.to_string())?,
        );
    }
    match bus.request_name(NAME, 0) {
        Ok(true) => {}
        Ok(false) | Err(_) => return Err(format!("{NAME} is another program's already")),
    }
    say!(DUTY, "serving {NAME}");
    let ended = loop {
        let mut fds = [bus.poll_fd()];
        if let Err(e) = poll(&mut fds, sooner(bus.timeout(), None)) {
            break format!("could not wait: {e}");
        }
        if let Err(e) = bus.dispatch() {
            break format!("the session bus went: {e}");
        }
    };
    // Ended, it holds nothing: the shell counts idle time again.
    drop(objects);
    held.borrow_mut().clear();
    Err(ended)
}

pub fn run(ctx: &Context) -> Result<(), String> {
    let bus = Bus::user().map_err(|e| e.to_string())?;
    serve(&bus, ctx)
}

/// Takes the listing away, as the daemon stops.
pub fn clean_up(ctx: &Context) {
    let _ = remove(&listing(ctx));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_apps_words_are_one_plain_line() {
        assert_eq!(one_line("Playing\tvideo\n", 120), "Playing video");
        assert_eq!(one_line("  a\u{7}b\u{200B}c  ", 120), "a b c");
        assert_eq!(one_line("\u{2028}x\u{85}y", 120), "x y");
        assert_eq!(one_line(&"é".repeat(200), 120).chars().count(), 120);
        assert_eq!(one_line("", 120), "");
    }

    #[test]
    fn cookies_go_round_and_skip_those_held() {
        let dir = nova_sd::testing::scratch("cookies");
        let mut held = Held::new(dir.join("idle-inhibitors"));
        held.cookie = 0xFFFF_FFFE;
        assert_eq!(held.add(":1.1", "a", ""), 0xFFFF_FFFF);
        assert_eq!(held.add(":1.1", "b", ""), 1);
        held.cookie = 0xFFFF_FFFE;
        assert_eq!(held.add(":1.1", "", "r"), 2);
        assert_eq!(held.lines(), vec!["a\t", "b\t", "an app\tr"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    use crate::testing::{calls, context, duty, stub, wait_until, zombies};
    use nova_sd::testing::{scratch, PrivateBus};
    use std::fs;

    const SAVER: &str = "/org/freedesktop/ScreenSaver";

    fn listed(ctx: &Context) -> String {
        fs::read_to_string(listing(ctx)).unwrap_or_default()
    }

    #[test]
    fn an_inhibit_is_listed_as_one_plain_line_until_the_app_that_asked_lets_go() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("idle");
        let ctx = context(&dir);
        // A file left by a run that ended holds nothing any more.
        fs::write(listing(&ctx), "Old\tleft over\n").unwrap();
        let _service = duty(&private.address, &ctx, serve);
        let app = Bus::connect(&private.address).unwrap();
        wait_until("the name", || app.name_owner(NAME).unwrap().is_some());
        assert_eq!(listed(&ctx), "");

        let answer = app
            .call(
                NAME,
                SAVER,
                NAME,
                "Inhibit",
                &[Value::str("Films"), Value::str("Playing\tvideo\n")],
            )
            .unwrap();
        let cookie = answer[0].clone();
        assert_eq!(listed(&ctx), "Films\tPlaying video\n");
        // Only the app that asked lets go of its own.
        let stranger = Bus::connect(&private.address).unwrap();
        stranger
            .call(
                NAME,
                "/ScreenSaver",
                NAME,
                "UnInhibit",
                std::slice::from_ref(&cookie),
            )
            .unwrap();
        assert_eq!(listed(&ctx), "Films\tPlaying video\n");
        app.call(NAME, SAVER, NAME, "UnInhibit", &[cookie]).unwrap();
        assert!(!listing(&ctx).exists());

        // The rest of the interface, as a screensaver that is not showing.
        assert_eq!(
            app.call(NAME, SAVER, NAME, "GetActive", &[]).unwrap(),
            vec![Value::Bool(false)]
        );
        assert_eq!(
            app.call(NAME, SAVER, NAME, "SetActive", &[Value::Bool(true)])
                .unwrap(),
            vec![Value::Bool(false)]
        );
        assert_eq!(
            app.call(NAME, SAVER, NAME, "GetSessionIdleTime", &[])
                .unwrap(),
            vec![Value::Uint32(0)]
        );
        let xml = app
            .call(
                NAME,
                SAVER,
                "org.freedesktop.DBus.Introspectable",
                "Introspect",
                &[],
            )
            .unwrap();
        assert!(xml[0]
            .as_str()
            .unwrap()
            .contains("<method name=\"Inhibit\">"));
    }

    #[test]
    fn an_app_that_leaves_the_bus_lets_go_of_what_it_held() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("idle");
        let ctx = context(&dir);
        let _service = duty(&private.address, &ctx, serve);
        let stays = Bus::connect(&private.address).unwrap();
        wait_until("the name", || stays.name_owner(NAME).unwrap().is_some());
        stays
            .call(
                NAME,
                SAVER,
                NAME,
                "Inhibit",
                &[Value::str("Music"), Value::str("Playing")],
            )
            .unwrap();
        let call = Bus::connect(&private.address).unwrap();
        call.call(
            NAME,
            SAVER,
            NAME,
            "Inhibit",
            &[Value::str("Call"), Value::str("")],
        )
        .unwrap();
        call.call(
            NAME,
            SAVER,
            NAME,
            "Inhibit",
            &[Value::str("Call"), Value::str("video")],
        )
        .unwrap();
        assert_eq!(listed(&ctx), "Music\tPlaying\nCall\t\nCall\tvideo\n");
        drop(call);
        wait_until("the call's to go", || listed(&ctx) == "Music\tPlaying\n");
        drop(stays);
        wait_until("the listing to go", || !listing(&ctx).exists());
    }

    #[test]
    fn lock_locks_and_leaves_no_child_behind() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("idle");
        let ctx = context(&dir);
        stub(&dir, "nova-system-lock", "exit 0");
        let _service = duty(&private.address, &ctx, serve);
        let app = Bus::connect(&private.address).unwrap();
        wait_until("the name", || app.name_owner(NAME).unwrap().is_some());
        app.call(NAME, SAVER, NAME, "Lock", &[]).unwrap();
        wait_until("the lock", || calls(&dir) == vec!["nova-system-lock"]);
        wait_until("no zombie", || zombies() == 0);
    }

    #[test]
    fn a_name_another_program_has_is_not_taken() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("idle");
        let ctx = context(&dir);
        let other = Bus::connect(&private.address).unwrap();
        assert!(other.request_name(NAME, 0).unwrap());
        let service = duty(&private.address, &ctx, serve);
        let ended = service.join().unwrap();
        assert_eq!(
            ended.unwrap_err(),
            format!("{NAME} is another program's already")
        );
    }

    #[test]
    fn the_listing_goes_with_the_bus() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("idle");
        let ctx = context(&dir);
        let service = duty(&private.address, &ctx, serve);
        let app = Bus::connect(&private.address).unwrap();
        wait_until("the name", || app.name_owner(NAME).unwrap().is_some());
        app.call(
            NAME,
            SAVER,
            NAME,
            "Inhibit",
            &[Value::str("Films"), Value::str("")],
        )
        .unwrap();
        assert!(listing(&ctx).exists());
        drop(private);
        assert!(service.join().unwrap().is_err());
        assert!(!listing(&ctx).exists());
    }
}
