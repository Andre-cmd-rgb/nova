//! What the daemon tells whoever shows AirDrop on this computer, and what it
//! is told back: a socket in the user's runtime folder (meet.rs has its path).
//!
//! Whoever connects says in one line what it wants:
//!
//!   watch            how things are, as a line of JSON, now and at each change
//!   status           the same in plain words, once
//!   accept [<id>]    yes to the question that is open (the one with that id)
//!   decline [<id>]   no to it
//!   hold             the user holds AirDrop on (`nova airdrop on`): until a
//!                    transfer to this computer is over
//!   stay             the doorbell holds it on: the shell says it for an
//!                    AirDrop it switched on for an iPhone's share sheet
//!   unstay           the doorbell lets go, as the sheet closes: AirDrop ends
//!                    if nothing else holds it
//!   stop             the user's off: AirDrop ends now, whatever holds it, and
//!                    a send that is going on ends with it
//!   send             with files passed alongside, open (SCM_RIGHTS): this
//!                    computer sends them (`send icon`: the last is a picture
//!                    for the offer, JPEG 2000); the connection is the send's from
//!                    then on (send.rs has what is said over it), and the send
//!                    holds AirDrop on until it is over, or its client goes
//!
//! and all but `watch` and `send` are answered with a line: `ok`, or why not.
//! A watcher may say the others before `send` too, and gets no answer but the
//! change itself.
//!
//! Who holds AirDrop on is the daemon's to know: it ends a moment after the
//! last lets go (main.rs), and the doorbell's going does not switch it off
//! from under the user or a send. The user's stop ends it whatever holds it:
//! a daemon that is to end always can, as its own end is what gives the Wi-Fi
//! back. Once it has decided to end, `hold` and `stay` are answered that it is
//! going off, and `send` with a line that says so (`{"state":"closing"}`):
//! whoever asked waits for it to go and starts it again.
//!
//! The lines of JSON all have a `state`, and with it:
//!
//!   waiting    `name` (what senders see), `seen` (a sender has this computer
//!              in its list), `ends` (when it gives up, in Unix seconds; 0 if never)
//!   asked      `id`, `sender`, `files` (each a `name` and `bytes`), `bytes`, `links`,
//!              `icon` (the sender's small picture of what it sends, in a file beside
//!              the socket while it is asked, as the sender sent it: JPEG 2000 from
//!              an iPhone, a stranger's to make up; "" for none)
//!   receiving  `sender`, `files`, `received`, `bytes`
//!   received   `sender`, `paths`, `bytes`, `seconds`
//!   links      `sender`, `links`
//!   declined   `sender`
//!   failed     `why`, a sentence for the user
//!
//! Only this user can reach the socket: the runtime folder is theirs alone.
//! What a sender calls itself and its files goes out as JSON strings, escaped,
//! and has been cleaned of control characters where it came in (receiver.rs).

use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::receiver::{Happened, Offer};
use crate::sys;

/// How long a question waits for its answer: a little less than a sender does.
const ANSWER_WITHIN: Duration = Duration::from_secs(55);
/// A watcher that takes no line for this long is let go.
const WATCHER_TAKES_WITHIN: Duration = Duration::from_millis(200);
const MOST_CLIENTS: usize = 16;

#[derive(Debug, Clone, PartialEq)]
pub enum Stage {
    Waiting {
        seen: bool,
    },
    Asked {
        id: String,
        offer: Offer,
        icon: Option<PathBuf>,
    },
    Receiving {
        offer: Offer,
        bytes: u64,
    },
    Received {
        sender: String,
        paths: Vec<PathBuf>,
        bytes: u64,
        seconds: f64,
    },
    Links {
        sender: String,
        links: Vec<String>,
    },
    Declined {
        sender: String,
    },
    Failed {
        why: String,
    },
}

use crate::meet::GOING_OFF;
pub(crate) use crate::meet::{quoted, size};

pub(crate) fn list(items: impl Iterator<Item = String>) -> String {
    format!("[{}]", items.collect::<Vec<_>>().join(","))
}

