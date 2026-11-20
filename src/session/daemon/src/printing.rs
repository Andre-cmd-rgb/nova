//! Printing: what a printer asks of the user while their documents wait for it.
//!
//! This was system-config-printer's applet, all day in 40 MB of Python: it
//! waited for CUPS to say a job was queued and then showed a job viewer, whose
//! notices were a printer out of paper or jammed and a held job's password.
//! Nova's own Settings has a Printers page now, and what is left of the
//! applet is this:
//!
//! - It waits for CUPS's signals (com.redhat.PrinterSpooler, on the system
//!   bus). CUPS sends them to whoever has asked for them, and nobody does
//!   now that the applet is gone, so `nova-printers subscribe` asks, for a
//!   day at a time (every six hours here, and whenever systemd says it
//!   started cups.service): it does nothing while CUPS is not running, so
//!   that nothing here starts CUPS, no look at login.
//! - Once a job of this user's is queued, it asks `nova-printers watch` every
//!   few seconds how the printers holding their jobs are. It stops when no job
//!   of theirs is left.
//! - What the user must do something about is said in a notification, once for
//!   as long as it lasts, with a button that opens Settings' Printers page at
//!   that printer: no paper, a paper jam, a cover open, no toner or ink, a
//!   printer that cannot be reached or has stopped, and a held job that asks
//!   for a user name and password. A printer low on paper or ink, or paused
//!   by the user, is on the page and not said.
//!
//! The applet also owned com.redhat.NewPrinterNotification, which its udev
//! rules called as a printer was plugged in. Nothing calls it without them:
//! a modern USB printer is driverless through ipp-usb and CUPS sees it like a
//! printer on the network, and an older one is added on the Printers page.

use std::cell::RefCell;
use std::collections::{HashSet, VecDeque};
use std::rc::Rc;
use std::sync::mpsc::{self, Sender};
use std::thread;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner};
use nova_sd::{Bus, Message};

use crate::common::Context;
use crate::idle::one_line;
use crate::say;

pub const DUTY: &str = "printing";
const SPOOLER_PATH: &str = "/com/redhat/PrinterSpooler";
const SPOOLER: &str = "com.redhat.PrinterSpooler";
const SYSTEMD: &str = "org.freedesktop.systemd1";
const SYSTEMD_PATH: &str = "/org/freedesktop/systemd1";
const MANAGER: &str = "org.freedesktop.systemd1.Manager";
const GLYPH: &str = "\u{f042a}";

#[derive(Clone)]
pub struct Setup {
    /// After a signal of CUPS's, how long it is let settle before the printers are asked.
    pub settle: Duration,
    /// How often the printers are asked while jobs are left.
    pub watch: Duration,
    /// How often the subscription to CUPS's signals is renewed.
    pub renew: Duration,
    /// Whose jobs count: the user's name, as CUPS has it.
    pub user: Option<String>,
}

