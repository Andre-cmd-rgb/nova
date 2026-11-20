//! Printing: what a printer asks of the user while their documents wait for it.
//!
//! This was system-config-printer's applet, all day in 40 MB of Python: it
//! waited for CUPS to say a job was queued and then showed a job viewer, whose
//! notices were a printer out of paper or jammed and a held job's password.
//! Nova's own Settings has a Printers page now, and what is left of the
//! applet is this:
//!
//! - It waits for CUPS's signals (org.cups.cupsd.Notifier, on the system
//!   bus: JobCreated, JobState, PrinterStateChanged, ...). CUPS's dbus
//!   notifier sends them for whoever has subscribed, and nobody has now that
//!   the applet is gone, so `nova-printers subscribe` does, for a day at a
//!   time (every six hours here, and whenever systemd says it started
//!   cups.service): it does nothing while CUPS is not running, so that
//!   nothing here starts CUPS, no look at login. The signals say no job's
//!   owner, and anyone may send them: a job created is a look, no more.
//! - Once a job is created, and as CUPS starts (a job may have started it
//!   before there was a subscription), it asks `nova-printers watch` every
//!   few seconds how the printers holding this user's jobs are. It stops when
//!   no job of theirs is left.
//! - What the user must do something about is said in a notification, once for
//!   as long as it lasts, with a button that opens Settings' Printers page at
//!   that printer: no paper, a paper jam, a cover open, no toner or ink, a
//!   printer that cannot be reached or has stopped. A printer low on paper or
//!   ink, or paused by the user, is on the page and not said.
//! - A job held for a user name and password (a printer at work, a shared
//!   one) is asked about on the shell's card, the drive passphrase's, with the
//!   user's own name to begin with. CUPS takes any answer and lets the job
//!   go; the printer refusing it holds the job again, which the card says,
//!   and asks again. Cancelled, it is not asked again for that job until
//!   Printers' Sign In (`nova-printers sign-in`, a switch in the runtime
//!   folder); with no shell to ask on, a notice says it.
//!
//! The applet also owned com.redhat.NewPrinterNotification, which its udev
//! rules called as a printer was plugged in. Nothing calls it without them:
//! a modern USB printer is driverless through ipp-usb and CUPS sees it like a
//! printer on the network, and an older one is added on the Printers page.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::Stdio;
use std::rc::Rc;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner, PollFd, POLLIN};
use nova_sd::{Bus, Message};

use crate::common::{retry_busy, Context, FolderWatch, IN_CLOSE_WRITE, IN_CREATE, IN_MOVED_TO};
use crate::idle::one_line;
use crate::json::quote;
use crate::prompt::{Ask, Dialog, Ender, Field, Glyph};
use crate::say;

pub const DUTY: &str = "printing";
const NOTIFIER_PATH: &str = "/org/cups/cupsd/Notifier";
const NOTIFIER: &str = "org.cups.cupsd.Notifier";
/// The switch `nova-printers sign-in` writes, in the runtime folder: the
/// printer and the held job to ask about again, a line each.
const SWITCH: &str = "printer-sign-in";
/// The answers a card takes before it goes: the job stays held, for
/// Printers' Sign In.
const TRIES: u32 = 3;
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
    /// After a held job is answered, how often it is looked at, and for how
    /// long at most, to know whether the printer took the answer.
    pub check: Duration,
    pub patience: Duration,
    /// Whose jobs count: the user's name, as CUPS has it.
    pub user: Option<String>,
}

