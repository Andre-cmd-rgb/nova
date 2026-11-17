//! A send: from the files the user handed over to the receiver they picked.
//!
//! `nova airdrop send` passes the files open over the control socket (so
//! this reads what the user could, wherever it is) and the session is that
//! client's from then on: it is told, a line of JSON at each change, who can
//! be sent to, and then how the sending goes; it says which receiver, or to
//! stop. Its going away stops it too. One send at a time, which holds
//! AirDrop on until it is over, or until its client has gone: a send whose
//! thread is caught in something no shut connection ends (a file read from a
//! mount that went with the Wi-Fi) holds nothing once it is cancelled
//! (control.rs).
//!
//! Meanwhile Bluetooth announces that this computer wants to send
//! (wake.rs, through announcer.rs), which is what wakes an iPhone's AirDrop:
//! on a thread of its own, the herald, so that a Bluetooth slow to answer
//! holds up neither the looking nor any deadline. The node asks on the
//! air who receives (node.rs), and each receiver it hears of is asked who it
//! is (/Discover, sender.rs), and listed. Picked, it is asked whether its
//! person wants the files (/Ask), and sent them (/Upload).
//!
//! The lines all have a `state`, and with it:
//!
//!   looking    `receivers` (each an `id`, its `name`, `model`, and `accepts`:
//!              false for one that takes AirDrop from its contacts only),
//!              `bluetooth` (why it cannot wake an iPhone; "" while it does);
//!              and `gone`, the id of one the client picked that is not
//!              listed any more, in a line said at once in answer to it
//!   asking     `to`: waiting for the person there to decide
//!   sending    `to`, `sent`, `bytes`
//!   sent       `to`, `bytes`, `seconds`
//!   declined   `to`
//!   failed     `why`, a sentence for the user
//!   nobody     AirDrop ended with nobody to send to; `refused`, the names of
//!              those that take AirDrop from their contacts only
//!   cancelled
//!
//! and the last of them, whichever it is, `stays` too: whether AirDrop stays
//! on after the send, as somebody else holds it; if not, it goes off a moment
//! after. The client says `to <id>` or `cancel`. Before any of it, a daemon
//! that has decided to end says `closing` (control.rs).

use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::net::{Shutdown, SocketAddr, SocketAddrV6};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, UNIX_EPOCH};

use crate::announcer::Announcer;
use crate::control::{list, quoted, Ready};
use crate::pack::{self, Item, Pack};
use crate::packet;
use crate::sender::{Answer, Listing, Sender};
use crate::sys;
use crate::wire::Mac;

/// The most files one send takes.
pub const MOST_FILES: usize = 200;
/// The most a picture for the offer may be: an iPhone's own are some tens of kB.
const PICTURE_MOST: u64 = 512 << 10;
/// What a picture for the offer starts with: JPEG 2000's signature, as an iPhone sends its own.
const JPEG_2000: [u8; 12] = [
    0, 0, 0, 0x0c, b'j', b'P', b' ', b' ', 0x0d, 0x0a, 0x87, 0x0a,
];
/// How often a receiver that would not say who it is is asked again, at the most, and one that
/// takes AirDrop from its contacts only: its owner may be switching it to Everyone.
const RETRY_AT_MOST: Duration = Duration::from_secs(10);
const ASK_AGAIN: Duration = Duration::from_secs(5);
/// How often the progress is told.
const PROGRESS_EVERY: Duration = Duration::from_millis(250);
/// How often the herald asks Bluetooth to say it again: the announcer itself says it again only
/// every few seconds (announcer.rs), and answers this at once meanwhile.
const HERALD_EVERY: Duration = Duration::from_millis(500);
/// What the looking lines say when the herald could not be started.
const NO_HERALD: &str =
    "Bluetooth could not be used to wake the iPhone's AirDrop (no thread could be started for it).";
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
    /// Set when its client has gone.
    left: Option<Arc<AtomicBool>>,
    /// What Bluetooth came to when the herald last asked: "" while it says this computer wants
    /// to send, else why not; None before its first answer.
    bluetooth: Option<String>,
    found: Vec<Found>,
    gone: Vec<Mac>,
}

