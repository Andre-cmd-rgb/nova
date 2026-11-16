//! A send: from the files the user handed over to the receiver they picked.
//!
//! `nova airdrop send` passes the files open over the control socket (so
//! this reads what the user could, wherever it is) and the session is that
//! client's from then on: it is told, a line of JSON at each change, who can
//! be sent to, and then how the sending goes; it says which receiver, or to
//! stop. Its going away stops it too. One send at a time.
//!
//! Meanwhile Bluetooth announces that this computer wants to send
//! (wake.rs), which is what wakes an iPhone's AirDrop; the node asks on the
//! air who receives (node.rs), and each receiver it hears of is asked who it
//! is (/Discover, sender.rs), and listed. Picked, it is asked whether its
//! person wants the files (/Ask), and sent them (/Upload).
//!
//! The lines all have a `state`, and with it:
//!
//!   looking    `receivers` (each an `id`, its `name`, `model`, and `accepts`:
//!              false for one that takes AirDrop from its contacts only),
//!              `bluetooth` (why it cannot wake an iPhone; "" while it does)
//!   asking     `to`: waiting for the person there to decide
//!   sending    `to`, `sent`, `bytes`
//!   sent       `to`, `bytes`, `seconds`
//!   declined   `to`
//!   failed     `why`, a sentence for the user
//!   nobody     AirDrop ended with nobody to send to; `refused`, the names of
//!              those that take AirDrop from their contacts only
//!   cancelled
//!
//! The client says `to <id>` or `cancel`.

use std::io::{BufRead, BufReader, Write};
use std::net::{Shutdown, SocketAddr, SocketAddrV6};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, UNIX_EPOCH};

use crate::control::{list, quoted};
use crate::pack::{self, Item, Pack};
use crate::packet;
use crate::sender::{Answer, Listing, Sender};
use crate::sys;
use crate::wake::Wake;
use crate::wire::Mac;

/// The most files one send takes.
pub const MOST_FILES: usize = 200;
/// How often a receiver that would not say who it is is asked again, at the most, and one that
/// takes AirDrop from its contacts only: its owner may be switching it to Everyone.
const RETRY_AT_MOST: Duration = Duration::from_secs(10);
const ASK_AGAIN: Duration = Duration::from_secs(5);
/// How often the progress is told.
const PROGRESS_EVERY: Duration = Duration::from_millis(250);
/// The most receivers a send keeps, and of one peer: a phone has one, and what changes its
/// instance on the air takes no more room than two.
const MOST_RECEIVERS: usize = 16;
const MOST_PER_PEER: usize = 2;

/// A receiver the node heard of: whose it is on the air, its instance, and where it listens.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub peer: Mac,
    pub instance: String,
    pub at: SocketAddr,
    /// What its requests' Host says.
    pub host: String,
}

/// What a send tells the daemon, for its log and its end.
#[derive(Debug, Clone, PartialEq)]
pub enum Told {
    Began,
    /// Over; `transfer` if a receiver was asked, which ends a daemon that ends after a transfer.
    Ended {
        transfer: bool,
    },
    Log(String),
}

#[derive(Default)]
struct Inner {
    /// A send is going on.
    on: bool,
    /// It looks for receivers: the node asks who receives.
    browsing: bool,
    /// A receiver is being asked or sent to: not the time for the daemon to give up.
    busy: bool,
    found: Vec<Found>,
    gone: Vec<Mac>,
}

pub struct Sending {
    sender: Sender,
    /// awdl0's number: the scope of a receiver's link-local address.
    scope: u32,
    wake: Mutex<Result<Wake, String>>,
    inner: Mutex<Inner>,
    tell: Box<dyn Fn(Told) + Send + Sync>,
}

#[derive(Clone)]
struct Candidate {
    id: usize,
    found: Found,
    listing: Option<Listing>,
    trying: bool,
    next: Instant,
    failures: u32,
}

