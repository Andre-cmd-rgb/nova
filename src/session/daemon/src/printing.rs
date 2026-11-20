//! Printing: the job viewer while this user's jobs are queued, and the
//! notices of a printer plugged in.
//!
//! What system-config-printer's applet did, all day in 40 MB of Python:
//!
//! - It waited for CUPS's signals (com.redhat.PrinterSpooler, on the system
//!   bus) and, once a job of the user's was queued, had its job viewer
//!   started: the notices of a printer out of paper or jammed, of a document
//!   sent to a printer on the network, and the password a held job asks for.
//!   The viewer stays system-config-printer's own, started through its
//!   D-Bus service (org.fedoraproject.Config.Printing, JobApplet); but it
//!   never ends by itself (only its tray icon's Quit, and Nova has no tray,
//!   ended it), so it is asked to quit once a minute has gone by with no job
//!   of the user's left, and the Python runs only while there is printing.
//!   Whether jobs are left is lpstat's to say, asked only after CUPS has
//!   said something, so that nothing here starts CUPS: no look at login.
//! - It owned com.redhat.NewPrinterNotification, which udev-add-printer
//!   calls as it sets up a printer plugged in: "Printer added", or a driver
//!   missing. Those are Nova's notifications now, in the same words, with a
//!   button for what the applet's notice offered first: a test page, or the
//!   driver's choice in Print Settings (nova-printer-setup).
//!
//! The applet's third service, com.redhat.PrinterDriversInstaller, only
//! passed driver installs to PackageKit, which Nova does not have.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;
use std::sync::mpsc::{self, Sender};
use std::thread;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner};
use nova_sd::{Bus, Interface, Message, Value, NAME_QUEUE};

use crate::common::Context;
use crate::idle::one_line;
use crate::say;

pub const DUTY: &str = "printing";
const SPOOLER_PATH: &str = "/com/redhat/PrinterSpooler";
const SPOOLER: &str = "com.redhat.PrinterSpooler";
pub const NOTIFIER: &str = "com.redhat.NewPrinterNotification";
const NOTIFIER_PATH: &str = "/com/redhat/NewPrinterNotification";
pub const CONFIG: &str = "org.fedoraproject.Config.Printing";
pub const CONFIG_PATH: &str = "/org/fedoraproject/Config/Printing";
pub const JOB_VIEWER: &str = "org.fedoraproject.Config.Printing.JobViewer";
const GLYPH: &str = "\u{f042a}";
/// The page CUPS prints as its test page.
const TEST_PAGE: &str = "/usr/share/cups/data/testprint";

#[derive(Clone)]
pub struct Setup {
    /// After a signal of CUPS's, how long it is let settle before lpstat is asked.
    pub settle: Duration,
    /// How long no job of the user's is left before the viewer is asked to quit.
    pub grace: Duration,
    /// How often lpstat is asked while jobs are left, should a signal be missed.
    pub recheck: Duration,
    /// Whose jobs count: the user's name, as CUPS has it.
    pub user: Option<String>,
}

impl Default for Setup {
    fn default() -> Setup {
        Setup {
            settle: Duration::from_secs(2),
            grace: Duration::from_secs(60),
            recheck: Duration::from_secs(300),
            user: std::env::var("USER").ok().filter(|u| !u.is_empty()),
        }
    }
}

/// A notification, as nova-notification-send takes it.
#[derive(Debug, Clone, PartialEq)]
pub struct Notice {
    pub headline: String,
    pub text: String,
    pub urgency: &'static str,
    /// The button's words, and what a press runs.
    pub button: Option<(String, Vec<String>)>,
    pub expire_ms: Option<u32>,
}

/// While udev-add-printer works out a driver, which can take a while.
pub fn ready_notice() -> Notice {
    Notice {
        headline: "Setting up a new printer".into(),
        text: "Please wait.".into(),
        urgency: "low",
        button: None,
        // The applet's waited 20 minutes for the outcome; one that never
        // comes should not stay as long.
        expire_ms: Some(300_000),
    }
}