fn files(offer: &Offer) -> String {
    list(
        offer
            .files
            .iter()
            .map(|(name, bytes)| format!(r#"{{"name":{},"bytes":{bytes}}}"#, quoted(name))),
    )
}

/// What is offered, in a few words: a file by its name, more by their number.
pub fn offered(offer: &Offer) -> String {
    match (offer.files.len(), offer.links.len()) {
        (0, 1) => "a link".into(),
        (0, links) => format!("{links} links"),
        (1, _) => format!("{} ({})", offer.files[0].0, size(offer.bytes)),
        (files, _) => format!("{files} files ({})", size(offer.bytes)),
    }
}

fn someone(sender: &str) -> &str {
    if sender.is_empty() {
        "Somebody"
    } else {
        sender
    }
}

impl Stage {
    fn json(&self, name: &str, ends: u64) -> String {
        match self {
            Stage::Waiting { seen } => format!(
                r#"{{"state":"waiting","name":{},"seen":{seen},"ends":{ends}}}"#,
                quoted(name)
            ),
            Stage::Asked { id, offer, icon } => format!(
                r#"{{"state":"asked","id":{},"sender":{},"files":{},"bytes":{},"links":{},"icon":{}}}"#,
                quoted(id),
                quoted(&offer.sender),
                files(offer),
                offer.bytes,
                list(offer.links.iter().map(|link| quoted(link))),
                quoted(
                    &icon
                        .as_deref()
                        .map(Path::to_string_lossy)
                        .unwrap_or_default()
                )
            ),
            Stage::Receiving { offer, bytes } => format!(
                r#"{{"state":"receiving","sender":{},"files":{},"received":{bytes},"bytes":{}}}"#,
                quoted(&offer.sender),
                files(offer),
                offer.bytes
            ),
            Stage::Received {
                sender,
                paths,
                bytes,
                seconds,
            } => format!(
                r#"{{"state":"received","sender":{},"paths":{},"bytes":{bytes},"seconds":{seconds:.2}}}"#,
                quoted(sender),
                list(paths.iter().map(|path| quoted(&path.to_string_lossy())))
            ),
            Stage::Links { sender, links } => format!(
                r#"{{"state":"links","sender":{},"links":{}}}"#,
                quoted(sender),
                list(links.iter().map(|link| quoted(link)))
            ),
            Stage::Declined { sender } => {
                format!(r#"{{"state":"declined","sender":{}}}"#, quoted(sender))
            }
            Stage::Failed { why } => format!(r#"{{"state":"failed","why":{}}}"#, quoted(why)),
        }
    }

    /// The same for a person, in a line.
    fn words(&self, name: &str) -> String {
        match self {
            Stage::Waiting { seen: false } => {
                format!("AirDrop is on: iPhones nearby can send to {name}. The Wi-Fi is off until it ends.")
            }
            Stage::Waiting { seen: true } => {
                format!("AirDrop is on: an iPhone has {name} in its list. The Wi-Fi is off until it ends.")
            }
            Stage::Asked { offer, .. } => format!(
                "{} wants to send {}: nova airdrop accept, or decline.",
                someone(&offer.sender),
                offered(offer)
            ),
            Stage::Receiving { offer, bytes } => format!(
                "Receiving {} from {}: {} so far.",
                offered(offer),
                someone(&offer.sender),
                size(*bytes)
            ),
            Stage::Received {
                sender,
                paths,
                bytes,
                seconds,
            } => format!(
                "Received from {}: {} ({}, {seconds:.1} s).",
                someone(sender),
                paths
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", "),
                size(*bytes)
            ),
            Stage::Links { sender, links } => {
                format!("{} sent: {}", someone(sender), links.join(" "))
            }
            Stage::Declined { sender } => format!("Declined what {} offered.", someone(sender)),
            Stage::Failed { why } => format!("AirDrop did not finish. {why}"),
        }
    }

    /// A question open or a transfer under way: not the time to give up, or to take another.
    fn busy(&self) -> bool {
        matches!(self, Stage::Asked { .. } | Stage::Receiving { .. })
    }
}

/// Who holds AirDrop on, besides a send.
#[derive(Default)]
struct Holds {
    /// The user's on (`hold`): until a transfer to this computer is over.
    user: bool,
    /// The doorbell's (`stay`, until `unstay`).
    stays: bool,
    /// How many times it has been taken hold of (`hold`, `stay`, a send): one that has let go
    /// again before the daemon's loop looked still counts.
    claims: u64,
    /// It has decided to end: nobody takes hold of it any more.
    closing: bool,
}

/// Who holds AirDrop on, as the daemon's end is decided by it.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Held {
    /// The user's on, or the doorbell's stay.
    pub held: bool,
    /// A send is going on, and its client is there.
    pub sending: bool,
    /// How many times it has been taken hold of.
    pub claims: u64,
}

struct Inner {
    stage: Stage,
    /// The receiver's number for the question the stage is about, while it is about one: what
    /// another sender's connection comes to meanwhile is not this one's business.
    owner: Option<u64>,
    /// The line the watchers were last told.
    told: String,
    /// When the daemon gives up by itself, in Unix seconds; 0 for never.
    ends: u64,
    watchers: Vec<(usize, UnixStream)>,
    /// The answer to the question with this id.
    answer: Option<(String, bool)>,
}

pub struct Control {
    name: String,
    /// The socket's, once there is one.
    path: OnceLock<PathBuf>,
    inner: Mutex<Inner>,
    answered: Condvar,
    holds: Mutex<Holds>,
    sends: OnceLock<Sends>,
}

/// Where a client that asks to send is handed (send.rs): `prepare` looks at the files it passed
/// (the send, ready, or why not), and `on` says whether a send is going on.
pub struct Sends {
    pub prepare: Box<Prepare>,
    pub on: Box<dyn Fn() -> bool + Send + Sync>,
}

/// The files, and whether the last of them is the picture for the offer.
type Prepare = dyn Fn(Vec<OwnedFd>, bool) -> Result<Box<dyn Ready>, String> + Send + Sync;

/// A send whose files have been looked at.
pub trait Ready {
    /// Taken as the send going on, or why not: quick, as nothing else is, as it is done while the
    /// daemon cannot decide to end.
    fn claim(&mut self) -> Result<(), String>;
    /// Started on its client's connection, once claimed; why not, with the claim let go.
    fn start(self: Box<Self>, stream: UnixStream) -> Result<(), String>;
}

impl Control {
    /// How things stand, with nobody told yet: for a daemon nobody can ask, and before `listen`.
    pub fn new(name: &str) -> Arc<Control> {
        Arc::new(Control {
            name: name.to_owned(),
            path: OnceLock::new(),
            inner: Mutex::new(Inner {
                stage: Stage::Waiting { seen: false },
                owner: None,
                told: String::new(),
                ends: 0,
                watchers: Vec::new(),
                answer: None,
            }),
            answered: Condvar::new(),
            holds: Mutex::default(),
            sends: OnceLock::new(),
        })
    }

    /// Clients that ask to send are handed to `sends` (send.rs).
    pub fn on_send(&self, sends: Sends) {
        let _ = self.sends.set(sends);
    }

    fn sending(&self) -> bool {
        self.sends.get().is_some_and(|sends| (sends.on)())
    }

    /// Opens the socket and starts answering on it. A socket left by a daemon that died is taken
    /// over; one a living daemon answers on is that daemon's.
    pub fn listen(self: &Arc<Self>, path: &Path) -> Result<(), String> {
        let said = |error: std::io::Error| format!("{}: {error}", path.display());
        if UnixStream::connect(path).is_ok() {
            return Err("AirDrop is already running for this user".into());
        }
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path).map_err(said)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(said)?;
        let _ = self.path.set(path.to_owned());
        let serving = self.clone();
        std::thread::Builder::new()
            .name("airdrop-control".into())
            .spawn(move || serving.serve(listener))
            .map_err(said)?;
        Ok(())
    }

    fn serve(self: Arc<Self>, listener: UnixListener) {
        let open = Arc::new(AtomicUsize::new(0));
        let mut number = 0usize;
        for stream in listener.incoming() {
            let Ok(stream) = stream else { continue };
            if open.fetch_add(1, Ordering::SeqCst) >= MOST_CLIENTS {
                open.fetch_sub(1, Ordering::SeqCst);
                continue;
            }
            number += 1;
            let (control, counted, number) = (self.clone(), open.clone(), number);
            let client = std::thread::Builder::new().name("airdrop-client".into());
            let started = client.spawn(move || {
                control.client(stream, number);
                counted.fetch_sub(1, Ordering::SeqCst);
            });
            // One this computer cannot give a thread to is let go unanswered, as one over the most.
            if started.is_err() {
                open.fetch_sub(1, Ordering::SeqCst);
            }
        }
    }

    /// One client, until it has its answer, or for a watcher until it goes.
    fn client(&self, stream: UnixStream, number: usize) {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let _ = stream.set_write_timeout(Some(WATCHER_TAKES_WITHIN));
        let Ok(mut out) = stream.try_clone() else {
            return;
        };
        // The first words as they came, with what was passed with them: files, for `send`.
        let mut first = vec![0u8; 4096];
        let Ok((size, files)) = crate::meet::receive_with_files(stream.as_raw_fd(), &mut first)
        else {
            return;
        };
        first.truncate(size);
        let words = first.strip_suffix(b"\n").unwrap_or(&first).trim_ascii();
        let icon = match words {
            b"send" => Some(false),
            b"send icon" => Some(true),
            _ => None,
        };
        if let Some(icon) = icon {
            let refused = match self.sends.get() {
                None => "This AirDrop does not send.".into(),
                // The files are looked at first, with no lock held: one on a mount that went with
                // the Wi-Fi may take its time, and the daemon's loop waits for nothing of the sort.
                Some(sends) => match (sends.prepare)(files, icon) {
                    Err(why) => why,
                    Ok(mut send) => {
                        // Claimed with the holds' lock held, and nothing else done under it: the
                        // daemon does not decide to end in the middle of it, and one that has
                        // decided takes no send.
                        let claimed = {
                            let mut holds = self.holds.lock().unwrap();
                            (!holds.closing && !sys::stopping()).then(|| {
                                let claimed = send.claim();
                                holds.claims += u64::from(claimed.is_ok());
                                claimed
                            })
                        };
                        match claimed {
                            None => {
                                let _ = writeln!(out, r#"{{"state":"closing"}}"#);
                                return;
                            }
                            Some(Err(why)) => why,
                            Some(Ok(())) => match send.start(stream) {
                                Ok(()) => return,
                                Err(why) => why,
                            },
                        }
                    }
                },
            };
            let _ = writeln!(out, r#"{{"state":"failed","why":{}}}"#, quoted(&refused));
            return;
        }
        drop(files);
        let mut lines =
            BufReader::new(std::io::Cursor::new(first).chain(stream.take(4096))).lines();
        let mut watching = false;
        while let Some(Ok(line)) = lines.next() {
            let mut words = line.split_whitespace();
            let answer = match (words.next().unwrap_or(""), words.next()) {
                ("watch", None) if !watching => {
                    let Ok(watcher) = out.try_clone() else { return };
                    let mut inner = self.inner.lock().unwrap();
                    let line = inner.stage.json(&self.name, inner.ends);
                    if writeln!(out, "{line}").is_err() {
                        return;
                    }
                    inner.watchers.push((number, watcher));
                    watching = true;
                    // A watcher says something when it wants something, which may be never.
                    let _ = out.set_read_timeout(None);
                    continue;
                }
                ("status", None) => {
                    let inner = self.inner.lock().unwrap();
                    inner.stage.words(&self.name)
                }
                ("accept", id) => self.answer(id, true),
                ("decline", id) => self.answer(id, false),
                ("hold", None) => self.hold(false),
                ("stay", None) => self.hold(true),
                ("unstay", None) => self.unstay(),
                ("stop", None) => self.stop(),
                _ => "not understood: watch, status, accept, decline, hold, stay, unstay, stop or \
                      send"
                    .into(),
            };
            if !watching {
                let _ = writeln!(out, "{answer}");
                return;
            }
        }
        if watching {
            let mut inner = self.inner.lock().unwrap();
            inner.watchers.retain(|(watcher, _)| *watcher != number);
        }
    }

    /// The user (`hold`) or the doorbell (`stay`) holds AirDrop on.
    fn hold(&self, stay: bool) -> String {
        let mut holds = self.holds.lock().unwrap();
        if holds.closing || sys::stopping() {
            return GOING_OFF.into();
        }
        if stay {
            holds.stays = true;
        } else {
            holds.user = true;
        }
        holds.claims += 1;
        "ok".into()
    }

    /// The doorbell lets go: AirDrop ends a moment later if nothing else holds it (main.rs).
    fn unstay(&self) -> String {
        self.holds.lock().unwrap().stays = false;
        "ok".into()
    }

    /// The user's off: the daemon ends at its loop's next turn, whatever holds it, and a send
    /// going on ends with it.
    fn stop(&self) -> String {
        *self.holds.lock().unwrap() = Holds {
            closing: true,
            ..Holds::default()
        };
        "ok".into()
    }

    /// It has decided to end.
    pub fn closing(&self) -> bool {
        self.holds.lock().unwrap().closing
    }

    /// The user's on, or the doorbell's stay, holds AirDrop on.
    pub fn held(&self) -> bool {
        let holds = self.holds.lock().unwrap();
        holds.user || holds.stays
    }

    /// A transfer to this computer is over, whichever way: what the user switched AirDrop on for.
    pub fn used(&self) {
        self.holds.lock().unwrap().user = false;
    }

    /// Whether the daemon ends now, as `ends` decides given who holds it: decided with nobody
    /// taking hold of it meanwhile, and once decided, nobody can.
    pub fn close_if(&self, ends: impl FnOnce(Held) -> bool) -> bool {
        let mut holds = self.holds.lock().unwrap();
        if !holds.closing {
            holds.closing = ends(Held {
                held: holds.user || holds.stays,
                sending: self.sending(),
                claims: holds.claims,
            });
        }
        holds.closing
    }

    fn answer(&self, id: Option<&str>, yes: bool) -> String {
        let mut inner = self.inner.lock().unwrap();
        let Stage::Asked { id: open, .. } = &inner.stage else {
            return "nothing is being asked".into();
        };
        if id.is_some_and(|id| id != open) {
            return "that question is over".into();
        }
        inner.answer = Some((open.clone(), yes));
        self.answered.notify_all();
        "ok".into()
    }

    /// Makes this the state of things, and tells the watchers. One that does not take the line in
    /// time is let go: the daemon waits for nobody.
    fn set(&self, inner: &mut Inner, stage: Stage) {
        inner.stage = stage;
        let line = inner.stage.json(&self.name, inner.ends);
        if line == inner.told {
            return;
        }
        inner
            .watchers
            .retain_mut(|(_, watcher)| writeln!(watcher, "{line}").is_ok());
        inner.told = line;
    }

    /// When the daemon will give up if nobody asks, for those who show a countdown.
    pub fn ends(&self, at: u64) {
        let mut inner = self.inner.lock().unwrap();
        inner.ends = at;
        // Told again as it is, if the line carries the time.
        let stage = inner.stage.clone();
        self.set(&mut inner, stage);
    }

    pub fn busy(&self) -> bool {
        self.inner.lock().unwrap().stage.busy()
    }

    /// Puts an offer to the user and waits for the answer: no, if none comes in time, if the daemon
    /// is stopping, or if another offer is open. `question` is the receiver's number for it, which
    /// what happens to it afterwards is told under. `unasked` is yes without the question.
    pub fn ask(&self, question: u64, offer: &Offer, unasked: bool) -> bool {
        let mut inner = self.inner.lock().unwrap();
        if inner.stage.busy() {
            return false;
        }
        let id = format!("{:x}-{question}", std::process::id());
        let icon = if unasked { None } else { self.icon(&id, offer) };
        inner.answer = None;
        inner.owner = Some(question);
        self.set(
            &mut inner,
            Stage::Asked {
                id: id.clone(),
                offer: offer.clone(),
                icon: icon.clone(),
            },
        );
        let asked = Instant::now();
        let yes = loop {
            if unasked {
                break true;
            }
            if let Some((answered, yes)) = inner.answer.take() {
                if answered == id {
                    break yes;
                }
            }
            let left = ANSWER_WITHIN.saturating_sub(asked.elapsed());
            if left.is_zero() || sys::stopping() {
                break false;
            }
            // Not for longer than a moment at a time: stopping is not something this is told of.
            inner = self
                .answered
                .wait_timeout(inner, left.min(Duration::from_millis(200)))
                .unwrap()
                .0;
        };
        if let Some(icon) = &icon {
            let _ = std::fs::remove_file(icon);
        }
        if yes && !offer.files.is_empty() {
            self.set(
                &mut inner,
                Stage::Receiving {
                    offer: offer.clone(),
                    bytes: 0,
                },
            );
        }
        yes
    }

    /// The sender's picture of what it offers, put beside the socket while it is asked, for whoever
    /// shows the offer: the user's alone, as the folder is. None without a picture or a socket.
    fn icon(&self, id: &str, offer: &Offer) -> Option<PathBuf> {
        let icon = offer.icon.as_deref()?;
        let path = self
            .path
            .get()?
            .parent()?
            .join(format!("airdrop-offer-{id}"));
        let written = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)
            .and_then(|mut file| file.write_all(icon));
        if written.is_err() {
            let _ = std::fs::remove_file(&path);
            return None;
        }
        Some(path)
    }

    /// What the receiver says happened, as far as it is about the question the stage is about:
    /// several senders can be talking at once, and one's end is not another's. True when it was
    /// the end of that question, whichever way.
    pub fn happened(&self, happened: &Happened) -> bool {
        let mut inner = self.inner.lock().unwrap();
        let ours = |question: &u64| inner.owner == Some(*question);
        let open = match &inner.stage {
            Stage::Asked { offer, .. } | Stage::Receiving { offer, .. } => Some(offer),
            _ => None,
        };
        let (next, over) = match (happened, &inner.stage, open) {
            (Happened::Listed, Stage::Waiting { seen: false }, _) => {
                (Stage::Waiting { seen: true }, false)
            }
            (
                Happened::Receiving {
                    question, bytes, ..
                },
                Stage::Receiving { offer, .. },
                _,
            ) if ours(question) => (
                Stage::Receiving {
                    offer: offer.clone(),
                    bytes: *bytes,
                },
                false,
            ),
            (
                Happened::Received {
                    question,
                    paths,
                    bytes,
                    seconds,
                },
                _,
                Some(offer),
            ) if ours(question) => (
                Stage::Received {
                    sender: offer.sender.clone(),
                    paths: paths.clone(),
                    bytes: *bytes,
                    seconds: *seconds,
                },
                true,
            ),
            (Happened::Links { question, links }, _, Some(offer)) if ours(question) => (
                Stage::Links {
                    sender: offer.sender.clone(),
                    links: links.clone(),
                },
                true,
            ),
            (Happened::Declined { question, offer }, _, Some(_)) if ours(question) => (
                Stage::Declined {
                    sender: offer.sender.clone(),
                },
                true,
            ),
            // In words for whoever was waiting for a photo: what went wrong on the wire is in the log.
            (
                Happened::Failed {
                    question: Some(question),
                    ..
                },
                stage,
                Some(offer),
            ) if ours(question) => (
                Stage::Failed {
                    why: match stage {
                        Stage::Receiving { .. } => format!(
                            "The transfer from {} stopped before it was complete. Nothing was kept.",
                            someone(&offer.sender)
                        ),
                        _ => format!(
                            "What {} offered could not be received.",
                            someone(&offer.sender)
                        ),
                    },
                },
                true,
            ),
            _ => return false,
        };
        if over {
            inner.owner = None;
        }
        self.set(&mut inner, next);
        over
    }

    /// Nobody is asking any more: back to waiting, for a daemon that stays on after a transfer.
    pub fn waiting(&self) {
        let mut inner = self.inner.lock().unwrap();
        if !inner.stage.busy() {
            self.set(&mut inner, Stage::Waiting { seen: true });
        }
    }
}

/// Takes the socket's file away, at the end of the daemon: nobody is told anything after that.
pub fn close(control: &Control) {
    if let Some(path) = control.path.get() {
        let _ = std::fs::remove_file(path);
    }
}

/// Reads one line from a client's side, for the tests.
#[cfg(test)]
fn line(stream: &mut impl Read) -> String {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    while stream.read(&mut byte).unwrap_or(0) == 1 && byte[0] != b'\n' {
        line.push(byte[0]);
    }
    String::from_utf8(line).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn offer() -> Offer {
        Offer {
            sender: "Zoë's \"phone\"".into(),
            files: vec![("IMG_0001.HEIC".into(), 1_044_468)],
            bytes: 1_044_468,
            links: Vec::new(),
            icon: None,
        }
    }

    fn socket(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("nova-airdrop-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        folder.join(name)
    }

    fn say(path: &Path, what: &str) -> String {
        let mut stream = UnixStream::connect(path).unwrap();
        writeln!(stream, "{what}").unwrap();
        line(&mut stream)
    }

    #[test]
    fn what_a_sender_calls_itself_cannot_break_out_of_its_string() {
        assert_eq!(quoted("a\"b\\c\nd\u{1}"), r#""a\"b\\c\nd\u0001""#);
        let stage = Stage::Asked {
            id: "1-1".into(),
            offer: offer(),
            icon: None,
        };
        assert_eq!(
            stage.json("Nova", 0),
            r#"{"state":"asked","id":"1-1","sender":"Zoë's \"phone\"","files":[{"name":"IMG_0001.HEIC","bytes":1044468}],"bytes":1044468,"links":[],"icon":""}"#
        );
        assert_eq!(
            Stage::Waiting { seen: true }.json("Nova", 7),
            r#"{"state":"waiting","name":"Nova","seen":true,"ends":7}"#
        );
    }

    #[test]
    fn sizes_and_offers_are_said_as_people_say_them() {
        assert_eq!(
            (
                size(512),
                size(20_480),
                size(1_044_468),
                size(3_200_000_000)
            ),
            (
                "512 bytes".into(),
                "20 kB".into(),
                "1.0 MB".into(),
                "3.20 GB".into()
            )
        );
        assert_eq!(offered(&offer()), "IMG_0001.HEIC (1.0 MB)");
        let mut several = offer();
        several.files.push(("b".into(), 1));
        assert_eq!(offered(&several), "2 files (1.0 MB)");
        several.files.clear();
        several.links = vec!["https://example.org/".into()];
        assert_eq!(offered(&several), "a link");
    }

    #[test]
    fn a_client_that_asks_to_send_is_handed_over_with_its_files() {
        let path = socket("sends");
        let control = Control::new("Nova");
        control.listen(&path).unwrap();
        let file = std::fs::File::open("/proc/self/stat").unwrap();
        let send = |words: &[u8]| {
            let stream = UnixStream::connect(&path).unwrap();
            crate::meet::send_with_files(
                stream.as_raw_fd(),
                words,
                &[file.as_raw_fd(), file.as_raw_fd()],
            );
            stream
        };
        // Nothing to hand it to: said so, in the send's own words.
        assert_eq!(
            line(&mut send(b"send\n")),
            r#"{"state":"failed","why":"This AirDrop does not send."}"#
        );
        struct Handed {
            files: usize,
            handed: std::sync::mpsc::Sender<usize>,
        }
        impl Ready for Handed {
            fn claim(&mut self) -> Result<(), String> {
                match self.files {
                    3 => Err("Taken.".into()),
                    _ => Ok(()),
                }
            }
            fn start(self: Box<Self>, mut stream: UnixStream) -> Result<(), String> {
                writeln!(stream, "handed {} files", self.files).unwrap();
                self.handed.send(self.files).unwrap();
                Ok(())
            }
        }
        let (handed, taken) = std::sync::mpsc::channel();
        control.on_send(Sends {
            prepare: Box::new(move |files, _| {
                if files.len() == 1 {
                    return Err("One is not enough.".into());
                }
                // Files that take their time to look at, as on a mount that has gone away.
                if files.len() == 4 {
                    std::thread::sleep(Duration::from_millis(600));
                }
                Ok(Box::new(Handed {
                    files: files.len(),
                    handed: handed.clone(),
                }))
            }),
            on: Box::new(|| false),
        });
        let claims = || {
            let mut seen = 0;
            assert!(!control.close_if(|held| {
                seen = held.claims;
                false
            }));
            seen
        };
        assert_eq!(line(&mut send(b"send\n")), "handed 2 files");
        assert_eq!(taken.recv().unwrap(), 2);
        // Taking hold of AirDrop, however short: the daemon's loop knows it was held.
        assert_eq!(claims(), 1);
        let mut one = UnixStream::connect(&path).unwrap();
        crate::meet::send_with_files(one.as_raw_fd(), b"send\n", &[file.as_raw_fd()]);
        assert_eq!(
            line(&mut one),
            r#"{"state":"failed","why":"One is not enough."}"#
        );
        // One whose claim is refused (another send going on) is told why.
        let mut three = UnixStream::connect(&path).unwrap();
        crate::meet::send_with_files(
            three.as_raw_fd(),
            b"send\n",
            &[file.as_raw_fd(), file.as_raw_fd(), file.as_raw_fd()],
        );
        assert_eq!(line(&mut three), r#"{"state":"failed","why":"Taken."}"#);
        assert_eq!(claims(), 1);
        // They are looked at with no lock held: the daemon's loop is not kept waiting meanwhile.
        let fd = file.as_raw_fd();
        let slow = {
            let path = path.clone();
            std::thread::spawn(move || {
                let mut four = UnixStream::connect(&path).unwrap();
                crate::meet::send_with_files(four.as_raw_fd(), b"send\n", &[fd, fd, fd, fd]);
                line(&mut four)
            })
        };
        std::thread::sleep(Duration::from_millis(150));
        let began = Instant::now();
        assert!(!control.close_if(|_| false));
        assert!(
            began.elapsed() < Duration::from_millis(100),
            "{:?}",
            began.elapsed()
        );
        assert_eq!(slow.join().unwrap(), "handed 4 files");
        assert_eq!(taken.recv().unwrap(), 4);
        // Files passed with anything else are let go, and the words answered as ever.
        assert!(line(&mut send(b"status\n")).starts_with("AirDrop is on"));
        // A daemon that has decided to end starts no send, and says so in a line of its own.
        assert!(control.close_if(|_| true));
        assert_eq!(line(&mut send(b"send\n")), r#"{"state":"closing"}"#);
        close(&control);
    }

    #[test]
    fn airdrop_is_held_on_by_whoever_asked_and_ends_when_the_last_lets_go() {
        let path = socket("holds");
        let control = Control::new("Nova");
        control.listen(&path).unwrap();
        let sending = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let on = sending.clone();
        control.on_send(Sends {
            prepare: Box::new(|_, _| Err("not in this test".into())),
            on: Box::new(move || on.load(Ordering::SeqCst)),
        });
        let held = || {
            let mut seen = Held::default();
            assert!(!control.close_if(|held| {
                seen = held;
                false
            }));
            seen
        };
        assert_eq!(held(), Held::default());
        // The user's on holds it until a transfer to this computer is over.
        assert_eq!(say(&path, "hold"), "ok");
        assert!(control.held() && held().held && held().claims == 1);
        control.used();
        assert!(!control.held());
        // The doorbell's stay, until it lets go; a transfer is not the end of it.
        assert_eq!(say(&path, "stay"), "ok");
        control.used();
        assert!(control.held());
        assert_eq!(say(&path, "unstay"), "ok");
        assert!(!control.held());
        // Its letting go is its own: the user's on, and a send, go on holding it.
        sending.store(true, Ordering::SeqCst);
        assert_eq!(say(&path, "hold"), "ok");
        assert_eq!(say(&path, "stay"), "ok");
        assert_eq!(say(&path, "unstay"), "ok");
        assert_eq!(
            held(),
            Held {
                held: true,
                sending: true,
                claims: 4
            }
        );
        // The user's stop: decided at once, whatever holds it, and it stays decided; nobody takes
        // hold of it any more.
        assert!(!control.closing());
        assert_eq!(say(&path, "stop"), "ok");
        assert!(control.closing() && control.close_if(|_| false));
        assert!(!control.held());
        assert_eq!(say(&path, "hold"), GOING_OFF);
        assert_eq!(say(&path, "stay"), GOING_OFF);
        assert_eq!(say(&path, "unstay"), "ok");
        close(&control);
    }

    #[test]
    fn a_watcher_is_told_each_change_and_a_question_waits_for_its_answer() {
        let path = socket("asks");
        let control = Control::new("Nova");
        control.listen(&path).unwrap();
        assert!(Control::new("Nova").listen(&path).is_err());
        assert!(say(&path, "status").starts_with("AirDrop is on: iPhones nearby"));
        assert_eq!(say(&path, "accept"), "nothing is being asked");
        assert!(say(&path, "dance").starts_with("not understood"));

        let mut watcher = UnixStream::connect(&path).unwrap();
        writeln!(watcher, "watch").unwrap();
        assert!(line(&mut watcher).starts_with(r#"{"state":"waiting","name":"Nova","seen":false"#));
        assert!(!control.happened(&Happened::Listed));
        assert!(line(&mut watcher).contains(r#""seen":true"#));

        // With the sender's picture, which is beside the socket while it is asked.
        let pictured = Offer {
            icon: Some(Arc::from(&b"\xff\xd8\xffpicture"[..])),
            ..offer()
        };
        let asking = {
            let control = control.clone();
            std::thread::spawn(move || control.ask(1, &pictured, false))
        };
        let asked = line(&mut watcher);
        assert!(asked.starts_with(r#"{"state":"asked","id":""#), "{asked}");
        let id = asked.split('"').nth(7).unwrap().to_owned();
        assert!(id.ends_with("-1"));
        let icon = path.with_file_name(format!("airdrop-offer-{id}"));
        assert!(
            asked.ends_with(&format!(r#""icon":"{}"}}"#, icon.display())),
            "{asked}"
        );
        assert_eq!(std::fs::read(&icon).unwrap(), b"\xff\xd8\xffpicture");
        let mode = std::fs::metadata(&icon).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert!(control.busy());
        // A second sender meanwhile is told no, and an answer to another question is not this one's.
        assert!(!control.ask(2, &offer(), false));
        assert_eq!(say(&path, "accept 0-0"), "that question is over");
        assert!(say(&path, "status").contains("wants to send IMG_0001.HEIC (1.0 MB)"));
        assert_eq!(say(&path, &format!("accept {id}")), "ok");
        assert!(asking.join().unwrap());
        assert!(line(&mut watcher).starts_with(r#"{"state":"receiving""#));
        assert!(!icon.exists());

        // What becomes of the second sender's connection, and of a stranger's that was never told
        // yes, is not this transfer's business.
        assert!(!control.happened(&Happened::Declined {
            question: 2,
            offer: offer()
        }));
        assert!(!control.happened(&Happened::Failed {
            question: None,
            why: "an upload nobody was asked about".into()
        }));
        assert!(!control.happened(&Happened::Failed {
            question: Some(2),
            why: "x".into()
        }));
        assert!(!control.happened(&Happened::Received {
            question: 2,
            paths: Vec::new(),
            bytes: 0,
            seconds: 0.0
        }));
        assert!(control.busy());

        assert!(!control.happened(&Happened::Receiving {
            question: 1,
            bytes: 500_000,
            of: 1_044_468,
        }));
        assert!(line(&mut watcher).contains(r#""received":500000,"bytes":1044468"#));
        assert!(control.happened(&Happened::Received {
            question: 1,
            paths: vec!["/home/zoe/Downloads/IMG_0001.HEIC".into()],
            bytes: 1_044_468,
            seconds: 2.25,
        }));
        assert_eq!(
            line(&mut watcher),
            r#"{"state":"received","sender":"Zoë's \"phone\"","paths":["/home/zoe/Downloads/IMG_0001.HEIC"],"bytes":1044468,"seconds":2.25}"#
        );
        assert!(!control.busy());

        // A watcher can answer too; and a no is a no.
        let asking = {
            let control = control.clone();
            std::thread::spawn(move || control.ask(3, &offer(), false))
        };
        assert!(line(&mut watcher).starts_with(r#"{"state":"asked""#));
        writeln!(watcher, "decline").unwrap();
        assert!(!asking.join().unwrap());
        assert!(control.happened(&Happened::Declined {
            question: 3,
            offer: offer()
        }));
        assert!(line(&mut watcher).starts_with(r#"{"state":"declined""#));

        // Without the question, for a daemon told to take everything.
        assert!(control.ask(4, &offer(), true));
        assert!(line(&mut watcher).starts_with(r#"{"state":"asked""#));
        assert!(line(&mut watcher).starts_with(r#"{"state":"receiving""#));
        assert!(control.happened(&Happened::Failed {
            question: Some(4),
            why: "the upload ended early".into()
        }));
        assert_eq!(
            line(&mut watcher),
            r#"{"state":"failed","why":"The transfer from Zoë's \"phone\" stopped before it was complete. Nothing was kept."}"#
        );
        // A failure with nothing under way changes nothing.
        assert!(!control.happened(&Happened::Failed {
            question: Some(4),
            why: "again".into()
        }));
        control.ends(99);
        control.waiting();
        assert!(
            line(&mut watcher).contains(r#""state":"waiting","name":"Nova","seen":true,"ends":99"#)
        );

        // Links are in the question itself: yes is the end of it.
        let links = Offer {
            sender: "Zoë".into(),
            files: Vec::new(),
            bytes: 0,
            links: vec!["https://example.org/".into()],
            icon: None,
        };
        assert!(control.ask(5, &links, true));
        assert!(line(&mut watcher).starts_with(r#"{"state":"asked""#));
        assert!(control.happened(&Happened::Links {
            question: 5,
            links: links.links.clone()
        }));
        assert_eq!(
            line(&mut watcher),
            r#"{"state":"links","sender":"Zoë","links":["https://example.org/"]}"#
        );

        close(&control);
        assert!(!path.exists());
    }
}