/// The client of a send: what it says comes in on a thread of its own.
struct Client {
    out: Mutex<UnixStream>,
    picks: mpsc::Receiver<String>,
    gone: Arc<AtomicBool>,
}

impl Client {
    fn new(stream: UnixStream) -> Option<Client> {
        let _ = stream.set_read_timeout(None);
        let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
        let reading = stream.try_clone().ok()?;
        let (said, picks) = mpsc::channel();
        let gone = Arc::new(AtomicBool::new(false));
        let going = gone.clone();
        let reader = std::thread::Builder::new().name("airdrop-client".into());
        let started = reader.spawn(move || {
            for line in BufReader::new(reading).lines() {
                let Ok(line) = line else { break };
                match line.split_whitespace().collect::<Vec<_>>().as_slice() {
                    ["cancel"] => break,
                    ["to", id] => {
                        let _ = said.send(id.to_string());
                    }
                    _ => {}
                }
            }
            going.store(true, Ordering::SeqCst);
        });
        started.ok()?;
        Some(Client {
            out: Mutex::new(stream),
            picks,
            gone,
        })
    }

    fn say(&self, line: &str) {
        let mut out = self.out.lock().unwrap();
        if writeln!(out, "{line}").is_err() {
            self.gone.store(true, Ordering::SeqCst);
        }
    }

    fn gone(&self) -> bool {
        self.gone.load(Ordering::SeqCst)
    }

    fn close(&self) {
        let _ = self.out.lock().unwrap().shutdown(Shutdown::Both);
    }
}

/// A file passed open, as an item to send: under the name it has where the user has it.
fn item(file: OwnedFd) -> Result<Item, String> {
    let raw = file.as_raw_fd();
    let name = std::fs::read_link(format!("/proc/self/fd/{raw}"))
        .ok()
        .and_then(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .map(|name| name.trim_end_matches(" (deleted)").to_owned())
        .unwrap_or_else(|| "file".into());
    let file = std::fs::File::from(file);
    let about = file
        .metadata()
        .map_err(|error| format!("{name} could not be read: {error}."))?;
    if about.is_dir() {
        return Err(format!("{name} is a folder: only files can be sent."));
    }
    if !about.is_file() {
        return Err(format!("{name} is not a file."));
    }
    if about.len() > pack::LARGEST {
        return Err(format!(
            "{name} is larger than AirDrop can send at once (8 GB)."
        ));
    }
    let modified = about
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since| since.as_secs());
    Ok(Item {
        name,
        file,
        size: about.len(),
        modified,
    })
}

fn someone(name: &str) -> String {
    if name.is_empty() {
        "the iPhone".into()
    } else {
        format!("“{name}”")
    }
}

impl Sending {
    pub fn new(
        sender: Sender,
        scope: u32,
        wake: Result<Wake, String>,
        tell: Box<dyn Fn(Told) + Send + Sync>,
    ) -> Arc<Sending> {
        Arc::new(Sending {
            sender,
            scope,
            wake: Mutex::new(wake),
            inner: Mutex::default(),
            tell,
        })
    }

    /// The node asks who receives while this is true.
    pub fn browsing(&self) -> bool {
        self.inner.lock().unwrap().browsing
    }

    /// A receiver is being asked, or sent to.
    pub fn busy(&self) -> bool {
        self.inner.lock().unwrap().busy
    }

