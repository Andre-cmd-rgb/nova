//! AirDrop's receiving side: what a sender asks over HTTPS, and what it is
//! answered.
//!
//! A sender that sees the service connects and posts to /Discover: the answer
//! is this computer's name, and puts it in the sender's list. When its owner
//! picks this computer it posts to /Ask what it wants to send, and waits; a
//! yes is answered with the name again, and on the same connection it then
//! posts the files themselves to /Upload, as one archive.
//!
//! Everything a sender says is read as what a stranger says: sizes are
//! bounded, names are shown but never used as paths except through the
//! unpacker's own checks, what is slow beyond any phone's slowness is not
//! waited for, and no sender has more than a few connections.
//!
//! Each question gets a number, and what is told of it afterwards carries
//! that number: several senders may be talking at once, and whoever shows
//! one transfer must not take another's end for its own.

use std::collections::HashMap;
use std::io::Read;
use std::net::{Ipv6Addr, SocketAddr, TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::http::Connection;
use crate::plist::{self, Value};
use crate::sys;
use crate::tls;
use crate::unpack::{Archive, Landing, Packing};

/// What a sender wants to send.
#[derive(Debug, Clone, PartialEq)]
pub struct Offer {
    /// The sender's name for itself, cleaned of anything but text.
    pub sender: String,
    /// (name, bytes) of each file or folder.
    pub files: Vec<(String, u64)>,
    pub bytes: u64,
    pub links: Vec<String>,
}

/// What happened, for whoever shows it. `question` is the number of the question it is about.
#[derive(Debug, Clone, PartialEq)]
pub enum Happened {
    /// A sender was told this computer's name: it is in that sender's list now.
    Listed,
    Asked {
        question: u64,
        offer: Offer,
    },
    Declined {
        question: u64,
        offer: Offer,
    },
    Receiving {
        question: u64,
        bytes: u64,
        of: u64,
    },
    Received {
        question: u64,
        paths: Vec<PathBuf>,
        bytes: u64,
        seconds: f64,
    },
    Links {
        question: u64,
        links: Vec<String>,
    },
    /// A connection that came to nothing: with a question's number if it had been told yes.
    Failed {
        question: Option<u64>,
        why: String,
    },
}

pub type Decide = Box<dyn Fn(u64, &Offer) -> bool + Send + Sync>;

pub struct Receiver {
    pub tls: tls::Server,
    /// What senders see this computer as, and what kind of computer they draw for it.
    pub name: String,
    pub model: String,
    pub folder: PathBuf,
    /// Whether to take what is offered, by the question's number. May take as long as a person takes.
    pub decide: Decide,
    pub tell: Box<dyn Fn(Happened) + Send + Sync>,
    /// The number of the last question asked.
    pub questions: AtomicU64,
}

/// Connections at once: a sender uses two, and this many are for several senders.
const MOST_CONNECTIONS: usize = 16;
/// And of those, to one address.
const MOST_TO_ONE: usize = 4;
/// A question at its largest: the files' names and sizes, and a picture of the first. One photo's
/// is an eighth of a megabyte.
const QUESTION_LIMIT: usize = 8 << 20;
/// How long a question has to arrive, and a handshake each of its steps.
const QUESTION_WITHIN: Duration = Duration::from_secs(60);
const HANDSHAKE_STEP: Duration = Duration::from_secs(10);
/// An upload that brings less than this in this long has stopped: a phone on its sparsest
/// timetable brings a hundred times as much.
const SLOWEST: u64 = 32 << 10;
const SLOWEST_OVER: Duration = Duration::from_secs(30);

/// A failure with its question's number, if the connection had one open.
struct Failure(Option<u64>, String);

fn failed(question: Option<u64>) -> impl Fn(std::io::Error) -> Failure {
    move |error| Failure(question, error.to_string())
}

/// Counts a connection from `from` in, if there is room for it: false for one over the most, in
/// all or from that address. One turned away leaves nothing behind: addresses cost a stranger
/// nothing to make up.
fn admitted(open: &mut HashMap<Ipv6Addr, usize>, from: Ipv6Addr) -> bool {
    let all: usize = open.values().sum();
    if all >= MOST_CONNECTIONS || open.get(&from).is_some_and(|theirs| *theirs >= MOST_TO_ONE) {
        return false;
    }
    *open.entry(from).or_insert(0) += 1;
    true
}

/// A name a stranger gave, made fit to show: one line, nothing that is not shown as itself
/// (unpack::hidden), not endless.
pub(crate) fn shown(text: &str) -> String {
    text.chars()
        .filter(|&c| !crate::unpack::hidden(c))
        .take(80)
        .collect::<String>()
        .trim()
        .to_owned()
}

pub(crate) fn offer(asked: &Value) -> Offer {
    let files: Vec<(String, u64)> = asked
        .get("Files")
        .map(Value::list)
        .unwrap_or_default()
        .iter()
        .take(10_000)
        .map(|file| {
            (
                shown(file.get("FileName").and_then(Value::text).unwrap_or("?")),
                file.get("FileSize")
                    .and_then(Value::int)
                    .unwrap_or(0)
                    .max(0) as u64,
            )
        })
        .collect();
    Offer {
        sender: shown(
            asked
                .get("SenderComputerName")
                .and_then(Value::text)
                .unwrap_or(""),
        ),
        // Sizes are a stranger's, and theirs to make add up past what a number holds.
        bytes: files
            .iter()
            .fold(0u64, |all, (_, bytes)| all.saturating_add(*bytes)),
        files,
        links: asked
            .get("Items")
            .map(Value::list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::text)
            .take(100)
            .map(shown)
            .collect(),
    }
}

/// Reads what a sender still sends after it has its answer, for two seconds at most, so that the
/// connection ends as an end and not as a reset that could overtake the answer.
fn finish(connection: &mut Connection<tls::Stream<'_>>) {
    let _ = connection
        .stream()
        .socket()
        .set_read_timeout(Some(Duration::from_secs(2)));
    connection.drain();
}

impl Receiver {
    fn names(&self, more: Vec<(String, Value)>) -> Vec<u8> {
        let mut answer = vec![
            (
                "ReceiverComputerName".to_owned(),
                Value::Text(self.name.clone()),
            ),
            (
                "ReceiverModelName".to_owned(),
                Value::Text(self.model.clone()),
            ),
        ];
        answer.extend(more);
        plist::write(&Value::Dict(answer))
    }

    /// Takes connections for as long as the process lives, each on a thread of its own.
    pub fn serve(self: Arc<Self>, listener: TcpListener) {
        // A whole burst of a sender fits: see sys::roomy. Connections taken from here on inherit it.
        sys::roomy(&listener);
        // How many are open, by the address at their other end.
        let open: Arc<Mutex<HashMap<Ipv6Addr, usize>>> = Arc::default();
        for stream in listener.incoming() {
            let Ok(stream) = stream else { continue };
            // AirDrop is spoken between link-local addresses and nothing else.
            let from = match stream.peer_addr() {
                Ok(SocketAddr::V6(address)) if address.ip().segments()[0] & 0xffc0 == 0xfe80 => {
                    *address.ip()
                }
                _ => continue,
            };
            if !admitted(&mut open.lock().unwrap(), from) {
                continue;
            }
            let let_go = move |open: &Mutex<HashMap<Ipv6Addr, usize>>| {
                let mut open = open.lock().unwrap();
                if let Some(theirs) = open.get_mut(&from) {
                    *theirs -= 1;
                    if *theirs == 0 {
                        open.remove(&from);
                    }
                }
            };
            let (receiver, counted) = (self.clone(), open.clone());
            let connection = std::thread::Builder::new().name("airdrop-sender".into());
            let started = connection.spawn(move || {
                receiver.serve_one(stream);
                let_go(&counted);
            });
            // One this computer cannot give a thread to is let go, as one over the most.
            if started.is_err() {
                let_go(&open);
            }
        }
    }

    /// One connection a sender made, whatever came of it told.
    pub fn serve_one(&self, stream: TcpStream) {
        if let Err(Failure(question, why)) = self.connection(stream) {
            (self.tell)(Happened::Failed { question, why });
        }
    }

    /// One connection, from its handshake to its end. An error is something worth telling: a sender
    /// going away between requests is not one.
    fn connection(&self, stream: TcpStream) -> Result<(), Failure> {
        let _ = stream.set_nodelay(true);
        let _ = stream.set_read_timeout(Some(HANDSHAKE_STEP));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(20)));
        sys::acknowledge_at_once(stream.as_raw_fd());
        let Ok(stream) = self.tls.accept(stream) else {
            return Ok(());
        };
        // Between requests a sender may be quiet for a while: a phone keeps its first connection open.
        let _ = stream
            .socket()
            .set_read_timeout(Some(Duration::from_secs(30)));
        let mut connection = Connection::new(stream);
        // The question this connection was told yes to, and owes an upload for.
        let mut accepted: Option<(u64, Offer)> = None;
        loop {
            let question = accepted.as_ref().map(|(question, _)| *question);
            let head = match connection.head() {
                Ok(Some(head)) => head,
                // Gone, or silent for too long, between requests: a sender that asked and got a yes owes an upload.
                _ if question.is_some() => {
                    return Err(Failure(
                        question,
                        "the sender asked, was told yes, and sent nothing".into(),
                    ))
                }
                _ => return Ok(()),
            };
            if head.expects_continue() {
                connection.go_on().map_err(failed(question))?;
            }
            match (head.method.as_str(), head.path.as_str()) {
                ("POST", "/Discover") => {
                    // What it says of itself is for receivers that only show themselves to their contacts. This one shows itself to whoever looks.
                    connection.within(Some(QUESTION_WITHIN));
                    let mut body = connection.body(&head).map_err(failed(question))?;
                    body.all(1 << 20).map_err(failed(question))?;
                    connection.within(None);
                    let answer = self.names(vec![
                        ("IsAirDropable".into(), Value::Bool(true)),
                        (
                            "ReceiverMediaCapabilities".into(),
                            Value::Data(br#"{"Version": 1}"#.to_vec()),
                        ),
                    ]);
                    connection
                        .respond(200, &answer, head.closes())
                        .map_err(failed(question))?;
                    (self.tell)(Happened::Listed);
                    if head.closes() {
                        finish(&mut connection);
                        return Ok(());
                    }
                }
                // One question to a connection: a second would leave the first's upload owed for good.
                ("POST", "/Ask") if question.is_none() => {
                    let unread = |error: &dyn std::fmt::Display| {
                        Failure(
                            None,
                            format!("the sender's question could not be read: {error}"),
                        )
                    };
                    connection.within(Some(QUESTION_WITHIN));
                    let mut body = connection.body(&head).map_err(|e| unread(&e))?;
                    let asked = body.all(QUESTION_LIMIT).map_err(|e| unread(&e))?;
                    connection.within(None);
                    let asked = plist::parse(&asked).map_err(|e| unread(&e))?;
                    let offered = offer(&asked);
                    if offered.files.is_empty() && offered.links.is_empty() {
                        let _ = connection.respond(400, b"", true);
                        return Err(Failure(None, "the sender asked to send nothing".into()));
                    }
                    let question = self.questions.fetch_add(1, Ordering::SeqCst) + 1;
                    (self.tell)(Happened::Asked {
                        question,
                        offer: offered.clone(),
                    });
                    if !(self.decide)(question, &offered) {
                        let _ = connection.respond(403, b"", true);
                        (self.tell)(Happened::Declined {
                            question,
                            offer: offered,
                        });
                        finish(&mut connection);
                        return Ok(());
                    }
                    connection
                        .respond(200, &self.names(Vec::new()), false)
                        .map_err(failed(Some(question)))?;
                    if offered.files.is_empty() {
                        // Links are in the question itself: there is nothing to upload.
                        (self.tell)(Happened::Links {
                            question,
                            links: offered.links,
                        });
                        return Ok(());
                    }
                    accepted = Some((question, offered));
                }
                ("POST", "/Upload") => {
                    let Some((question, offered)) = accepted.take() else {
                        let _ = connection.respond(400, b"", true);
                        return Err(Failure(None, "an upload nobody was asked about".into()));
                    };
                    return match self.upload(&mut connection, &head, question, &offered) {
                        Ok(received) => {
                            (self.tell)(received);
                            finish(&mut connection);
                            Ok(())
                        }
                        Err(error) => {
                            let _ = connection.respond(500, b"", true);
                            Err(Failure(
                                Some(question),
                                format!("receiving from {} failed: {error}", offered.sender),
                            ))
                        }
                    };
                }
                // Anything else is not AirDrop's, and ends the connection: its body, if it has one, is not read as a request.
                _ => {
                    let status = if head.method == "POST" { 400 } else { 405 };
                    let _ = connection.respond(status, b"", true);
                    return match question {
                        Some(_) => Err(Failure(
                            question,
                            "the sender asked, was told yes, and sent something else".into(),
                        )),
                        None => Ok(()),
                    };
                }
            }
        }
    }

    /// The upload, unpacked as it arrives, and answered the moment the archive is whole and in place.
    fn upload(
        &self,
        connection: &mut Connection<tls::Stream<'_>>,
        head: &crate::http::Head,
        question: u64,
        offered: &Offer,
    ) -> Result<Happened, String> {
        let began = Instant::now();
        let text = |error: &dyn std::fmt::Display| error.to_string();
        let landing =
            Landing::new(&self.folder).map_err(|e| format!("{}: {e}", self.folder.display()))?;
        let mut archive = Archive::new(&landing, offered.bytes);
        let mut packing =
            Packing::of(head.header("content-type").unwrap_or("")).map_err(|e| text(&e))?;
        let _ = connection
            .stream()
            .socket()
            .set_read_timeout(Some(Duration::from_secs(20)));
        let mut piece = vec![0u8; 256 << 10];
        let socket = connection.stream().socket().as_raw_fd();
        let (mut arrived, mut told) = (0u64, Instant::now());
        // What may arrive in all, packed: no more than may be unpacked, and a little for the packing.
        let most = Archive::most(offered.bytes).saturating_add(32 << 20);
        let (mut lap, mut at_lap) = (Instant::now(), 0u64);
        {
            let mut body = connection.body(head).map_err(|e| text(&e))?;
            while !archive.done() {
                let size = body
                    .read(&mut piece)
                    .map_err(|e| format!("after {arrived} bytes: {e}"))?;
                if size == 0 {
                    return Err(format!(
                        "the upload ended after {arrived} bytes, before its archive did"
                    ));
                }
                sys::acknowledge_at_once(socket);
                arrived += size as u64;
                if arrived > most {
                    return Err(format!(
                        "the upload is larger than the {} bytes of files it was said to be",
                        offered.bytes
                    ));
                }
                if lap.elapsed() >= SLOWEST_OVER {
                    if arrived - at_lap < SLOWEST {
                        return Err(format!("the upload all but stopped after {arrived} bytes"));
                    }
                    (lap, at_lap) = (Instant::now(), arrived);
                }
                packing
                    .feed(&piece[..size], &mut |plain| archive.feed(plain))
                    .map_err(|e| text(&e))?;
                if told.elapsed() >= Duration::from_millis(250) {
                    told = Instant::now();
                    (self.tell)(Happened::Receiving {
                        question,
                        bytes: archive.bytes.min(arrived),
                        of: offered.bytes,
                    });
                }
            }
        }
        // The answer goes while the sender is still here to hear it: it leaves the channel when it has sent its last byte.
        let bytes = archive.bytes;
        drop(archive);
        let paths = landing.keep().map_err(|e| text(&e))?;
        connection.respond(200, b"", true).map_err(|e| text(&e))?;
        Ok(Happened::Received {
            question,
            paths,
            bytes,
            seconds: began.elapsed().as_secs_f64(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connections_over_the_most_are_turned_away_and_leave_nothing_behind() {
        let mut open = HashMap::new();
        let address = |n: u16| Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, n);
        for _ in 0..MOST_TO_ONE {
            assert!(admitted(&mut open, address(1)));
        }
        assert!(!admitted(&mut open, address(1)));
        for n in 2..=(MOST_CONNECTIONS - MOST_TO_ONE) as u16 + 1 {
            assert!(admitted(&mut open, address(n)));
        }
        // Full: a stranger at a new address each time is not counted in.
        for n in 1000..1100 {
            assert!(!admitted(&mut open, address(n)));
        }
        assert_eq!(open.len(), 1 + MOST_CONNECTIONS - MOST_TO_ONE);
        assert_eq!(open.values().sum::<usize>(), MOST_CONNECTIONS);
    }

    #[test]
    fn an_offer_is_read_from_what_a_sender_asks() {
        let asked = Value::Dict(vec![
            (
                "SenderComputerName".into(),
                Value::Text("Zoë's\u{7} iPhone\n".into()),
            ),
            (
                "Files".into(),
                Value::List(vec![
                    Value::Dict(vec![
                        ("FileName".into(), Value::Text("IMG_0001.HEIC".into())),
                        ("FileSize".into(), Value::Int(1_044_468)),
                    ]),
                    Value::Dict(vec![
                        ("FileName".into(), Value::Text("x".repeat(500))),
                        ("FileSize".into(), Value::Int(-5)),
                    ]),
                    Value::Text("not a file".into()),
                ]),
            ),
            (
                "Items".into(),
                Value::List(vec![
                    Value::Text("https://example.org/".into()),
                    Value::Int(3),
                ]),
            ),
        ]);
        let offered = offer(&asked);
        assert_eq!(offered.sender, "Zoë's iPhone");
        assert_eq!(shown("photo\u{202e}gpj.sh\u{2069}"), "photogpj.sh");
        assert_eq!(offered.files[0], ("IMG_0001.HEIC".to_owned(), 1_044_468));
        assert_eq!((offered.files[1].0.len(), offered.files[1].1), (80, 0));
        assert_eq!(offered.files[2], ("?".to_owned(), 0));
        assert_eq!(
            (offered.bytes, offered.links.as_slice()),
            (1_044_468, &["https://example.org/".to_owned()][..])
        );
        // Sizes that add up past what a number holds are as large as it holds, not small again.
        let huge = Value::Dict(vec![("FileSize".into(), Value::Int(i64::MAX))]);
        let asked = Value::Dict(vec![("Files".into(), Value::List(vec![huge; 3]))]);
        assert_eq!(offer(&asked).bytes, u64::MAX);
        // Something that is no question at all.
        assert_eq!(
            offer(&Value::Int(1)),
            Offer {
                sender: String::new(),
                files: Vec::new(),
                bytes: 0,
                links: Vec::new()
            }
        );
    }
}