/// What a printer plugged in came to, from NewPrinter's arguments: <name>
/// is the queue made for it, or the device's URI when no driver fit, and
/// <status> how well the driver fits (0 exactly, 1 another model's, 2 a
/// generic one, 3 none). What the device says of itself is its own text:
/// one plain line of it.
pub fn new_printer_notice(
    status: i32,
    name: &str,
    mfg: &str,
    mdl: &str,
    des: &str,
    cmd: &str,
) -> Notice {
    let (name, mfg, mdl, des) = (
        one_line(name, 200),
        one_line(mfg, 80),
        one_line(mdl, 80),
        one_line(des, 120),
    );
    let device_id = format!("MFG:{mfg};MDL:{mdl};DES:{des};CMD:{};", one_line(cmd, 200));
    if name.contains('/') {
        let text = if !mfg.is_empty() && !mdl.is_empty() {
            format!("No printer driver for {mfg} {mdl}.")
        } else if !des.is_empty() {
            format!("No printer driver for {des}.")
        } else {
            "No driver for this printer.".into()
        };
        return Notice {
            headline: "Missing printer driver".into(),
            text,
            urgency: "critical",
            button: Some((
                "Find Driver".into(),
                vec![
                    "nova-printer-setup".into(),
                    "device".into(),
                    name,
                    device_id,
                ],
            )),
            expire_ms: None,
        };
    }
    if status == 0 {
        return Notice {
            headline: "Printer added".into(),
            text: format!("“{name}” is ready for printing."),
            urgency: "normal",
            button: Some((
                "Print Test Page".into(),
                vec!["lp".into(), "-d".into(), name, TEST_PAGE.into()],
            )),
            expire_ms: None,
        };
    }
    Notice {
        headline: if status < 2 {
            "Printer added"
        } else {
            "Missing printer driver"
        }
        .into(),
        text: format!("“{name}” was added, with a driver that may not be the right one."),
        urgency: "critical",
        button: Some((
            "Find Driver".into(),
            vec![
                "nova-printer-setup".into(),
                "driver".into(),
                name,
                device_id,
            ],
        )),
        expire_ms: None,
    }
}

/// nova-notification-send's words for <notice>, replacing notification
/// <replaces>, or printing the new one's id.
pub fn notice_argv(notice: &Notice, replaces: Option<&str>, print_id: bool) -> Vec<String> {
    let mut argv: Vec<String> = vec![
        "nova-notification-send".into(),
        "-u".into(),
        notice.urgency.into(),
        "-g".into(),
        GLYPH.into(),
    ];
    if let Some(id) = replaces {
        argv.extend(["-r".into(), id.into()]);
    }
    if print_id {
        argv.push("-p".into());
    }
    if let Some(ms) = notice.expire_ms {
        argv.extend(["-t".into(), ms.to_string()]);
    }
    if let Some((words, _)) = &notice.button {
        argv.extend(["--button".into(), words.clone()]);
    }
    argv.extend([notice.headline.clone(), notice.text.clone()]);
    if let Some((_, click)) = &notice.button {
        argv.push("--exec".into());
        argv.extend(click.iter().cloned());
    }
    argv
}

enum Say {
    /// The setting-up notice, whose id the outcome replaces.
    Ready,
    Outcome(Notice),
}

/// Sends the notices one after another on a thread of its own, so that an
/// answer to udev-add-printer never waits for one, and the outcome always
/// comes after, and in place of, the setting-up notice.
fn notifier(ctx: &Context) -> Result<Sender<Say>, String> {
    let (tell, told) = mpsc::channel::<Say>();
    let ctx = ctx.clone();
    thread::Builder::new()
        .name("printing-say".into())
        .stack_size(128 * 1024)
        .spawn(move || {
            let mut shown: Option<String> = None;
            for say in told {
                let (notice, replaces, print_id) = match say {
                    Say::Ready => (ready_notice(), shown.clone(), true),
                    Say::Outcome(notice) => (notice, shown.take(), false),
                };
                let argv = notice_argv(&notice, replaces.as_deref(), print_id);
                let mut command = ctx.command(&argv[0]);
                command.args(&argv[1..]);
                match command.output() {
                    Ok(out) if print_id => {
                        let id = String::from_utf8_lossy(&out.stdout).trim().to_owned();
                        shown = id
                            .chars()
                            .all(|c| c.is_ascii_digit())
                            .then_some(id)
                            .filter(|id| !id.is_empty());
                    }
                    Ok(_) => {}
                    Err(e) => say!(DUTY, "could not run nova-notification-send: {e}"),
                }
            }
        })
        .map_err(|e| format!("could not start the notices' thread: {e}"))?;
    Ok(tell)
}