impl Inner {
    /// Its client is there: a send whose client has gone holds nothing, whatever it is caught in.
    fn there(&self) -> bool {
        !self
            .left
            .as_ref()
            .is_some_and(|left| left.load(Ordering::SeqCst))
    }
}

pub struct Sending {
    sender: Sender,
    /// awdl0's number: the scope of a receiver's link-local address.
    scope: u32,
    wake: Mutex<Result<Announcer, String>>,
    inner: Mutex<Inner>,
    tell: Box<dyn Fn(Told) + Send + Sync>,
    /// Whether AirDrop stays on once a send lets go of it.
    stays: Box<dyn Fn() -> bool + Send + Sync>,
}

#[derive(Clone)]
struct Candidate {
    id: usize,
    found: Found,
    /// When the node last heard of it.
    heard: Instant,
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
        wake: Result<Announcer, String>,
        tell: Box<dyn Fn(Told) + Send + Sync>,
        stays: Box<dyn Fn() -> bool + Send + Sync>,
    ) -> Arc<Sending> {
        Arc::new(Sending {
            sender,
            scope,
            wake: Mutex::new(wake),
            inner: Mutex::default(),
            tell,
            stays,
        })
    }

    /// A send is going on, and its client is there: from the client's handing it over to its
    /// last line, or to the client's going.
    pub fn on(&self) -> bool {
        let inner = self.inner.lock().unwrap();
        inner.on && inner.there()
    }

    /// The node asks who receives while this is true.
    pub fn browsing(&self) -> bool {
        self.inner.lock().unwrap().browsing
    }

    /// A receiver is being asked, or sent to, for a client that is there.
    pub fn busy(&self) -> bool {
        let inner = self.inner.lock().unwrap();
        inner.busy && inner.there()
    }

    /// Waits a moment for a send that is ending to tell its client so, as the daemon ends.
    pub fn finish(&self, at_most: Duration) {
        let until = Instant::now() + at_most;
        while self.on() && Instant::now() < until {
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

    /// The herald: Bluetooth says this computer wants to send, on a thread of its own, until the
    /// sender handed back is dropped, and is quiet after. The announcer may take its time to
    /// answer (13 s at most), and nothing of the send waits for it: the looking lines say what it
    /// came to last, and the watch on a receiver looks at flags alone. None if no thread could
    /// be started, which the looking lines say.
    fn herald(self: &Arc<Self>) -> Option<(mpsc::Sender<()>, JoinHandle<()>)> {
        let (over, until) = mpsc::channel::<()>();
        let sending = self.clone();
        let started = std::thread::Builder::new()
            .name("airdrop-herald".into())
            .spawn(move || {
                loop {
                    let said = sending.announce();
                    sending.inner.lock().unwrap().bluetooth = Some(said);
                    if !matches!(
                        until.recv_timeout(HERALD_EVERY),
                        Err(mpsc::RecvTimeoutError::Timeout)
                    ) {
                        break;
                    }
                }
                sending.quiet();
            });
        match started {
            Ok(herald) => Some((over, herald)),
            Err(_) => {
                self.inner.lock().unwrap().bluetooth = Some(NO_HERALD.into());
                None
            }
        }
    }

    /// The files a client handed over, looked at before anything else, with no lock of the
    /// daemon's held (a file on a mount that went with the Wi-Fi may take its time): the send, for
    /// control.rs to claim and start, or why not. With `icon`, the last of them is the picture for
    /// the offer (`send icon`).
    pub fn prepare(
        self: &Arc<Self>,
        mut files: Vec<OwnedFd>,
        icon: bool,
    ) -> Result<Prepared, String> {
        let icon = if icon {
            files.pop().and_then(picture)
        } else {
            None
        };
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
        Ok(Prepared {
            sending: self.clone(),
            items,
            icon,
        })
    }

    /// The same, claimed and started in one go, for the tests.
    #[cfg(test)]
    pub fn start(self: &Arc<Self>, stream: UnixStream, files: Vec<OwnedFd>) -> Result<(), String> {
        let mut send = Box::new(self.prepare(files, false)?);
        send.claim()?;
        send.start(stream)
    }

    /// A claimed send, started: the session is its client's from now on.
    fn begin(
        self: &Arc<Self>,
        stream: UnixStream,
        items: Vec<Item>,
        icon: Option<Vec<u8>>,
    ) -> Result<(), String> {
        let client = Client::new(stream).ok_or("The send could not be started.")?;
        self.inner.lock().unwrap().left = Some(client.gone.clone());
        let sending = self.clone();
        let session = std::thread::Builder::new().name("airdrop-send".into());
        let started = session.spawn(move || {
            (sending.tell)(Told::Began);
            let herald = sending.herald();
            let (last, transfer) = sending.session(&client, items, icon);
            // Told first: a Bluetooth slow to go quiet holds up nobody's last line.
            client.say(&afterwards(&last, (sending.stays)()));
            client.close();
            // Quiet before another send may start: this one's announcement does not outlast it.
            if let Some((over, herald)) = herald {
                drop(over);
                let _ = herald.join();
            }
            *sending.inner.lock().unwrap() = Inner::default();
            (sending.tell)(Told::Ended { transfer });
        });
        started
            .map(|_| ())
            .map_err(|_| "The send could not be started.".into())
    }

    /// The send, from the looking to its end: the last line, and whether a receiver was asked.
    fn session(
        self: &Arc<Self>,
        client: &Client,
        items: Vec<Item>,
        icon: Option<Vec<u8>>,
    ) -> (String, bool) {
        let offered: Vec<(String, u64)> = items
            .iter()
            .map(|item| (item.name.clone(), item.size))
            .collect();
        let (results, discovered) = mpsc::channel::<(usize, Mac, Result<Listing, String>)>();
        let mut candidates: Vec<Candidate> = Vec::new();
        // The peers a /Discover is on its way to, one at a time each.
        let mut asking: Vec<Mac> = Vec::new();
        let (mut numbered, mut told) = (0usize, String::new());
        // A pick of one that is not listed any more, to be answered.
        let mut went: Option<String> = None;
        let chosen = loop {
            if client.gone() {
                return (r#"{"state":"cancelled"}"#.into(), false);
            }
            if sys::stopping() {
                return (ended(&candidates), false);
            }
            let now = Instant::now();
            // What the client picked, read first: the one it picked keeps its room below.
            let mut picked = None;
            while let Ok(id) = client.picks.try_recv() {
                picked = Some(id);
            }
            let keep = picked
                .as_deref()
                .and_then(|id| candidates.iter().find(|c| c.id.to_string() == id))
                .map(|c| c.id);
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
                    known.heard = now;
                    continue;
                }
                if !room(&mut candidates, &found.peer, keep) {
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
                    heard: now,
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
            if let Some(id) = picked {
                let listed = |c: &&Candidate| c.id.to_string() == id && c.listing.is_some();
                match candidates.iter().find(listed) {
                    Some(chosen) if chosen.listing.as_ref().is_some_and(|l| l.accepts) => {
                        break chosen.clone();
                    }
                    // One that takes AirDrop from its contacts only: no client picks it.
                    Some(_) => {}
                    // Gone before it could be asked: the client is told so, with the list.
                    None => went = Some(id),
                }
            }
            // Said once the herald has Bluetooth's first answer, with what it came to last.
            let bluetooth = self.inner.lock().unwrap().bluetooth.clone();
            if let Some(bluetooth) = bluetooth {
                let line = looking(&candidates, &bluetooth, None);
                if let Some(id) = went.take() {
                    client.say(&looking(&candidates, &bluetooth, Some(&id)));
                    told = line;
                } else if line != told {
                    client.say(&line);
                    told = line;
                }
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
        // Looked at by the thread that watches the connection, too, which shuts it at once: flags
        // alone, so that no deadline waits for Bluetooth (the herald goes on telling it while the
        // receiver is asked and sent to).
        let gone = client.gone.clone();
        let stop = move || gone.load(Ordering::SeqCst) || sys::stopping();
        let mut connection = match self
            .sender
            .offer(&at, &host, &offered, icon.as_deref(), &stop)
        {
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
        (self.tell)(Told::Log(format!("{to:?} said yes")));
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
            &|line| (self.tell)(Told::Log(format!("sending to {to:?}: {line}"))),
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

/// A send whose files have been looked at: claimed as the one going on, then started (control.rs).
pub struct Prepared {
    sending: Arc<Sending>,
    items: Vec<Item>,
    icon: Option<Vec<u8>>,
}

impl Ready for Prepared {
    fn claim(&mut self) -> Result<(), String> {
        let mut inner = self.sending.inner.lock().unwrap();
        if inner.on {
            return Err("AirDrop is sending something already.".into());
        }
        *inner = Inner {
            on: true,
            browsing: true,
            ..Inner::default()
        };
        Ok(())
    }

    fn start(self: Box<Self>, stream: UnixStream) -> Result<(), String> {
        let Prepared {
            sending,
            items,
            icon,
        } = *self;
        let started = sending.begin(stream, items, icon);
        // Nothing of a send that did not start is left: not its looking either.
        if started.is_err() {
            *sending.inner.lock().unwrap() = Inner::default();
        }
        started
    }
}

/// The picture `nova airdrop send` made for the offer: a file, small, and JPEG 2000; else none, and
/// the offer goes without one.
fn picture(fd: OwnedFd) -> Option<Vec<u8>> {
    let mut file = std::fs::File::from(fd);
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    file.seek(SeekFrom::Start(0)).ok()?;
    let mut picture = Vec::new();
    file.take(PICTURE_MOST + 1).read_to_end(&mut picture).ok()?;
    (picture.len() as u64 <= PICTURE_MOST && picture.starts_with(&JPEG_2000)).then_some(picture)
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

/// A send's last line, with whether AirDrop stays on after it.
fn afterwards(last: &str, stays: bool) -> String {
    match last.strip_suffix('}') {
        Some(open) => format!(r#"{open},"stays":{stays}}}"#),
        None => last.into(),
    }
}

/// Makes room for a receiver of `peer`'s, if there may be one: a peer's third takes the place of
/// its oldest; with the most there may be, the one the node heard of least lately goes, one that
/// would not say who it is before any other, so that a crowd that went quiet keeps nobody out.
/// Never the one the client picked (`keep`). False if none can go.
fn room(candidates: &mut Vec<Candidate>, peer: &Mac, keep: Option<usize>) -> bool {
    let kept = |c: &Candidate| Some(c.id) == keep;
    let oldest_of_peer = candidates
        .iter()
        .enumerate()
        .filter(|(_, c)| c.found.peer == *peer)
        .map(|(at, c)| (at, kept(c)))
        .collect::<Vec<_>>();
    if oldest_of_peer.len() >= MOST_PER_PEER {
        if let Some(&(at, _)) = oldest_of_peer.iter().find(|(_, kept)| !kept) {
            candidates.remove(at);
            return true;
        }
    }
    if candidates.len() < MOST_RECEIVERS {
        return true;
    }
    let quietest = candidates
        .iter()
        .enumerate()
        .filter(|(_, c)| !kept(c))
        .min_by_key(|(_, c)| (!(c.listing.is_none() && c.failures > 0), c.heard))
        .map(|(at, _)| at);
    match quietest {
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
/// With `gone`, the id of one picked that is not among them any more.
fn looking(candidates: &[Candidate], bluetooth: &str, gone: Option<&str>) -> String {
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
    let gone = gone.map_or(String::new(), |id| format!(r#","gone":{}"#, quoted(id)));
    format!(
        r#"{{"state":"looking","receivers":{},"bluetooth":{}{gone}}}"#,
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
            Box::new(|| false),
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
        assert!(!sending.browsing() && !sending.on());
        sending.start(theirs, files).unwrap();
        assert!(sending.on());

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
        assert!(sent.ends_with(r#","stays":false}"#), "{sent}");
        assert!(!sending.browsing() && !sending.busy() && !sending.on());
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn a_bluetooth_that_does_not_answer_holds_up_nothing_of_a_send() {
        let folder = scratch("session-slow-bluetooth");
        let (at, _) = receiving(&folder, "Zoë's iPhone", true);
        // Each request to it is given up on after three seconds, and asked again.
        let (announcer, _hung) = Announcer::unanswering(Duration::from_secs(3));
        let sending = Sending::new(
            sender(&folder),
            0,
            Ok(announcer),
            Box::new(|_| {}),
            Box::new(|| false),
        );
        let (mut ours, theirs) = UnixStream::pair().unwrap();
        sending
            .start(theirs, vec![opened(&folder, "a.jpg", &[7u8; 200_000])])
            .unwrap();
        // The first looking line waits for its first answer, which is that there was none.
        let first = line(&mut ours);
        assert!(
            first.contains("Bluetooth did not answer in time"),
            "{first}"
        );
        // Asked again meanwhile, it holds up neither the list nor the asking and the sending,
        // nor the watch on them: each is over long before Bluetooth gives up again.
        let began = Instant::now();
        sending.heard(Found {
            peer: [2, 0, 0, 0, 0, 1],
            instance: "0000000000ab".into(),
            at,
            host: "h:1".into(),
        });
        until(&mut ours, r#"{"state":"looking","receivers":[{"#);
        assert!(
            began.elapsed() < Duration::from_secs(2),
            "{:?}",
            began.elapsed()
        );
        let began = Instant::now();
        writeln!(ours, "to 1").unwrap();
        let (sent, _) = until(&mut ours, r#"{"state":"sent""#);
        assert!(
            began.elapsed() < Duration::from_secs(2),
            "{:?}",
            began.elapsed()
        );
        assert!(sent.ends_with(r#","stays":false}"#), "{sent}");
        // The last line is not held up either; the herald goes quiet after it, and only then may
        // another send start.
        assert_eq!(line(&mut ours), "");
        assert!(sending.inner.lock().unwrap().on);
        let began = Instant::now();
        while sending.inner.lock().unwrap().on && began.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!sending.inner.lock().unwrap().on);
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
        // An id that is not one listed (any more) is not taken: the list is said again at once,
        // with the id that is gone.
        writeln!(ours, "to 9").unwrap();
        let (again, _) = until(&mut ours, r#"{"state":"looking""#);
        assert!(again.ends_with(r#","gone":"9"}"#), "{again}");
        assert!(again.contains(r#""name":"Elsewhere""#), "{again}");
        writeln!(ours, "to 1").unwrap();
        until(&mut ours, r#"{"state":"asking""#);
        assert_eq!(
            line(&mut ours),
            r#"{"state":"declined","to":"Elsewhere","stays":false}"#
        );

        // The client stops a send while it looks.
        std::thread::sleep(Duration::from_millis(50));
        let (mut ours, theirs) = UnixStream::pair().unwrap();
        sending
            .start(theirs, vec![opened(&folder, "b.jpg", b"jpeg")])
            .unwrap();
        line(&mut ours);
        writeln!(ours, "cancel").unwrap();
        assert_eq!(line(&mut ours), r#"{"state":"cancelled","stays":false}"#);
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(
            told.lock().unwrap().last(),
            Some(&Told::Ended { transfer: false })
        );
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn a_send_whose_client_has_gone_holds_nothing_whatever_it_is_caught_in() {
        let folder = scratch("session-left");
        let (sending, _) = sending(&folder);
        let left = Arc::new(AtomicBool::new(false));
        // As a session caught in a read that nothing ends would leave it: asking, sending, on.
        *sending.inner.lock().unwrap() = Inner {
            on: true,
            busy: true,
            left: Some(left.clone()),
            ..Inner::default()
        };
        assert!(sending.on() && sending.busy());
        left.store(true, Ordering::SeqCst);
        assert!(!sending.on() && !sending.busy());
        let began = Instant::now();
        sending.finish(Duration::from_secs(2));
        assert!(began.elapsed() < Duration::from_millis(100));
        // It is still the one send, though: another waits until its thread is over.
        let (_, theirs) = UnixStream::pair().unwrap();
        assert_eq!(
            sending
                .start(theirs, vec![opened(&folder, "a", b"a")])
                .err(),
            Some("AirDrop is sending something already.".into())
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
            heard: Instant::now(),
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
            looking(&twice, "", None),
            r#"{"state":"looking","receivers":[{"id":"1","name":"Zoë","model":"","accepts":true},{"id":"3","name":"Zoë","model":"","accepts":true}],"bluetooth":""}"#
        );
        let renamed = [
            candidate(1, 1, Some(listing("Zoë", true))),
            candidate(4, 1, Some(listing("Zoë", true))),
        ];
        assert_eq!(
            looking(&renamed, "", None),
            r#"{"state":"looking","receivers":[{"id":"4","name":"Zoë","model":"","accepts":true}],"bluetooth":""}"#
        );
        assert_eq!(
            looking(&renamed, "", Some("3")),
            r#"{"state":"looking","receivers":[{"id":"4","name":"Zoë","model":"","accepts":true}],"bluetooth":"","gone":"3"}"#
        );
        assert_eq!(someone(""), "the iPhone");
        assert_eq!(
            afterwards(r#"{"state":"cancelled"}"#, true),
            r#"{"state":"cancelled","stays":true}"#
        );
    }

    #[test]
    fn a_crowd_or_a_liar_gets_no_more_room_than_a_few() {
        let began = Instant::now();
        let candidate = |id, peer: u8, listed: bool, failures| Candidate {
            id,
            found: Found {
                peer: [2, 0, 0, 0, 0, peer],
                instance: format!("{id}"),
                at: "[::1]:1".parse().unwrap(),
                host: String::new(),
            },
            // Heard of in the order they came, one a second.
            heard: began + Duration::from_secs(id as u64),
            listing: listed.then(|| Listing {
                name: format!("{id}"),
                model: String::new(),
                accepts: true,
            }),
            trying: false,
            next: Instant::now(),
            failures,
        };
        let ids = |candidates: &[Candidate]| candidates.iter().map(|c| c.id).collect::<Vec<_>>();
        // A peer's third instance takes the place of its oldest, unless that is the one picked.
        let mut candidates = vec![candidate(1, 1, true, 0), candidate(2, 1, true, 0)];
        assert!(room(&mut candidates, &[2, 0, 0, 0, 0, 1], None));
        assert_eq!(ids(&candidates), [2]);
        let mut candidates = vec![candidate(1, 1, true, 0), candidate(2, 1, true, 0)];
        assert!(room(&mut candidates, &[2, 0, 0, 0, 0, 1], Some(1)));
        assert_eq!(ids(&candidates), [1]);
        // Full: one that never said who it is makes room first, wherever it is.
        let mut candidates: Vec<Candidate> = (0..MOST_RECEIVERS)
            .map(|n| candidate(n, n as u8 + 10, n != 7, u32::from(n == 7)))
            .collect();
        assert!(room(&mut candidates, &[2, 0, 0, 0, 0, 99], None));
        assert_eq!(candidates.len(), MOST_RECEIVERS - 1);
        assert!(!candidates.iter().any(|c| c.id == 7));
        // Then the one heard of least lately, listed or not: a crowd that went quiet keeps
        // nobody new out. Never the one picked.
        candidates.push(candidate(99, 99, true, 0));
        assert!(room(&mut candidates, &[2, 0, 0, 0, 0, 98], Some(0)));
        assert!(candidates.iter().any(|c| c.id == 0) && !candidates.iter().any(|c| c.id == 1));
        candidates.push(candidate(98, 98, true, 0));
        candidates[0].heard = began + Duration::from_secs(1000);
        assert!(room(&mut candidates, &[2, 0, 0, 0, 0, 97], None));
        assert!(candidates.iter().any(|c| c.id == 0) && !candidates.iter().any(|c| c.id == 2));
    }
}