impl Default for Setup {
    fn default() -> Setup {
        Setup {
            settle: Duration::from_secs(2),
            watch: Duration::from_secs(5),
            renew: Duration::from_secs(6 * 3600),
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

/// A printer, as `nova-printers watch` says it.
#[derive(Debug, Clone, PartialEq)]
pub struct Printer {
    pub name: String,
    /// IPP's printer-state: 3 idle, 4 printing, 5 stopped.
    pub state: i32,
    pub reasons: Vec<String>,
}

/// A job of the user's, as `nova-printers watch` says it.
#[derive(Debug, Clone, PartialEq)]
pub struct Job {
    pub printer: String,
    pub id: String,
    pub reasons: Vec<String>,
    pub name: String,
}

#[derive(Debug, Default, PartialEq)]
pub struct Watched {
    pub printers: Vec<Printer>,
    pub jobs: Vec<Job>,
}

/// What `nova-printers watch` printed: a tab-separated line for each printer
/// the user has jobs on (`printer name state reasons accepting`) and for each
/// of their jobs (`job printer id state reasons name`). Anything else is
/// passed over.
pub fn parse_watch(text: &str) -> Watched {
    let mut watched = Watched::default();
    let reasons = |field: &str| -> Vec<String> {
        field
            .split(',')
            .filter(|r| !r.is_empty())
            .map(String::from)
            .collect()
    };
    for line in text.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        match fields.as_slice() {
            ["printer", name, state, why, ..] => watched.printers.push(Printer {
                name: (*name).into(),
                state: state.parse().unwrap_or(3),
                reasons: reasons(why),
            }),
            ["job", printer, id, _state, why, name] => watched.jobs.push(Job {
                printer: (*printer).into(),
                id: (*id).into(),
                reasons: reasons(why),
                name: (*name).into(),
            }),
            _ => {}
        }
    }
    watched
}

/// IPP's printer-state-reasons keywords end in -error, -warning or -report to
/// say how bad: the keyword is what counts here.
fn keyword(reason: &str) -> &str {
    ["-error", "-warning", "-report"]
        .iter()
        .find_map(|suffix| reason.strip_suffix(suffix))
        .unwrap_or(reason)
}

fn has(reasons: &[String], words: &[&str]) -> bool {
    reasons.iter().any(|r| words.contains(&keyword(r)))
}

/// A string as JSON has it, quotes round it.
fn json_string(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The button of every notice: Settings' Printers page, at <printer>, and at
/// <job> when it is about one.
fn open_printers(printer: &str, job: Option<&str>) -> (String, Vec<String>) {
    let mut payload = format!(
        "{{\"page\":\"printers\",\"printer\":{}",
        json_string(printer)
    );
    if let Some(job) = job {
        payload.push_str(&format!(",\"job\":{}", json_string(job)));
    }
    payload.push('}');
    (
        "Open Printers".into(),
        vec![
            "nova-shell".into(),
            "shell".into(),
            "summon".into(),
            "nova.settings".into(),
            payload,
        ],
    )
}

fn notice(headline: &str, text: String, button: (String, Vec<String>)) -> Notice {
    Notice {
        headline: headline.into(),
        text,
        urgency: "normal",
        button: Some(button),
        expire_ms: None,
    }
}

/// A problem the user has to do something about, and the notification for
/// it. <key> says which problem of which printer (or job) it is.
#[derive(Debug, PartialEq)]
pub struct Problem {
    pub key: String,
    pub notice: Notice,
}

/// What is wrong with the printers and the jobs: one problem a kind, for each
/// printer, in plain words. A name or a document's name comes from a device or
/// an app: one plain line of it.
pub fn problems(watched: &Watched) -> Vec<Problem> {
    let mut found = Vec::new();
    for printer in &watched.printers {
        let name = one_line(&printer.name, 80);
        let button = open_printers(&printer.name, None);
        let r = &printer.reasons;
        let mut say = |kind: &str, headline: &str, text: String| {
            found.push(Problem {
                key: format!("{}/{kind}", printer.name),
                notice: notice(headline, text, button.clone()),
            });
        };
        let mut known = false;
        if has(r, &["media-empty", "media-needed"]) {
            known = true;
            say(
                "paper",
                "Printer out of paper",
                format!("“{name}” is out of paper. Add paper and printing carries on."),
            );
        }
        if has(r, &["media-jam"]) {
            known = true;
            say(
                "jam",
                "Paper jam",
                format!("“{name}” has a paper jam. Clear it and printing carries on."),
            );
        }
        if has(r, &["cover-open", "door-open", "interlock-open"]) {
            known = true;
            say(
                "cover",
                "Printer cover open",
                format!("“{name}” has a cover open. Close it and printing carries on."),
            );
        }
        if has(r, &["toner-empty", "marker-supply-empty"]) {
            known = true;
            say(
                "supply",
                "Printer out of ink or toner",
                format!("“{name}” is out of ink or toner. Replace it and printing carries on."),
            );
        }
        if has(r, &["offline"]) {
            known = true;
            say(
                "offline",
                "Printer can’t be reached",
                format!("“{name}” can’t be reached. Check that it is on and connected."),
            );
        }
        // Stopped, and none of the above says why: not by the user, who
        // paused it.
        if printer.state == 5 && !known && !has(r, &["paused", "moving-to-paused"]) {
            say(
                "stopped",
                "Printer stopped",
                format!("“{name}” has stopped. Check the printer."),
            );
        }
    }
    for job in &watched.jobs {
        if has(
            &job.reasons,
            &["cups-held-for-authentication", "auth-info-required"],
        ) || job.reasons.iter().any(|r| r.contains("authentication"))
        {
            let (printer, document) = (one_line(&job.printer, 80), one_line(&job.name, 80));
            found.push(Problem {
                key: format!("{}/auth/{}", job.printer, job.id),
                notice: notice(
                    "Printer asks for a password",
                    format!("“{printer}” asks for a user name and password to print “{document}”."),
                    open_printers(&job.printer, Some(&job.id)),
                ),
            });
        }
    }
    found
}

/// The notices of <found> that were not said already, and <told> after it:
/// what is said stays said for as long as the problem lasts, and a problem
/// that went and came back is said again.
pub fn news(told: &mut HashSet<String>, found: Vec<Problem>) -> Vec<Notice> {
    told.retain(|key| found.iter().any(|p| &p.key == key));
    found
        .into_iter()
        .filter(|p| told.insert(p.key.clone()))
        .map(|p| p.notice)
        .collect()
}

/// nova-notification-send's words for <notice>.
pub fn notice_argv(notice: &Notice) -> Vec<String> {
    let mut argv: Vec<String> = vec![
        "nova-notification-send".into(),
        "-u".into(),
        notice.urgency.into(),
        "-g".into(),
        GLYPH.into(),
    ];
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

/// Sends the notices one after another on a thread of its own, so that
/// asking the printers never waits for one.
fn notifier(ctx: &Context) -> Result<Sender<Notice>, String> {
    let (tell, told) = mpsc::channel::<Notice>();
    let ctx = ctx.clone();
    thread::Builder::new()
        .name("printing-say".into())
        .stack_size(128 * 1024)
        .spawn(move || {
            for notice in told {
                let argv = notice_argv(&notice);
                if let Err(e) = ctx.command(&argv[0]).args(&argv[1..]).output() {
                    say!(DUTY, "could not run nova-notification-send: {e}");
                }
            }
        })
        .map_err(|e| format!("could not start the notices' thread: {e}"))?;
    Ok(tell)
}

/// How the printers holding the user's jobs are. Nothing when CUPS cannot be
/// asked, which is no job left to watch.
fn watched(ctx: &Context, user: Option<&str>) -> Watched {
    let mut command = ctx.command("nova-printers");
    command.arg("watch");
    if let Some(user) = user {
        command.arg(user);
    }
    match command.output() {
        Ok(out) if out.status.success() => parse_watch(&String::from_utf8_lossy(&out.stdout)),
        Ok(_) => Watched::default(),
        Err(e) => {
            say!(DUTY, "could not run nova-printers: {e}");
            Watched::default()
        }
    }
}

/// The subscription to CUPS's signals, made or renewed on a thread of its own:
/// it asks CUPS, which can take a moment.
fn subscribe(ctx: &Context) {
    let ctx = ctx.clone();
    let started = thread::Builder::new()
        .name("printing-subscribe".into())
        .stack_size(128 * 1024)
        .spawn(move || {
            if let Err(e) = ctx.command("nova-printers").arg("subscribe").status() {
                say!(DUTY, "could not run nova-printers: {e}");
            }
        });
    if let Err(e) = started {
        say!(DUTY, "could not subscribe to CUPS's signals: {e}");
    }
}

enum Event {
    /// A job of the user's was queued, or another's.
    Queued(Option<String>),
    /// CUPS said something else about a printer or a job.
    Changed,
    /// systemd started cups.service.
    CupsStarted,
}

pub fn serve(system: &Bus, ctx: &Context, setup: Setup) -> Result<(), String> {
    let tell = notifier(ctx)?;
    let events: Rc<RefCell<VecDeque<Event>>> = Rc::default();

    let queue = events.clone();
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
            queue.borrow_mut().push_back(match m.member() {
                Some("JobQueuedLocal") => Event::Queued(user),
                _ => Event::Changed,
            });
        })
        .map_err(|e| e.to_string())?;

    // CUPS started: from then on there is someone to ask. systemd sends its
    // jobs' ends to the ones that subscribed.
    let queue = events.clone();
    let rule = nova_sd::rule(&[
        ("type", "signal"),
        ("sender", SYSTEMD),
        ("interface", MANAGER),
        ("member", "JobRemoved"),
    ])
    .map_err(|e| e.to_string())?;
    let _started = system
        .add_match(&rule, move |m: &Message| {
            // Its job, started as the unit's: JobRemoved's id, job, unit and result.
            if matches!(
                m.args().as_deref(),
                Ok([_, _, unit, result])
                    if unit.as_str() == Some("cups.service") && result.as_str() == Some("done")
            ) {
                queue.borrow_mut().push_back(Event::CupsStarted);
            }
        })
        .map_err(|e| e.to_string())?;
    let asked = system.call_async(
        SYSTEMD,
        SYSTEMD_PATH,
        MANAGER,
        "Subscribe",
        &[],
        Some(Duration::from_secs(10)),
        |answer| {
            if let Err(e) = answer {
                say!(DUTY, "could not subscribe to systemd's jobs: {e}");
            }
        },
    );
    if let Err(e) = asked {
        say!(DUTY, "could not subscribe to systemd's jobs: {e}");
    }

    let mut told: HashSet<String> = HashSet::new();
    let mut look_at: Option<Instant> = None;
    let mut renew_at = Instant::now();
    loop {
        let now = Instant::now();
        let soon = now + setup.settle;
        let happened: Vec<Event> = events.borrow_mut().drain(..).collect();
        for event in happened {
            match event {
                Event::Queued(user) => {
                    let mine = match (&user, &setup.user) {
                        (Some(theirs), Some(me)) => theirs == me,
                        _ => true,
                    };
                    if mine {
                        look_at = Some(look_at.map_or(soon, |at| at.min(soon)));
                    }
                }
                Event::Changed => {
                    if let Some(at) = look_at {
                        look_at = Some(at.min(soon));
                    }
                }
                Event::CupsStarted => renew_at = now,
            }
        }
        if renew_at <= now {
            subscribe(ctx);
            renew_at = now + setup.renew;
        }
        if look_at.is_some_and(|at| at <= now) {
            let watched = watched(ctx, setup.user.as_deref());
            if watched.jobs.is_empty() {
                // Nothing is left to wait for: what was said is over.
                told.clear();
                look_at = None;
            } else {
                for notice in news(&mut told, problems(&watched)) {
                    let _ = tell.send(notice);
                }
                look_at = Some(now + setup.watch);
            }
        }
        let until = [Some(renew_at), look_at]
            .into_iter()
            .flatten()
            .min()
            .map(|at| at.saturating_duration_since(Instant::now()));
        let mut fds = [system.poll_fd()];
        poll(&mut fds, sooner(system.timeout(), until))
            .map_err(|e| format!("could not wait: {e}"))?;
        system
            .dispatch()
            .map_err(|e| format!("the system bus went: {e}"))?;
    }
}

pub fn run(ctx: &Context) -> Result<(), String> {
    let system = Bus::system().map_err(|e| e.to_string())?;
    serve(&system, ctx, Setup::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{calls, context, stub, wait_until};
    use nova_sd::testing::{scratch, PrivateBus};
    use nova_sd::Value;
    use std::path::Path;
    use std::thread::JoinHandle;

    fn printer(name: &str, state: i32, reasons: &[&str]) -> Printer {
        Printer {
            name: name.into(),
            state,
            reasons: reasons.iter().map(|r| r.to_string()).collect(),
        }
    }

    fn watching(printers: Vec<Printer>) -> Watched {
        Watched {
            printers,
            jobs: vec![],
        }
    }

    fn said(watched: &Watched) -> Vec<(String, String)> {
        problems(watched)
            .into_iter()
            .map(|p| (p.key, p.notice.headline))
            .collect()
    }

    #[test]
    fn what_watch_says_is_read_a_line_at_a_time() {
        let text = "printer\tOffice\t4\tmedia-empty-error,toner-low-warning\ttrue\n\
                    job\tOffice\t11\t5\tjob-printing\treport.pdf\n\
                    job\tOffice\t12\t4\tcups-held-for-authentication\ta b.pdf\n\
                    something else\n";
        assert_eq!(
            parse_watch(text),
            Watched {
                printers: vec![printer(
                    "Office",
                    4,
                    &["media-empty-error", "toner-low-warning"]
                )],
                jobs: vec![
                    Job {
                        printer: "Office".into(),
                        id: "11".into(),
                        reasons: vec!["job-printing".into()],
                        name: "report.pdf".into()
                    },
                    Job {
                        printer: "Office".into(),
                        id: "12".into(),
                        reasons: vec!["cups-held-for-authentication".into()],
                        name: "a b.pdf".into()
                    }
                ],
            }
        );
        assert_eq!(parse_watch(""), Watched::default());
    }

    #[test]
    fn a_printer_is_said_to_need_what_it_lacks_and_not_what_it_is_low_on() {
        let each = [
            ("media-empty-error", "Printer out of paper"),
            ("media-needed-warning", "Printer out of paper"),
            ("media-jam-error", "Paper jam"),
            ("cover-open-error", "Printer cover open"),
            ("door-open-report", "Printer cover open"),
            ("toner-empty-error", "Printer out of ink or toner"),
            ("marker-supply-empty-error", "Printer out of ink or toner"),
            ("offline-report", "Printer can’t be reached"),
        ];
        for (reason, headline) in each {
            let found = said(&watching(vec![printer("Office", 3, &[reason])]));
            assert_eq!(found.len(), 1, "{reason}");
            assert_eq!(found[0].1, headline, "{reason}");
        }
        // Low, not out; the user's own pause; nothing wrong.
        for reasons in [
            &["media-low-warning"][..],
            &["toner-low-warning", "marker-supply-low-warning"],
            &["paused"],
            &["moving-to-paused"],
            &[],
        ] {
            assert!(
                said(&watching(vec![printer("Office", 3, reasons)])).is_empty(),
                "{reasons:?}"
            );
        }
        assert!(said(&watching(vec![printer("Office", 5, &["paused"])])).is_empty());
    }

    #[test]
    fn a_printer_stopped_for_no_reason_of_the_users_is_said_to_have_stopped() {
        let found = said(&watching(vec![printer("Office", 5, &[])]));
        assert_eq!(
            found,
            [("Office/stopped".to_string(), "Printer stopped".to_string())]
        );
        // Out of paper is what it says, not also that it stopped.
        let found = said(&watching(vec![printer(
            "Office",
            5,
            &["media-empty-error"],
        )]));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].1, "Printer out of paper");
    }

    #[test]
    fn two_problems_of_one_printer_are_two_notices() {
        let found = said(&watching(vec![printer(
            "Office",
            3,
            &["media-jam-error", "cover-open-error"],
        )]));
        assert_eq!(
            found.iter().map(|f| f.0.as_str()).collect::<Vec<_>>(),
            ["Office/jam", "Office/cover"]
        );
    }

    #[test]
    fn a_notice_is_in_plain_words_with_a_button_to_the_printer() {
        let found = problems(&watching(vec![printer(
            "Office",
            3,
            &["media-empty-error"],
        )]));
        assert_eq!(
            found[0].notice,
            Notice {
                headline: "Printer out of paper".into(),
                text: "“Office” is out of paper. Add paper and printing carries on.".into(),
                urgency: "normal",
                button: Some((
                    "Open Printers".into(),
                    vec![
                        "nova-shell".into(),
                        "shell".into(),
                        "summon".into(),
                        "nova.settings".into(),
                        r#"{"page":"printers","printer":"Office"}"#.into()
                    ]
                )),
                expire_ms: None,
            }
        );
    }

    #[test]
    fn a_held_job_that_asks_for_a_password_is_said_with_its_document() {
        let watched = Watched {
            printers: vec![printer("Office", 3, &[])],
            jobs: vec![
                Job {
                    printer: "Office".into(),
                    id: "12".into(),
                    reasons: vec!["cups-held-for-authentication".into()],
                    name: "Budget 2027.pdf".into(),
                },
                Job {
                    printer: "Office".into(),
                    id: "13".into(),
                    reasons: vec!["job-printing".into()],
                    name: "other.pdf".into(),
                },
            ],
        };
        let found = problems(&watched);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].key, "Office/auth/12");
        assert_eq!(found[0].notice.headline, "Printer asks for a password");
        assert_eq!(
            found[0].notice.text,
            "“Office” asks for a user name and password to print “Budget 2027.pdf”."
        );
        assert_eq!(
            found[0].notice.button.as_ref().unwrap().1[4],
            r#"{"page":"printers","printer":"Office","job":"12"}"#
        );
    }

    #[test]
    fn what_a_device_or_an_app_names_is_one_plain_line_and_one_json_string() {
        let name = "Of\"fice\\\n--exec";
        let found = problems(&watching(vec![printer(name, 3, &["media-jam-error"])]));
        let text = "“Of\"fice\\ --exec” has a paper jam. Clear it and printing carries on.";
        assert_eq!(found[0].notice.text, text);
        let payload = &found[0].notice.button.as_ref().unwrap().1[4];
        assert_eq!(
            payload,
            "{\"page\":\"printers\",\"printer\":\"Of\\\"fice\\\\\\u000a--exec\"}"
        );
        // The words are the text's, never options of nova-notification-send.
        let argv = notice_argv(&found[0].notice);
        let exec = argv.iter().rposition(|w| w == "--exec").unwrap();
        assert_eq!(argv[exec - 1], text);
    }

    #[test]
    fn a_problem_is_said_once_while_it_lasts_and_again_when_it_comes_back() {
        let mut told = HashSet::new();
        let out_of_paper = || {
            problems(&watching(vec![printer(
                "Office",
                3,
                &["media-empty-error"],
            )]))
        };
        assert_eq!(news(&mut told, out_of_paper()).len(), 1);
        assert!(news(&mut told, out_of_paper()).is_empty());
        // A jam as well: only the jam is new.
        let both = problems(&watching(vec![printer(
            "Office",
            3,
            &["media-empty-error", "media-jam-error"],
        )]));
        let fresh = news(&mut told, both);
        assert_eq!(fresh.len(), 1);
        assert_eq!(fresh[0].headline, "Paper jam");
        // Paper added: nothing wrong, and so nothing said; then out again.
        assert!(news(&mut told, vec![]).is_empty());
        assert_eq!(news(&mut told, out_of_paper()).len(), 1);
        // Another printer's is another problem.
        let hall = problems(&watching(vec![printer("Hall", 3, &["media-empty-error"])]));
        assert_eq!(news(&mut told, hall).len(), 1);
    }

    #[test]
    fn the_notices_words_for_nova_notification_send() {
        let found = problems(&watching(vec![printer("Office", 3, &["cover-open-error"])]));
        assert_eq!(
            notice_argv(&found[0].notice),
            vec![
                "nova-notification-send".to_string(),
                "-u".into(),
                "normal".into(),
                "-g".into(),
                GLYPH.into(),
                "--button".into(),
                "Open Printers".into(),
                "Printer cover open".into(),
                "“Office” has a cover open. Close it and printing carries on.".into(),
                "--exec".into(),
                "nova-shell".into(),
                "shell".into(),
                "summon".into(),
                "nova.settings".into(),
                r#"{"page":"printers","printer":"Office"}"#.into(),
            ]
        );
    }

    fn quick() -> Setup {
        Setup {
            settle: Duration::from_millis(30),
            watch: Duration::from_millis(60),
            renew: Duration::from_secs(3600),
            user: Some("andre".into()),
        }
    }

    /// The duty on its own connection to a system-like bus.
    fn printing(system: &str, ctx: &Context, setup: Setup) -> JoinHandle<Result<(), String>> {
        let (system, ctx) = (system.to_owned(), ctx.clone());
        thread::spawn(move || {
            let system = Bus::connect(&system).map_err(|e| e.to_string())?;
            serve(&system, &ctx, setup)
        })
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

    /// What `nova-printers watch` says from now on.
    fn watch_says(dir: &Path, text: &str) {
        std::fs::write(dir.join("watch"), text).unwrap();
    }

    fn watch_calls(dir: &Path) -> usize {
        calls(dir)
            .iter()
            .filter(|c| c.starts_with("nova-printers watch"))
            .count()
    }

    fn notices(dir: &Path) -> Vec<String> {
        calls(dir)
            .into_iter()
            .filter(|c| c.starts_with("nova-notification-send"))
            .collect()
    }

    #[test]
    fn jobs_are_watched_while_they_are_queued_and_a_problem_is_said_once() {
        let Some(system) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("printing");
        let ctx = context(&dir);
        stub(
            &dir,
            "nova-printers",
            &format!(
                "[[ $1 != watch ]] || cat '{}/watch' 2>/dev/null; exit 0",
                dir.display()
            ),
        );
        stub(&dir, "nova-notification-send", "");
        let duty = printing(&system.address, &ctx, quick());
        let cups = Bus::connect(&system.address).unwrap();

        // At login CUPS is asked for its subscription, and nothing else.
        wait_until("the subscription", || {
            calls(&dir) == ["nova-printers subscribe"]
        });
        thread::sleep(Duration::from_millis(150));
        assert_eq!(watch_calls(&dir), 0);

        // Another user's job is theirs.
        spooler(&cups, "JobQueuedLocal", Some("guest"));
        thread::sleep(Duration::from_millis(150));
        assert_eq!(watch_calls(&dir), 0);

        // The user's, and the printer is out of paper: said once, however long.
        watch_says(
            &dir,
            "printer\tOffice\t3\tmedia-empty-error\ttrue\njob\tOffice\t7\t3\t\treport.pdf\n",
        );
        spooler(&cups, "JobQueuedLocal", Some("andre"));
        wait_until("the notice", || notices(&dir).len() == 1);
        assert_eq!(
            notices(&dir)[0],
            format!(
                "nova-notification-send -u normal -g {GLYPH} --button Open Printers Printer out of paper “Office” is out of paper. Add paper and printing carries on. --exec nova-shell shell summon nova.settings {{\"page\":\"printers\",\"printer\":\"Office\"}}"
            )
        );
        wait_until("a few looks", || watch_calls(&dir) >= 4);
        assert_eq!(notices(&dir).len(), 1);
        assert!(calls(&dir).contains(&"nova-printers watch andre".to_string()));

        // Paper added, and then a jam: a new problem, said.
        watch_says(
            &dir,
            "printer\tOffice\t3\t\ttrue\njob\tOffice\t7\t3\t\treport.pdf\n",
        );
        thread::sleep(Duration::from_millis(200));
        assert_eq!(notices(&dir).len(), 1);
        watch_says(
            &dir,
            "printer\tOffice\t3\tmedia-jam-error\ttrue\njob\tOffice\t7\t3\t\treport.pdf\n",
        );
        wait_until("the jam", || notices(&dir).len() == 2);

        // Printed: no job left, and no more looks.
        watch_says(&dir, "");
        spooler(&cups, "QueueChanged", None);
        wait_until("the last look", || {
            let n = watch_calls(&dir);
            thread::sleep(Duration::from_millis(250));
            n == watch_calls(&dir)
        });
        let after = watch_calls(&dir);
        thread::sleep(Duration::from_millis(300));
        assert_eq!(watch_calls(&dir), after);
        assert_eq!(notices(&dir).len(), 2);

        // The next job watches again, and what was said before is said again.
        watch_says(
            &dir,
            "printer\tOffice\t3\tmedia-jam-error\ttrue\njob\tOffice\t8\t3\t\tother.pdf\n",
        );
        spooler(&cups, "JobQueuedLocal", Some("andre"));
        wait_until("the jam again", || notices(&dir).len() == 3);
        assert!(!duty.is_finished());
    }

    #[test]
    fn the_subscription_is_renewed_as_systemd_says_cups_started() {
        let (Some(system), Some(_)) = (PrivateBus::start(), Some(())) else {
            return;
        };
        let dir = scratch("printing");
        let ctx = context(&dir);
        stub(&dir, "nova-printers", "");
        let _duty = printing(&system.address, &ctx, quick());
        wait_until("the first", || calls(&dir) == ["nova-printers subscribe"]);

        // As systemd would: its name, and a job of cups.service done.
        let manager = Bus::connect(&system.address).unwrap();
        assert!(manager.request_name(SYSTEMD, 0).unwrap());
        let ended = |unit: &str, result: &str| {
            manager
                .emit_signal(
                    SYSTEMD_PATH,
                    MANAGER,
                    "JobRemoved",
                    &[
                        Value::Uint32(1),
                        Value::str("/org/freedesktop/systemd1/job/1"),
                        Value::str(unit),
                        Value::str(result),
                    ],
                )
                .unwrap();
            manager.flush().unwrap();
        };
        ended("cups.socket", "done");
        ended("cups.service", "failed");
        thread::sleep(Duration::from_millis(150));
        assert_eq!(calls(&dir).len(), 1);
        ended("cups.service", "done");
        wait_until("the second", || calls(&dir).len() == 2);
    }
}