fn notifier_interface() -> Interface {
    Interface::new(NOTIFIER)
        .method("GetReady", "", "")
        .method("NewPrinter", "isssss", "")
}

/// Whether the user has jobs CUPS has not finished, as lpstat lists them.
fn jobs_left(ctx: &Context, user: Option<&str>) -> bool {
    let mut command = ctx.command("lpstat");
    match user {
        Some(user) => command.args(["-u", user]),
        None => command.arg("-o"),
    };
    match command.output() {
        Ok(out) => out.status.success() && !out.stdout.iter().all(u8::is_ascii_whitespace),
        Err(e) => {
            say!(DUTY, "could not run lpstat: {e}");
            false
        }
    }
}

/// The job viewer, and when to look again whether it is still wanted.
struct Viewer {
    /// Its object, once JobApplet has answered.
    path: Rc<RefCell<Option<String>>>,
    running: bool,
    look_at: Option<Instant>,
    /// Since when no job of the user's has been left.
    idle_since: Option<Instant>,
}

impl Viewer {
    fn start(&mut self, session: &Bus, now: Instant, setup: &Setup) {
        let path = self.path.clone();
        // Answered with the viewer there is, when one runs.
        let asked = session.call_async(
            CONFIG,
            CONFIG_PATH,
            CONFIG,
            "JobApplet",
            &[],
            Some(Duration::from_secs(60)),
            move |answer| match answer {
                Ok(values) => {
                    *path.borrow_mut() = values.first().and_then(|v| v.as_str()).map(String::from)
                }
                Err(e) => say!(DUTY, "could not start the job viewer: {e}"),
            },
        );
        if let Err(e) = asked {
            say!(DUTY, "could not start the job viewer: {e}");
            return;
        }
        if !self.running {
            say!(DUTY, "a job is queued: the job viewer runs");
        }
        self.running = true;
        self.idle_since = None;
        self.look_at = Some(now + setup.recheck);
    }

    fn signalled(&mut self, now: Instant, setup: &Setup) {
        if self.running {
            let soon = now + setup.settle;
            self.look_at = Some(self.look_at.map_or(soon, |at| at.min(soon)));
        }
    }

    fn look(&mut self, ctx: &Context, session: &Bus, now: Instant, setup: &Setup) {
        if jobs_left(ctx, setup.user.as_deref()) {
            self.idle_since = None;
            self.look_at = Some(now + setup.recheck);
            return;
        }
        let since = *self.idle_since.get_or_insert(now);
        if now.duration_since(since) < setup.grace {
            self.look_at = Some(since + setup.grace);
            return;
        }
        self.quit(session);
    }

    fn quit(&mut self, session: &Bus) {
        self.running = false;
        self.look_at = None;
        self.idle_since = None;
        let Some(path) = self.path.borrow_mut().take() else {
            return;
        };
        say!(DUTY, "no job is left: the job viewer quits");
        let asked = session.call_async(CONFIG, &path, JOB_VIEWER, "Quit", &[], None, |answer| {
            if let Err(e) = answer {
                say!(DUTY, "the job viewer did not quit: {e}");
            }
        });
        if let Err(e) = asked {
            say!(DUTY, "the job viewer did not quit: {e}");
        }
    }
}