impl Default for Setup {
    fn default() -> Setup {
        Setup {
            settle: Duration::from_secs(2),
            watch: Duration::from_secs(5),
            renew: Duration::from_secs(6 * 3600),
            check: Duration::from_secs(1),
            patience: Duration::from_secs(30),
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

/// Whether <job> is held for a user name and password.
fn asks_for_password(job: &Job) -> bool {
    has(
        &job.reasons,
        &["cups-held-for-authentication", "auth-info-required"],
    ) || job.reasons.iter().any(|r| r.contains("authentication"))
}

/// Which held job a sign-in is for, as its problem's key.
fn sign_in_key(printer: &str, job: &str) -> String {
    format!("{printer}/auth/{job}")
}

/// The button of every notice: Settings' Printers page, at <printer>, and at
/// <job> when it is about one.
fn open_printers(printer: &str, job: Option<&str>) -> (String, Vec<String>) {
    let mut payload = format!("{{\"page\":\"printers\",\"printer\":{}", quote(printer));
    if let Some(job) = job {
        payload.push_str(&format!(",\"job\":{}", quote(job)));
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
/// it. <key> says which problem of which printer (or job) it is. A held
/// job's user name and password are asked for on the card: the notice is
/// for when there is no card to ask on.
#[derive(Debug, PartialEq)]
pub struct Problem {
    pub key: String,
    pub notice: Notice,
    pub sign_in: Option<SignIn>,
}

/// A held job that asks for a user name and password.
#[derive(Debug, Clone, PartialEq)]
pub struct SignIn {
    pub printer: String,
    pub job: String,
    pub document: String,
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
                sign_in: None,
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
    for job in watched.jobs.iter().filter(|job| asks_for_password(job)) {
        let (printer, document) = (one_line(&job.printer, 80), one_line(&job.name, 80));
        found.push(Problem {
            key: sign_in_key(&job.printer, &job.id),
            notice: notice(
                "Printer asks for a password",
                format!("“{printer}” asks for a user name and password to print “{document}”."),
                open_printers(&job.printer, Some(&job.id)),
            ),
            sign_in: Some(SignIn {
                printer: job.printer.clone(),
                job: job.id.clone(),
                document: job.name.clone(),
            }),
        });
    }
    found
}

/// The problems of <found> that were not said already, and <told> after it:
/// what is said stays said for as long as the problem lasts, and a problem
/// that went and came back is said again.
pub fn news(told: &mut HashSet<String>, found: Vec<Problem>) -> Vec<Problem> {
    told.retain(|key| found.iter().any(|p| &p.key == key));
    found
        .into_iter()
        .filter(|p| told.insert(p.key.clone()))
        .collect()
}

/// The card for <sign_in>, with <user> as the name to begin with: a printer
/// at work often wants the same name as the computer.
pub fn sign_in_ask(sign_in: &SignIn, user: &str) -> Ask {
    let printer = one_line(&sign_in.printer, 80);
    let document = one_line(&sign_in.document, 80);
    let mut ask = Ask::new(Glyph::Printer, &format!("Sign in to “{printer}”"));
    ask.text = if document.is_empty() {
        "The printer asks for a user name and password.".into()
    } else {
        format!("To print “{document}”, the printer asks for a user name and password.")
    };
    ask.fields.push(Field::plain("user", "User name", user));
    ask.fields.push(Field::secret("password", "Password"));
    ask.accept = "Print".into();
    ask
}

/// The cards up, by their problem's key, with the hold on each once it is
/// open; a key taken away calls the card off.
type Cards = Arc<Mutex<HashMap<String, Option<Ender>>>>;

/// Hands <user> and <password> to CUPS for the held job, on nova-printers'
/// standard input, never as an argument, which anyone may read. Whether CUPS
/// took them: the printer has not seen them yet.
fn authenticate(ctx: &Context, sign_in: &SignIn, user: &str, password: &str) -> bool {
    let mut command = ctx.command("nova-printers");
    command
        .args(["authenticate", &sign_in.printer, &sign_in.job])
        .stdin(Stdio::piped())
        .stdout(Stdio::null());
    let started = retry_busy(|| command.spawn());
    let mut child = match started {
        Ok(child) => child,
        Err(e) => {
            say!(DUTY, "could not run nova-printers: {e}");
            return false;
        }
    };
    if let Some(mut stdin) = child.stdin.take() {
        let mut lines = format!("{user}\n{password}\n").into_bytes();
        let _ = stdin.write_all(&lines);
        lines.fill(0);
    }
    child.wait().is_ok_and(|status| status.success())
}

/// Whether the printer took the answer to <sign_in>: CUPS lets the job go at
/// once, and holds it again for a user name and password when the printer
/// refuses them. A job gone (printed, or cancelled), or not held again
/// within the patience, was taken.
fn taken(ctx: &Context, setup: &Setup, sign_in: &SignIn) -> bool {
    let until = Instant::now() + setup.patience;
    loop {
        thread::sleep(setup.check);
        let now = watched(ctx, setup.user.as_deref());
        match now
            .jobs
            .iter()
            .find(|job| job.printer == sign_in.printer && job.id == sign_in.job)
        {
            None => return true,
            Some(job) if asks_for_password(job) => return false,
            Some(_) if Instant::now() >= until => return true,
            Some(_) => {}
        }
    }
}

/// Asks for <sign_in>'s user name and password on the card until the
/// printer takes them, the card is cancelled or called off, or TRIES
/// answers did not do. With no card to ask on, <notice> says it.
fn sign_in(
    ctx: &Context,
    setup: &Setup,
    sign_in: &SignIn,
    notice: Notice,
    tell: &Sender<Notice>,
    cards: &Cards,
) {
    let user = setup.user.clone().unwrap_or_default();
    let mut dialog = match Dialog::open(ctx, &sign_in_ask(sign_in, &user)) {
        Ok(dialog) => dialog,
        Err(e) => {
            say!(
                DUTY,
                "no card to ask for a printer's password on ({e}): a notice says it"
            );
            let _ = tell.send(notice);
            return;
        }
    };
    {
        let Ok(mut open) = cards.lock() else { return };
        match open.get_mut(&sign_in_key(&sign_in.printer, &sign_in.job)) {
            Some(slot) => *slot = dialog.ender().ok(),
            // Called off while it opened: the job went.
            None => return,
        }
    }
    for tries in 1..=TRIES {
        let Some(mut values) = dialog.answer() else {
            return;
        };
        let name = values.remove("user").unwrap_or_default();
        let mut password = values.remove("password").unwrap_or_default();
        let asked = authenticate(ctx, sign_in, name.trim(), &password);
        // SAFETY: zeroes are valid UTF-8.
        unsafe { password.as_bytes_mut().fill(0) };
        let words = if !asked {
            "The printer could not be asked. Try again."
        } else if taken(ctx, setup, sign_in) {
            dialog.done();
            return;
        } else {
            "That user name and password did not work."
        };
        let _ = dialog.wrong(words);
        if tries == TRIES {
            dialog.done();
            return;
        }
    }
}

/// The card for <problem>'s held job, on a thread of its own, unless one is
/// up for it already.
fn start_sign_in(
    ctx: &Context,
    setup: &Setup,
    problem: Problem,
    tell: &Sender<Notice>,
    cards: &Cards,
) {
    let Some(job) = problem.sign_in else {
        return;
    };
    {
        let Ok(mut open) = cards.lock() else { return };
        if open.contains_key(&problem.key) {
            return;
        }
        open.insert(problem.key.clone(), None);
    }
    let (ctx, setup, tell, cards) = (ctx.clone(), setup.clone(), tell.clone(), cards.clone());
    let (key, notice) = (problem.key, problem.notice);
    let started = thread::Builder::new()
        .name("printing-sign-in".into())
        .stack_size(256 * 1024)
        .spawn({
            let (key, notice, cards, tell) =
                (key.clone(), notice.clone(), cards.clone(), tell.clone());
            move || {
                sign_in(&ctx, &setup, &job, notice, &tell, &cards);
                if let Ok(mut open) = cards.lock() {
                    open.remove(&key);
                }
            }
        });
    if let Err(e) = started {
        say!(DUTY, "could not ask for a printer's password: {e}");
        if let Ok(mut open) = cards.lock() {
            open.remove(&key);
        }
        let _ = tell.send(notice);
    }
}

/// Calls off the cards of jobs that are gone: printed, or cancelled.
fn call_off(cards: &Cards, watched: &Watched) {
    let Ok(mut open) = cards.lock() else { return };
    open.retain(|key, ender| {
        let here = watched
            .jobs
            .iter()
            .any(|job| sign_in_key(&job.printer, &job.id) == *key);
        if let (false, Some(ender)) = (here, ender) {
            ender.end();
        }
        here
    });
}

/// The held job the switch names, as its problem's key. The switch is taken
/// away: it says it once.
fn switched(runtime: &Path) -> Option<String> {
    let path = runtime.join(SWITCH);
    let text = fs::read_to_string(&path).ok()?;
    let _ = fs::remove_file(&path);
    let mut lines = text.lines();
    let (printer, job) = (lines.next()?, lines.next()?);
    (!printer.is_empty() && !job.is_empty() && job.bytes().all(|b| b.is_ascii_digit()))
        .then(|| sign_in_key(printer, job))
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
                let mut command = ctx.command(&argv[0]);
                command.args(&argv[1..]);
                if let Err(e) = retry_busy(|| command.output()) {
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
    match retry_busy(|| command.output()) {
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
            let mut command = ctx.command("nova-printers");
            command.arg("subscribe");
            if let Err(e) = retry_busy(|| command.status()) {
                say!(DUTY, "could not run nova-printers: {e}");
            }
        });
    if let Err(e) = started {
        say!(DUTY, "could not subscribe to CUPS's signals: {e}");
    }
}

enum Event {
    /// A job was created: the user's, or another's.
    Queued,
    /// CUPS said something else about a printer or a job.
    Changed,
    /// systemd started cups.service.
    CupsStarted,
}

pub fn serve(system: &Bus, ctx: &Context, setup: Setup) -> Result<(), String> {
    let tell = notifier(ctx)?;
    let runtime = ctx
        .runtime_dir()
        .map_err(|e| format!("no runtime folder: {e}"))?
        .to_owned();
    let switch = FolderWatch::new(&runtime, IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE)
        .map_err(|e| format!("cannot watch {}: {e}", runtime.display()))?;
    let cards: Cards = Arc::default();
    let events: Rc<RefCell<VecDeque<Event>>> = Rc::default();

    let queue = events.clone();
    let rule = nova_sd::rule(&[
        ("type", "signal"),
        ("path", NOTIFIER_PATH),
        ("interface", NOTIFIER),
    ])
    .map_err(|e| e.to_string())?;
    let _notifier = system
        .add_match(&rule, move |m: &Message| {
            queue.borrow_mut().push_back(match m.member() {
                Some("JobCreated") => Event::Queued,
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
                Event::Queued => look_at = Some(look_at.map_or(soon, |at| at.min(soon))),
                Event::Changed => {
                    if let Some(at) = look_at {
                        look_at = Some(at.min(soon));
                    }
                }
                Event::CupsStarted => {
                    renew_at = now;
                    look_at = Some(look_at.map_or(soon, |at| at.min(soon)));
                }
            }
        }
        if renew_at <= now {
            subscribe(ctx);
            renew_at = now + setup.renew;
        }
        if look_at.is_some_and(|at| at <= now) {
            let watched = watched(ctx, setup.user.as_deref());
            call_off(&cards, &watched);
            if watched.jobs.is_empty() {
                // Nothing is left to wait for: what was said is over.
                told.clear();
                look_at = None;
            } else {
                for problem in news(&mut told, problems(&watched)) {
                    if problem.sign_in.is_some() {
                        start_sign_in(ctx, &setup, problem, &tell, &cards);
                    } else {
                        let _ = tell.send(problem.notice);
                    }
                }
                look_at = Some(now + setup.watch);
            }
        }
        let until = [Some(renew_at), look_at]
            .into_iter()
            .flatten()
            .min()
            .map(|at| at.saturating_duration_since(Instant::now()));
        let mut fds = [system.poll_fd(), PollFd::new(switch.fd(), POLLIN)];
        poll(&mut fds, sooner(system.timeout(), until))
            .map_err(|e| format!("could not wait: {e}"))?;
        // Printers' Sign In: the job is asked about again, at once.
        if fds[1].ready() && switch.names().iter().any(|n| n == SWITCH) {
            if let Some(key) = switched(&runtime) {
                told.remove(&key);
                look_at = Some(Instant::now());
            }
        }
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
    use crate::prompt::fake::Card;
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
        assert_eq!(
            found[0].sign_in,
            Some(SignIn {
                printer: "Office".into(),
                job: "12".into(),
                document: "Budget 2027.pdf".into()
            })
        );
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
            "{\"page\":\"printers\",\"printer\":\"Of\\\"fice\\\\\\n--exec\"}"
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
        assert_eq!(fresh[0].notice.headline, "Paper jam");
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
            check: Duration::from_millis(20),
            patience: Duration::from_secs(2),
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

    /// CUPS's dbus notifier saying <member> about a job on Office, as it
    /// does (its text, the printer's uri, name, state, reasons and whether it
    /// takes jobs, then the job's id, state, reasons, name and impressions):
    /// no owner.
    fn cups_says(cups: &Bus, member: &str) {
        let args = [
            Value::str("Job created."),
            Value::str("ipp://localhost/printers/Office"),
            Value::str("Office"),
            Value::Uint32(3),
            Value::str("none"),
            Value::Bool(true),
            Value::Uint32(7),
            Value::Uint32(3),
            Value::str("job-incoming"),
            Value::str("report.pdf"),
            Value::Uint32(0),
        ];
        cups.emit_signal(NOTIFIER_PATH, NOTIFIER, member, &args)
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

        // A job created, but not the user's: one look, which finds none of
        // theirs, and then no more.
        cups_says(&cups, "JobCreated");
        wait_until("the look", || watch_calls(&dir) == 1);
        thread::sleep(Duration::from_millis(200));
        assert_eq!(watch_calls(&dir), 1);
        // What else CUPS says is no look while no job is watched.
        cups_says(&cups, "JobState");
        thread::sleep(Duration::from_millis(150));
        assert_eq!(watch_calls(&dir), 1);

        // The user's, and the printer is out of paper: said once, however long.
        watch_says(
            &dir,
            "printer\tOffice\t3\tmedia-empty-error\ttrue\njob\tOffice\t7\t3\t\treport.pdf\n",
        );
        cups_says(&cups, "JobCreated");
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
        cups_says(&cups, "JobCompleted");
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
        cups_says(&cups, "JobCreated");
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
        // Started: the subscription, and a look, for the job that may have
        // started CUPS before there was one.
        ended("cups.service", "done");
        let subscribes = || {
            calls(&dir)
                .iter()
                .filter(|c| *c == "nova-printers subscribe")
                .count()
        };
        wait_until("the second", || subscribes() == 2 && watch_calls(&dir) == 1);
    }

    #[test]
    fn the_sign_in_card_asks_in_plain_words_with_the_users_name() {
        let job = SignIn {
            printer: "Office\n2".into(),
            job: "9".into(),
            document: "Budget.pdf".into(),
        };
        let ask = sign_in_ask(&job, "andre");
        assert_eq!(ask.glyph, Glyph::Printer);
        assert_eq!(ask.title, "Sign in to “Office 2”");
        assert_eq!(
            ask.text,
            "To print “Budget.pdf”, the printer asks for a user name and password."
        );
        assert_eq!(
            ask.fields,
            [
                Field::plain("user", "User name", "andre"),
                Field::secret("password", "Password")
            ]
        );
        let unnamed = SignIn {
            document: String::new(),
            ..job
        };
        assert_eq!(
            sign_in_ask(&unnamed, "").text,
            "The printer asks for a user name and password."
        );
    }

    const HELD: &str =
        "printer\tOffice\t3\t\ttrue\njob\tOffice\t9\t4\tcups-held-for-authentication\tBudget.pdf\n";

    /// nova-printers as a sign-in needs it: watch says what the test wrote;
    /// authenticate writes down the two lines it was given, and the password
    /// "right" lets the job go (printed: no job left).
    fn signing_stub(dir: &Path) {
        let d = dir.display();
        stub(
            dir,
            "nova-printers",
            &format!(
                "case $1 in\n\
                 watch) cat '{d}/watch' 2>/dev/null ;;\n\
                 authenticate) IFS= read -r user; IFS= read -r password\n\
                 printf '%s\\n%s\\n' \"$user\" \"$password\" >>'{d}/auth'\n\
                 [[ $password != right ]] || : >'{d}/watch' ;;\n\
                 esac\n\
                 exit 0"
            ),
        );
        stub(dir, "nova-notification-send", "");
    }

    fn handed(dir: &Path) -> String {
        std::fs::read_to_string(dir.join("auth")).unwrap_or_default()
    }

    #[test]
    fn a_held_job_is_asked_about_on_the_card_until_the_printer_takes_it() {
        let Some(system) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("printing");
        let ctx = context(&dir);
        signing_stub(&dir);
        let card = Card::listen(
            &ctx.runtime,
            &[
                Some(r#"{"user":" office ","password":"wrong"}"#),
                Some(r#"{"user":"office","password":"right"}"#),
            ],
        );
        let _duty = printing(&system.address, &ctx, quick());
        let cups = Bus::connect(&system.address).unwrap();
        wait_until("the subscription", || {
            calls(&dir).contains(&"nova-printers subscribe".to_string())
        });
        watch_says(&dir, HELD);
        cups_says(&cups, "JobCreated");

        // The wrong password: the printer holds the job again, and the card
        // says so and asks again; the right one, and the job goes.
        wait_until("the right password", || {
            handed(&dir) == "office\nwrong\noffice\nright\n"
        });
        wait_until("the card's end", || card.ended() == [0]);
        let lines = card.lines();
        assert!(lines.iter().all(|(n, _)| *n == 0), "one card: {lines:?}");
        assert!(lines[0]
            .1
            .contains(r#""glyph":"printer","title":"Sign in to “Office”""#));
        assert!(lines[0]
            .1
            .contains(r#"{"id":"user","label":"User name","secret":false,"value":"andre"}"#));
        assert_eq!(
            lines[1].1,
            r#"{"type":"wrong","text":"That user name and password did not work."}"#
        );
        // The password went to nova-printers on its input, never as a word.
        assert!(calls(&dir)
            .iter()
            .all(|c| !c.contains("wrong") && !c.contains("right")));
        assert!(notices(&dir).is_empty());
    }

    #[test]
    fn a_card_cancelled_is_not_asked_again_until_printers_sign_in() {
        let Some(system) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("printing");
        let ctx = context(&dir);
        signing_stub(&dir);
        let card = Card::listen(
            &ctx.runtime,
            &[
                Some("cancel"),
                Some(r#"{"user":"office","password":"right"}"#),
            ],
        );
        let _duty = printing(&system.address, &ctx, quick());
        let cups = Bus::connect(&system.address).unwrap();
        wait_until("the subscription", || {
            calls(&dir).contains(&"nova-printers subscribe".to_string())
        });
        watch_says(&dir, HELD);
        cups_says(&cups, "JobCreated");
        wait_until("the cancel", || card.ended() == [0]);
        let looks = watch_calls(&dir);
        wait_until("a few looks", || watch_calls(&dir) >= looks + 4);
        assert_eq!(card.lines().len(), 1, "asked once");
        assert!(notices(&dir).is_empty());
        assert_eq!(handed(&dir), "");

        // Sign In on Printers: the switch, written as nova-printers writes it.
        let switch = ctx.runtime.join(SWITCH);
        std::fs::write(ctx.runtime.join(".switch"), "Office\n9\n").unwrap();
        std::fs::rename(ctx.runtime.join(".switch"), &switch).unwrap();
        wait_until("the answer", || handed(&dir) == "office\nright\n");
        assert!(!switch.exists(), "a switch says it once");
        assert_eq!(card.lines()[1].0, 1, "on a card of its own");
    }

    #[test]
    fn with_no_card_to_ask_on_a_notice_says_it() {
        let Some(system) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("printing");
        let ctx = context(&dir);
        signing_stub(&dir);
        let _duty = printing(&system.address, &ctx, quick());
        let cups = Bus::connect(&system.address).unwrap();
        wait_until("the subscription", || {
            calls(&dir).contains(&"nova-printers subscribe".to_string())
        });
        watch_says(&dir, HELD);
        cups_says(&cups, "JobCreated");
        wait_until("the notice", || notices(&dir).len() == 1);
        assert!(notices(&dir)[0].contains("Printer asks for a password"));
        let looks = watch_calls(&dir);
        wait_until("a few looks", || watch_calls(&dir) >= looks + 4);
        assert_eq!(notices(&dir).len(), 1);
    }

    #[test]
    fn a_card_whose_job_went_is_called_off() {
        let Some(system) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("printing");
        let ctx = context(&dir);
        signing_stub(&dir);
        // Nobody answers it.
        let card = Card::listen(&ctx.runtime, &[None]);
        let _duty = printing(&system.address, &ctx, quick());
        let cups = Bus::connect(&system.address).unwrap();
        wait_until("the subscription", || {
            calls(&dir).contains(&"nova-printers subscribe".to_string())
        });
        watch_says(&dir, HELD);
        cups_says(&cups, "JobCreated");
        wait_until("the card", || card.lines().len() == 1);
        // The job cancelled on Printers: no job left, and the card goes.
        watch_says(&dir, "");
        cups_says(&cups, "JobCompleted");
        wait_until("the card's end", || card.ended() == [0]);
        assert_eq!(handed(&dir), "");
    }
}