    /// Waits a moment for a send that is ending to tell its client so, as the daemon ends.
    pub fn finish(&self, at_most: Duration) {
        let until = Instant::now() + at_most;
        while self.inner.lock().unwrap().on && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The node heard of a receiver.
    pub fn heard(&self, found: Found) {
        let mut inner = self.inner.lock().unwrap();
        if inner.on && inner.found.len() < 64 {
            inner.found.push(found);
        }
    }

    /// A receiver the node heard of, from where the node heard it.
    pub fn heard_on_air(&self, peer: Mac, receiver: packet::Receiver) {
        let address = std::net::Ipv6Addr::from(packet::link_local(&peer));
        // The name it gave goes into the Host of what it is asked: nothing but what a host name has.
        let host: String = receiver
            .host
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.'))
            .take(255)
            .collect();
        self.heard(Found {
            peer,
            at: SocketAddr::V6(SocketAddrV6::new(address, receiver.port, 0, self.scope)),
            host: format!("{host}:{}", receiver.port),
            instance: receiver.instance,
        });
    }

    /// A peer the node no longer hears.
    pub fn gone(&self, peer: Mac) {
        let mut inner = self.inner.lock().unwrap();
        if inner.on && inner.gone.len() < 64 {
            inner.gone.push(peer);
        }
    }

    /// Bluetooth says this computer wants to send: "" while it does, else why not.
    fn announce(&self) -> String {
        match &mut *self.wake.lock().unwrap() {
            Ok(wake) => wake.announce().err().unwrap_or_default(),
            Err(why) => {
                format!("Bluetooth could not be used to wake the iPhone's AirDrop ({why}).")
            }
        }
    }

    fn quiet(&self) {
        if let Ok(wake) = &mut *self.wake.lock().unwrap() {
            wake.quiet();
        }
    }

    /// A client asked to send these files: the session is its from now on. Why not, if it cannot be.
    pub fn start(self: &Arc<Self>, stream: UnixStream, files: Vec<OwnedFd>) -> Result<(), String> {
        if files.is_empty() {
            return Err("Nothing was given to send.".into());
        }
        if files.len() > MOST_FILES {
            return Err(format!("AirDrop sends up to {MOST_FILES} files at a time."));
        }
        let mut items = files.into_iter().map(item).collect::<Result<Vec<_>, _>>()?;
        let names = pack::names(
            &items
                .iter()
                .map(|item| item.name.clone())
                .collect::<Vec<_>>(),
        );
        for (item, name) in items.iter_mut().zip(names) {
            item.name = name;
        }
        {
            let mut inner = self.inner.lock().unwrap();
            if inner.on {
                return Err("AirDrop is sending something already.".into());
            }
            *inner = Inner {
                on: true,
                browsing: true,
                ..Inner::default()
            };
        }
        let Some(client) = Client::new(stream) else {
            self.inner.lock().unwrap().on = false;
            return Err("The send could not be started.".into());
        };
        let sending = self.clone();
        let session = std::thread::Builder::new().name("airdrop-send".into());
        let started = session.spawn(move || {
            (sending.tell)(Told::Began);
            let (last, transfer) = sending.session(&client, items);
            sending.quiet();
            client.say(&last);
            client.close();
            *sending.inner.lock().unwrap() = Inner::default();
            (sending.tell)(Told::Ended { transfer });
        });
        if started.is_err() {
            *self.inner.lock().unwrap() = Inner::default();
            return Err("The send could not be started.".into());
        }
        Ok(())
    }

    /// The send, from the looking to its end: the last line, and whether a receiver was asked.
    fn session(self: &Arc<Self>, client: &Client, items: Vec<Item>) -> (String, bool) {
        let offered: Vec<(String, u64)> = items
            .iter()
            .map(|item| (item.name.clone(), item.size))
            .collect();
        let (results, discovered) = mpsc::channel::<(usize, Mac, Result<Listing, String>)>();
        let mut candidates: Vec<Candidate> = Vec::new();
        // The peers a /Discover is on its way to, one at a time each.
        let mut asking: Vec<Mac> = Vec::new();
        let (mut numbered, mut told) = (0usize, String::new());
        let chosen = loop {
            if client.gone() {
                return (r#"{"state":"cancelled"}"#.into(), false);
            }
            if sys::stopping() {
                return (ended(&candidates), false);
            }
            let now = Instant::now();
            let (found, gone) = {
                let mut inner = self.inner.lock().unwrap();
                (
                    std::mem::take(&mut inner.found),
                    std::mem::take(&mut inner.gone),
                )
            };
            for found in found {
                if let Some(known) = candidates
                    .iter_mut()
                    .find(|c| c.found.peer == found.peer && c.found.instance == found.instance)
                {
                    known.found = found;
                    continue;
                }
                if !room(&mut candidates, &found.peer) {
                    continue;
                }
                numbered += 1;
                (self.tell)(Told::Log(format!(
                    "a receiver, {:?}, at {}",
                    found.instance, found.at
                )));
                candidates.push(Candidate {
                    id: numbered,
                    found,
                    listing: None,
                    trying: false,
                    next: now,
                    failures: 0,
                });
            }
            candidates.retain(|c| !gone.contains(&c.found.peer));
            // Who each is, asked on a thread of its own: a phone may take seconds to answer. One
            // question at a time to a peer, and no more at once than there may be receivers.
            for candidate in candidates.iter_mut().filter(|c| !c.trying && now >= c.next) {
                let peer = candidate.found.peer;
                if asking.contains(&peer) || asking.len() >= MOST_RECEIVERS {
                    continue;
                }
                let (sending, results) = (self.clone(), results.clone());
                let (id, found) = (candidate.id, candidate.found.clone());
                let discovering = std::thread::Builder::new().name("airdrop-discover".into());
                let started = discovering.spawn(move || {
                    let listing = sending.sender.discover(&found.at, &found.host);
                    let _ = results.send((id, peer, listing));
                });
                match started {
                    Ok(_) => {
                        candidate.trying = true;
                        asking.push(peer);
                    }
                    // Asked again later, as one that did not answer.
                    Err(_) => candidate.next = now + RETRY_AT_MOST,
                }
            }
            while let Ok((id, peer, result)) = discovered.try_recv() {
                asking.retain(|asked| *asked != peer);
                let Some(candidate) = candidates.iter_mut().find(|c| c.id == id) else {
                    continue;
                };
                candidate.trying = false;
                match result {
                    Ok(listing) => {
                        if candidate.listing.as_ref() != Some(&listing) {
                            (self.tell)(Told::Log(format!(
                                "{:?} is {:?}, and {}",
                                candidate.found.instance,
                                listing.name,
                                if listing.accepts {
                                    "takes AirDrop from this computer"
                                } else {
                                    "takes AirDrop from its contacts only"
                                }
                            )));
                        }
                        candidate.next = if listing.accepts {
                            now + Duration::from_secs(24 * 3600)
                        } else {
                            now + ASK_AGAIN
                        };
                        candidate.listing = Some(listing);
                    }
                    Err(why) => {
                        candidate.failures += 1;
                        candidate.next =
                            now + (Duration::from_secs(2) * candidate.failures).min(RETRY_AT_MOST);
                        (self.tell)(Told::Log(format!(
                            "{:?} would not say who it is: {why}",
                            candidate.found.instance
                        )));
                    }
                }
            }
            let mut picked = None;
            while let Ok(id) = client.picks.try_recv() {
                picked = Some(id);
            }
            if let Some(chosen) = picked.and_then(|id| {
                candidates.iter().find(|c| {
                    c.id.to_string() == id && c.listing.as_ref().is_some_and(|l| l.accepts)
                })
            }) {
                break chosen.clone();
            }
            let bluetooth = self.announce();
            let line = looking(&candidates, &bluetooth);
            if line != told {
                client.say(&line);
                told = line;
            }
            std::thread::sleep(Duration::from_millis(100));
        };

        {
            let mut inner = self.inner.lock().unwrap();
            inner.browsing = false;
            inner.busy = true;
        }
        let to = chosen.listing.map(|l| l.name).unwrap_or_default();
        let (at, host) = (chosen.found.at, chosen.found.host);
        client.say(&format!(r#"{{"state":"asking","to":{}}}"#, quoted(&to)));
        (self.tell)(Told::Log(format!(
            "asking {to:?} whether it wants {} file(s)",
            offered.len()
        )));
        // Bluetooth keeps saying it while the receiver is asked and sent to; this is looked at by
        // the thread that watches the connection, too, which shuts it at once.
        let gone = client.gone.clone();
        let stop = move || {
            self.announce();
            gone.load(Ordering::SeqCst) || sys::stopping()
        };
        let mut connection = match self.sender.ask(&at, &host, &offered, &stop) {
            Err(_) if stop() => return (interrupted(client), true),
            Err(why) => {
                (self.tell)(Told::Log(format!("asking {to:?} failed: {why}")));
                let why = if why == "nobody answered" {
                    format!("{} did not answer.", someone(&to))
                } else {
                    format!("{} could not be reached.", someone(&to))
                };
                return (failed(&why), true);
            }
            Ok(Answer::No(status)) => {
                (self.tell)(Told::Log(format!("{to:?} declined ({status})")));
                return (
                    format!(r#"{{"state":"declined","to":{}}}"#, quoted(&to)),
                    true,
                );
            }
            Ok(Answer::Yes(connection)) => connection,
        };
        let mut pack = match Pack::new(items) {
            Ok(pack) => pack,
            Err(why) => return (failed(&format!("{why}.")), true),
        };
        let (bytes, began) = (pack.bytes, Instant::now());
        let progress = |sent: u64| {
            format!(
                r#"{{"state":"sending","to":{},"sent":{sent},"bytes":{bytes}}}"#,
                quoted(&to)
            )
        };
        client.say(&progress(0));
        let mut said = Instant::now();
        let result = self.sender.upload(
            &mut connection,
            &host,
            &mut pack,
            &mut |sent| {
                if said.elapsed() >= PROGRESS_EVERY {
                    said = Instant::now();
                    client.say(&progress(sent));
                }
            },
            &stop,
        );
        let seconds = began.elapsed().as_secs_f64();
        match result {
            Ok(()) => {
                (self.tell)(Told::Log(format!(
                    "sent {to:?} {} in {seconds:.2} s ({:.0} kB/s)",
                    crate::control::size(bytes),
                    bytes as f64 / 1024.0 / seconds.max(0.001)
                )));
                (
                    format!(
                        r#"{{"state":"sent","to":{},"bytes":{bytes},"seconds":{seconds:.2}}}"#,
                        quoted(&to)
                    ),
                    true,
                )
            }
            Err(_) if stop() => (interrupted(client), true),
            Err(why) => {
                (self.tell)(Told::Log(format!("sending to {to:?} failed: {why}")));
                (
                    failed(&format!("The files did not all reach {}.", someone(&to))),
                    true,
                )
            }
        }
    }
}

/// The last line of a send stopped on its way: by its client, or by AirDrop's end.
fn interrupted(client: &Client) -> String {
    if client.gone() {
        r#"{"state":"cancelled"}"#.into()
    } else {
        failed("AirDrop went off before the files had all gone.")
    }
}

fn failed(why: &str) -> String {
    format!(r#"{{"state":"failed","why":{}}}"#, quoted(why))
}

/// Makes room for a receiver of `peer`'s, if there may be one: a peer's third takes the place of
/// its oldest; with the most there may be, one that never said who it is goes. False if none can.
fn room(candidates: &mut Vec<Candidate>, peer: &Mac) -> bool {
    let of_peer: Vec<usize> = candidates
        .iter()
        .enumerate()
        .filter(|(_, c)| c.found.peer == *peer)
        .map(|(at, _)| at)
        .collect();
    if of_peer.len() >= MOST_PER_PEER {
        candidates.remove(of_peer[0]);
        return true;
    }
    if candidates.len() < MOST_RECEIVERS {
        return true;
    }
    match candidates
        .iter()
        .position(|c| c.listing.is_none() && c.failures > 0)
    {
        Some(at) => {
            candidates.remove(at);
            true
        }
        None => false,
    }
}

/// The receivers as the client is told of them: those that said who they are. A peer that comes
/// under a new instance is listed as its newest self; another peer of the same name is another
/// device, and is listed too, until the node no longer hears it: a name is anybody's to give.
fn looking(candidates: &[Candidate], bluetooth: &str) -> String {
    let mut shown: Vec<(&Candidate, &Listing)> = Vec::new();
    for candidate in candidates.iter().rev() {
        let Some(listing) = &candidate.listing else {
            continue;
        };
        if shown.iter().any(|(seen, said)| {
            seen.found.peer == candidate.found.peer && said.name == listing.name
        }) {
            continue;
        }
        shown.push((candidate, listing));
    }
    shown.reverse();
    format!(
        r#"{{"state":"looking","receivers":{},"bluetooth":{}}}"#,
        list(shown.iter().map(|(candidate, listing)| format!(
            r#"{{"id":"{}","name":{},"model":{},"accepts":{}}}"#,
            candidate.id,
            quoted(&listing.name),
            quoted(&listing.model),
            listing.accepts
        ))),
        quoted(bluetooth)
    )
}

/// The last line of a send that AirDrop's end cut short while it looked.
fn ended(candidates: &[Candidate]) -> String {
    let listed: Vec<&Listing> = candidates
        .iter()
        .filter_map(|c| c.listing.as_ref())
        .collect();
    if listed.iter().any(|listing| listing.accepts) {
        return failed("AirDrop went off before anything was sent.");
    }
    format!(
        r#"{{"state":"nobody","refused":{}}}"#,
        list(listed.iter().map(|listing| quoted(&listing.name)))
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sender::tests::{receiving, scratch, sender};
    use std::io::Read;

    fn line(stream: &mut UnixStream) -> String {
        let mut line = Vec::new();
        let mut byte = [0u8; 1];
        while stream.read(&mut byte).unwrap_or(0) == 1 && byte[0] != b'\n' {
            line.push(byte[0]);
        }
        String::from_utf8(line).unwrap()
    }

    /// Lines until one that starts so; the ones before it.
    fn until(stream: &mut UnixStream, start: &str) -> (String, Vec<String>) {
        let mut before = Vec::new();
        loop {
            let next = line(stream);
            assert!(
                !next.is_empty(),
                "the session ended before {start}: {before:?}"
            );
            if next.starts_with(start) {
                return (next, before);
            }
            before.push(next);
        }
    }

    fn opened(folder: &std::path::Path, name: &str, data: &[u8]) -> OwnedFd {
        let path = folder.join(name);
        std::fs::write(&path, data).unwrap();
        OwnedFd::from(std::fs::File::open(path).unwrap())
    }

    fn sending(folder: &std::path::Path) -> (Arc<Sending>, Arc<Mutex<Vec<Told>>>) {
        let told: Arc<Mutex<Vec<Told>>> = Arc::default();
        let keep = told.clone();
        let sending = Sending::new(
            sender(folder),
            0,
            Err("no Bluetooth in a test".into()),
            Box::new(move |said| keep.lock().unwrap().push(said)),
        );
        (sending, told)
    }

    #[test]
    fn a_receiver_heard_of_is_listed_picked_asked_and_sent_to() {
        let folder = scratch("session");
        let (at, _) = receiving(&folder, "Zoë's iPhone", true);
        let (sending, told) = sending(&folder);
        let photo: Vec<u8> = (0..300_000u32).map(|n| (n % 253) as u8).collect();
        let picked = folder.join("picked");
        std::fs::create_dir_all(&picked).unwrap();
        let files = vec![
            opened(&picked, "IMG_0001.JPG", &photo),
            opened(&picked, "notes.txt", b"hi\n"),
        ];
        let (mut ours, theirs) = UnixStream::pair().unwrap();
        // A folder is refused before anything starts.
        let folder_itself = OwnedFd::from(std::fs::File::open(&picked).unwrap());
        assert_eq!(
            sending
                .start(theirs.try_clone().unwrap(), vec![folder_itself])
                .err(),
            Some("picked is a folder: only files can be sent.".into())
        );
        assert!(!sending.browsing());
        sending.start(theirs, files).unwrap();

        let first = line(&mut ours);
        assert!(
            first.starts_with(
                r#"{"state":"looking","receivers":[],"bluetooth":"Bluetooth could not be used"#
            ),
            "{first}"
        );
        assert!(sending.browsing() && !sending.busy());
        // A second send meanwhile is refused.
        let (_, other) = UnixStream::pair().unwrap();
        assert_eq!(
            sending.start(other, vec![opened(&picked, "b", b"b")]).err(),
            Some("AirDrop is sending something already.".into())
        );

        // What it calls itself on the air goes into the log quoted: a line of its own, or a
        // terminal's escapes, are not the log's.
        sending.heard(Found {
            peer: [2, 0, 0, 0, 0, 1],
            instance: "abc\ndef\u{1b}[2J".into(),
            at,
            host: "Zoes-Phone.local:8770".into(),
        });
        let (listed, _) = until(&mut ours, r#"{"state":"looking","receivers":[{"#);
        assert_eq!(
            listed,
            r#"{"state":"looking","receivers":[{"id":"1","name":"Zoë's iPhone","model":"Nova","accepts":true}],"bluetooth":"Bluetooth could not be used to wake the iPhone's AirDrop (no Bluetooth in a test)."}"#
        );
        writeln!(ours, "to 1").unwrap();
        assert_eq!(line(&mut ours), r#"{"state":"asking","to":"Zoë's iPhone"}"#);
        let (sent, progress) = until(&mut ours, r#"{"state":"sent""#);
        assert!(
            sent.starts_with(r#"{"state":"sent","to":"Zoë's iPhone","bytes":300003,"seconds":"#)
        );
        assert!(progress[0]
            .starts_with(r#"{"state":"sending","to":"Zoë's iPhone","sent":0,"bytes":300003}"#));
        assert_eq!(line(&mut ours), "", "and that is the end of it");
        let into = folder.join("received");
        assert_eq!(std::fs::read(into.join("IMG_0001.JPG")).unwrap(), photo);
        assert_eq!(std::fs::read(into.join("notes.txt")).unwrap(), b"hi\n");
        // The daemon was told it began and ended, with a transfer.
        std::thread::sleep(Duration::from_millis(50));
        let told = told.lock().unwrap();
        assert!(told.contains(&Told::Log(
            r#"a receiver, "abc\ndef\u{1b}[2J", at [::1]:"#.to_owned() + &at.port().to_string()
        )));
        assert_eq!(told.first(), Some(&Told::Began));
        assert_eq!(told.last(), Some(&Told::Ended { transfer: true }));
        assert!(!sending.browsing() && !sending.busy());
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn a_receiver_that_says_no_and_a_client_that_goes() {
        let folder = scratch("session-no");
        let (at, _) = receiving(&folder, "Elsewhere", false);
        let (sending, told) = sending(&folder);
        let (mut ours, theirs) = UnixStream::pair().unwrap();
        sending
            .start(theirs, vec![opened(&folder, "a.jpg", b"jpeg")])
            .unwrap();
        line(&mut ours);
        sending.heard(Found {
            peer: [2, 0, 0, 0, 0, 2],
            instance: "0000000000aa".into(),
            at,
            host: "h:1".into(),
        });
        until(&mut ours, r#"{"state":"looking","receivers":[{"#);
        // An id that is not one listed is not taken.
        writeln!(ours, "to 9").unwrap();
        writeln!(ours, "to 1").unwrap();
        until(&mut ours, r#"{"state":"asking""#);
        assert_eq!(line(&mut ours), r#"{"state":"declined","to":"Elsewhere"}"#);

        // The client stops a send while it looks.
        std::thread::sleep(Duration::from_millis(50));
        let (mut ours, theirs) = UnixStream::pair().unwrap();
        sending
            .start(theirs, vec![opened(&folder, "b.jpg", b"jpeg")])
            .unwrap();
        line(&mut ours);
        writeln!(ours, "cancel").unwrap();
        assert_eq!(line(&mut ours), r#"{"state":"cancelled"}"#);
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(
            told.lock().unwrap().last(),
            Some(&Told::Ended { transfer: false })
        );
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn what_the_client_is_told_when_nobody_takes_it() {
        let listing = |name: &str, accepts| Listing {
            name: name.into(),
            model: String::new(),
            accepts,
        };
        let candidate = |id, peer: u8, listed: Option<Listing>| Candidate {
            id,
            found: Found {
                peer: [2, 0, 0, 0, 0, peer],
                instance: format!("{id}"),
                at: "[::1]:1".parse().unwrap(),
                host: String::new(),
            },
            listing: listed,
            trying: false,
            next: Instant::now(),
            failures: 0,
        };
        assert_eq!(ended(&[]), r#"{"state":"nobody","refused":[]}"#);
        assert_eq!(
            ended(&[
                candidate(1, 1, Some(listing("", false))),
                candidate(2, 2, None)
            ]),
            r#"{"state":"nobody","refused":[""]}"#
        );
        assert!(ended(&[candidate(1, 1, Some(listing("Zoë", true)))]).contains("went off"));
        // Two peers of one name are two devices: both listed, while both are heard. One peer under
        // a new instance is listed once, as its newest self.
        let twice = [
            candidate(1, 1, Some(listing("Zoë", true))),
            candidate(2, 2, None),
            candidate(3, 3, Some(listing("Zoë", true))),
        ];
        assert_eq!(
            looking(&twice, ""),
            r#"{"state":"looking","receivers":[{"id":"1","name":"Zoë","model":"","accepts":true},{"id":"3","name":"Zoë","model":"","accepts":true}],"bluetooth":""}"#
        );
        let renamed = [
            candidate(1, 1, Some(listing("Zoë", true))),
            candidate(4, 1, Some(listing("Zoë", true))),
        ];
        assert_eq!(
            looking(&renamed, ""),
            r#"{"state":"looking","receivers":[{"id":"4","name":"Zoë","model":"","accepts":true}],"bluetooth":""}"#
        );
        assert_eq!(someone(""), "the iPhone");
    }

    #[test]
    fn a_crowd_or_a_liar_gets_no_more_room_than_a_few() {
        let candidate = |id, peer: u8, listed: bool, failures| Candidate {
            id,
            found: Found {
                peer: [2, 0, 0, 0, 0, peer],
                instance: format!("{id}"),
                at: "[::1]:1".parse().unwrap(),
                host: String::new(),
            },
            listing: listed.then(|| Listing {
                name: format!("{id}"),
                model: String::new(),
                accepts: true,
            }),
            trying: false,
            next: Instant::now(),
            failures,
        };
        // A peer's third instance takes the place of its oldest.
        let mut candidates = vec![candidate(1, 1, true, 0), candidate(2, 1, true, 0)];
        assert!(room(&mut candidates, &[2, 0, 0, 0, 0, 1]));
        assert_eq!(candidates.iter().map(|c| c.id).collect::<Vec<_>>(), [2]);
        // Full: one that never said who it is makes room; with none, nobody new is taken.
        let mut candidates: Vec<Candidate> = (0..MOST_RECEIVERS)
            .map(|n| candidate(n, n as u8 + 10, n != 7, u32::from(n == 7)))
            .collect();
        assert!(room(&mut candidates, &[2, 0, 0, 0, 0, 99]));
        assert_eq!(candidates.len(), MOST_RECEIVERS - 1);
        assert!(!candidates.iter().any(|c| c.id == 7));
        candidates.push(candidate(99, 99, true, 0));
        assert!(!room(&mut candidates, &[2, 0, 0, 0, 0, 98]));
    }
}