/// A signal of CUPS's: what it says, and whose job it is about, if a job's.
struct Spooled {
    member: String,
    user: Option<String>,
}

pub fn serve(system: &Bus, session: &Bus, ctx: &Context, setup: Setup) -> Result<(), String> {
    let tell = notifier(ctx)?;
    let handler = move |call: &Message, args: Vec<Value>| -> nova_sd::Result<Vec<Value>> {
        match (call.member().unwrap_or_default(), args.as_slice()) {
            ("GetReady", _) => {
                let _ = tell.send(Say::Ready);
            }
            ("NewPrinter", [status, name, mfg, mdl, des, cmd]) => {
                let text = |v: &Value| v.as_str().unwrap_or_default().to_owned();
                let notice = new_printer_notice(
                    status.as_i64().unwrap_or(3) as i32,
                    &text(name),
                    &text(mfg),
                    &text(mdl),
                    &text(des),
                    &text(cmd),
                );
                let _ = tell.send(Say::Outcome(notice));
            }
            _ => {}
        }
        Ok(vec![])
    };
    let _object = system
        .export(NOTIFIER_PATH, vec![notifier_interface()], handler)
        .map_err(|e| e.to_string())?;
    // Waited for while the applet of an earlier session, or another user's,
    // still has it: the system bus has one for everybody.
    match system.request_name(NOTIFIER, NAME_QUEUE) {
        Ok(true) => {}
        Ok(false) => say!(DUTY, "{NOTIFIER} is another program's: waiting for it"),
        Err(e) => return Err(format!("could not ask for {NOTIFIER}: {e}")),
    }

    let spooled: Rc<RefCell<VecDeque<Spooled>>> = Rc::default();
    let queue = spooled.clone();
    let rule = nova_sd::rule(&[
        ("type", "signal"),
        ("path", SPOOLER_PATH),
        ("interface", SPOOLER),
    ])
    .map_err(|e| e.to_string())?;
    let _spooler = system
        .add_match(&rule, move |m: &Message| {
            // JobQueuedLocal and JobStartedLocal: the printer, the job and its user.
            let user = match m.args().as_deref() {
                Ok([_, _, user, ..]) => user.as_str().map(String::from),
                _ => None,
            };
            queue.borrow_mut().push_back(Spooled {
                member: m.member().unwrap_or_default().to_owned(),
                user,
            });
        })
        .map_err(|e| e.to_string())?;

    let mut viewer = Viewer {
        path: Rc::default(),
        running: false,
        look_at: None,
        idle_since: None,
    };
    loop {
        let now = Instant::now();
        let events: Vec<Spooled> = spooled.borrow_mut().drain(..).collect();
        for event in events {
            let mine = match (&event.user, &setup.user) {
                (Some(theirs), Some(me)) => theirs == me,
                _ => true,
            };
            if event.member == "JobQueuedLocal" && mine {
                viewer.start(session, now, &setup);
            } else {
                viewer.signalled(now, &setup);
            }
        }
        if viewer.look_at.is_some_and(|at| at <= now) {
            viewer.look(ctx, session, now, &setup);
        }
        let until_look = viewer
            .look_at
            .map(|at| at.saturating_duration_since(Instant::now()));
        let mut fds = [system.poll_fd(), session.poll_fd()];
        poll(
            &mut fds,
            sooner(sooner(system.timeout(), session.timeout()), until_look),
        )
        .map_err(|e| format!("could not wait: {e}"))?;
        system
            .dispatch()
            .map_err(|e| format!("the system bus went: {e}"))?;
        session
            .dispatch()
            .map_err(|e| format!("the session bus went: {e}"))?;
    }
}

pub fn run(ctx: &Context) -> Result<(), String> {
    let system = Bus::system().map_err(|e| e.to_string())?;
    let session = Bus::user().map_err(|e| e.to_string())?;
    serve(&system, &session, ctx, Setup::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{calls, context, stub, wait_until, Service};
    use nova_sd::testing::{scratch, PrivateBus};
    use std::path::Path;
    use std::sync::{Arc, Mutex};
    use std::thread::JoinHandle;

    #[test]
    fn a_printer_set_up_is_ready_for_printing_with_a_test_page_to_print() {
        assert_eq!(
            new_printer_notice(0, "LaserJet-1020", "HP", "LaserJet 1020", "", ""),
            Notice {
                headline: "Printer added".into(),
                text: "“LaserJet-1020” is ready for printing.".into(),
                urgency: "normal",
                button: Some((
                    "Print Test Page".into(),
                    vec![
                        "lp".into(),
                        "-d".into(),
                        "LaserJet-1020".into(),
                        TEST_PAGE.into()
                    ]
                )),
                expire_ms: None,
            }
        );
    }

    #[test]
    fn a_printer_with_no_driver_is_named_as_well_as_it_names_itself() {
        let uri = "usb://Acme/Inkjet%20Z?serial=1";
        let notice = new_printer_notice(3, uri, "Acme", "Inkjet Z", "", "PCL");
        assert_eq!(notice.headline, "Missing printer driver");
        assert_eq!(notice.text, "No printer driver for Acme Inkjet Z.");
        assert_eq!(notice.urgency, "critical");
        assert_eq!(
            notice.button.unwrap().1,
            vec![
                "nova-printer-setup",
                "device",
                uri,
                "MFG:Acme;MDL:Inkjet Z;DES:;CMD:PCL;"
            ]
        );
        assert_eq!(
            new_printer_notice(3, uri, "", "", "Acme Inkjet", "").text,
            "No printer driver for Acme Inkjet."
        );
        assert_eq!(
            new_printer_notice(3, uri, "Acme", "", "", "").text,
            "No driver for this printer."
        );
    }

    #[test]
    fn a_driver_that_may_not_fit_offers_another() {
        let notice = new_printer_notice(1, "Office", "HP", "LaserJet 1022", "", "");
        assert_eq!(notice.headline, "Printer added");
        assert_eq!(
            notice.text,
            "“Office” was added, with a driver that may not be the right one."
        );
        assert_eq!(
            notice.button.unwrap().1[..3],
            ["nova-printer-setup", "driver", "Office"]
        );
        assert_eq!(
            new_printer_notice(2, "Office", "", "", "", "").headline,
            "Missing printer driver"
        );
    }

    #[test]
    fn what_a_device_says_of_itself_is_one_plain_line_of_text() {
        let notice = new_printer_notice(3, "usb://x", "Acme\n--exec", "Z\u{7}\tjet", "", "");
        assert_eq!(notice.text, "No printer driver for Acme --exec Z jet.");
        let argv = notice_argv(&notice, None, false);
        // The device's words are the text's, never options.
        let exec = argv.iter().rposition(|w| w == "--exec").unwrap();
        assert_eq!(argv[exec - 1], "No printer driver for Acme --exec Z jet.");
        assert_eq!(argv[exec - 2], "Missing printer driver");
    }

    #[test]
    fn the_notices_words_for_nova_notification_send() {
        assert_eq!(
            notice_argv(&ready_notice(), None, true),
            vec![
                "nova-notification-send",
                "-u",
                "low",
                "-g",
                GLYPH,
                "-p",
                "-t",
                "300000",
                "Setting up a new printer",
                "Please wait.",
            ]
        );
        let added = new_printer_notice(0, "Office", "", "", "", "");
        assert_eq!(
            notice_argv(&added, Some("42"), false),
            vec![
                "nova-notification-send",
                "-u",
                "normal",
                "-g",
                GLYPH,
                "-r",
                "42",
                "--button",
                "Print Test Page",
                "Printer added",
                "“Office” is ready for printing.",
                "--exec",
                "lp",
                "-d",
                "Office",
                TEST_PAGE,
            ]
        );
    }

    fn quick() -> Setup {
        Setup {
            settle: Duration::from_millis(50),
            grace: Duration::from_millis(300),
            recheck: Duration::from_secs(60),
            user: Some("andre".into()),
        }
    }

    /// The duty on its own connections to a system-like and a session-like bus.
    fn printing(
        system: &str,
        session: &str,
        ctx: &Context,
        setup: Setup,
    ) -> JoinHandle<Result<(), String>> {
        let (system, session, ctx) = (system.to_owned(), session.to_owned(), ctx.clone());
        thread::spawn(move || {
            let system = Bus::connect(&system).map_err(|e| e.to_string())?;
            let session = Bus::connect(&session).map_err(|e| e.to_string())?;
            serve(&system, &session, &ctx, setup)
        })
    }

    /// system-config-printer's service, as far as the duty uses it, with
    /// what it was asked, in order.
    fn config_printing(session: &str) -> (Service, Arc<Mutex<Vec<String>>>) {
        let asked: Arc<Mutex<Vec<String>>> = Arc::default();
        let log = asked.clone();
        let service = Service::start(session, move |bus| {
            let applet = log.clone();
            let main = bus
                .export(
                    CONFIG_PATH,
                    vec![Interface::new(CONFIG).method("JobApplet", "", "s")],
                    move |_: &Message, _: Vec<Value>| -> nova_sd::Result<Vec<Value>> {
                        applet.lock().unwrap().push("JobApplet".into());
                        Ok(vec![Value::str(format!("{CONFIG_PATH}/JobApplet/1"))])
                    },
                )
                .unwrap();
            let quit = log.clone();
            let viewer = bus
                .export(
                    &format!("{CONFIG_PATH}/JobApplet/1"),
                    vec![Interface::new(JOB_VIEWER).method("Quit", "", "")],
                    move |_: &Message, _: Vec<Value>| -> nova_sd::Result<Vec<Value>> {
                        quit.lock().unwrap().push("Quit".into());
                        Ok(vec![])
                    },
                )
                .unwrap();
            assert!(bus.request_name(CONFIG, 0).unwrap());
            Box::new((main, viewer))
        });
        (service, asked)
    }

    /// CUPS saying <member>, about a job of <user>'s when there is one.
    fn spooler(cups: &Bus, member: &str, user: Option<&str>) {
        let mut args = vec![Value::str("Office")];
        if let Some(user) = user {
            args.extend([Value::Uint32(7), Value::str(user)]);
        }
        cups.emit_signal(SPOOLER_PATH, SPOOLER, member, &args)
            .unwrap();
        cups.flush().unwrap();
    }

    fn jobs(dir: &Path, listed: &str) {
        std::fs::write(dir.join("jobs"), listed).unwrap();
    }

    #[test]
    fn the_job_viewer_runs_while_a_job_of_the_users_is_left_and_quits_a_while_after_the_last() {
        let (Some(system), Some(session)) = (PrivateBus::start(), PrivateBus::start()) else {
            return;
        };
        let dir = scratch("printing");
        let ctx = context(&dir);
        stub(
            &dir,
            "lpstat",
            &format!("cat '{}/jobs' 2>/dev/null; exit 0", dir.display()),
        );
        let (_service, asked) = config_printing(&session.address);
        let duty = printing(&system.address, &session.address, &ctx, quick());
        let cups = Bus::connect(&system.address).unwrap();
        wait_until("the duty on the bus", || {
            cups.name_owner(NOTIFIER).unwrap().is_some()
        });
        // Nothing at login, not even a look at CUPS, which would start it.
        thread::sleep(Duration::from_millis(100));
        assert!(asked.lock().unwrap().is_empty());
        assert!(calls(&dir).is_empty());

        // Another user's job is theirs.
        spooler(&cups, "JobQueuedLocal", Some("guest"));
        thread::sleep(Duration::from_millis(100));
        assert!(asked.lock().unwrap().is_empty());
        assert!(calls(&dir).is_empty());

        // The user's: the viewer, from system-config-printer's service.
        jobs(&dir, "Office-7 andre 1024 Thu 20 Nov 2026\n");
        spooler(&cups, "JobQueuedLocal", Some("andre"));
        wait_until("the viewer", || *asked.lock().unwrap() == ["JobApplet"]);
        // CUPS at work, the job still there: it stays.
        spooler(&cups, "JobStartedLocal", Some("andre"));
        wait_until("a look", || calls(&dir) == ["lpstat -u andre"]);
        thread::sleep(Duration::from_millis(400));
        assert_eq!(*asked.lock().unwrap(), ["JobApplet"]);

        // Printed: a while after, and only then, it is asked to quit.
        jobs(&dir, "");
        spooler(&cups, "QueueChanged", None);
        wait_until("the look after", || calls(&dir).len() == 2);
        assert_eq!(*asked.lock().unwrap(), ["JobApplet"]);
        wait_until("the viewer to quit", || {
            *asked.lock().unwrap() == ["JobApplet", "Quit"]
        });

        // The next job starts it again.
        jobs(&dir, "Office-8 andre 1024 Thu 20 Nov 2026\n");
        spooler(&cups, "JobQueuedLocal", Some("andre"));
        wait_until("the viewer again", || asked.lock().unwrap().len() == 3);
        assert!(!duty.is_finished());
    }

    #[test]
    fn a_printer_plugged_in_is_told_of_once_its_driver_is_found_in_place_of_the_wait() {
        let (Some(system), Some(session)) = (PrivateBus::start(), PrivateBus::start()) else {
            return;
        };
        let dir = scratch("printing");
        let ctx = context(&dir);
        stub(
            &dir,
            "nova-notification-send",
            "[[ \" $* \" != *\" -p \"* ]] || echo 42",
        );
        // The applet of an earlier session still has the name: the duty waits for it.
        let applet = Bus::connect(&system.address).unwrap();
        assert!(applet.request_name(NOTIFIER, 0).unwrap());
        let foreign = applet.unique_name().unwrap();
        let duty = printing(&system.address, &session.address, &ctx, quick());
        let udev = Bus::connect(&system.address).unwrap();
        thread::sleep(Duration::from_millis(100));
        assert!(!duty.is_finished());
        drop(applet);
        wait_until("the name", || {
            udev.name_owner(NOTIFIER)
                .unwrap()
                .is_some_and(|owner| owner != foreign)
        });

        // As udev-add-printer does.
        udev.call(NOTIFIER, NOTIFIER_PATH, NOTIFIER, "GetReady", &[])
            .unwrap();
        udev.call(
            NOTIFIER,
            NOTIFIER_PATH,
            NOTIFIER,
            "NewPrinter",
            &[
                Value::Int32(0),
                Value::str("LaserJet-1020"),
                Value::str("HP"),
                Value::str("LaserJet 1020"),
                Value::str(""),
                Value::str("ZJS"),
            ],
        )
        .unwrap();
        wait_until("both notices", || calls(&dir).len() == 2);
        assert_eq!(
            calls(&dir),
            vec![
                format!("nova-notification-send -u low -g {GLYPH} -p -t 300000 Setting up a new printer Please wait."),
                format!(
                    "nova-notification-send -u normal -g {GLYPH} -r 42 --button Print Test Page Printer added “LaserJet-1020” is ready for printing. --exec lp -d LaserJet-1020 {TEST_PAGE}"
                ),
            ]
        );

        // No driver, and no wait before it: a notice of its own.
        udev.call(
            NOTIFIER,
            NOTIFIER_PATH,
            NOTIFIER,
            "NewPrinter",
            &[
                Value::Int32(3),
                Value::str("usb://Acme/Z"),
                Value::str("Acme"),
                Value::str("Z"),
                Value::str(""),
                Value::str(""),
            ],
        )
        .unwrap();
        wait_until("the third notice", || calls(&dir).len() == 3);
        assert_eq!(
            calls(&dir)[2],
            format!(
                "nova-notification-send -u critical -g {GLYPH} --button Find Driver Missing printer driver No printer driver for Acme Z. --exec nova-printer-setup device usb://Acme/Z MFG:Acme;MDL:Z;DES:;CMD:;"
            )
        );
        assert!(!duty.is_finished());
    }
}
