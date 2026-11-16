//! AirDrop's sending side: what this computer asks a receiver over HTTPS,
//! and what it makes of the answers. receiver.rs is the other end of each.
//!
//! It posts to /Discover and is told the receiver's name, if the receiver
//! takes AirDrop from it at all: one set to take it from its contacts only
//! answers a sender it cannot find among them with no name, and this
//! computer, with no Apple ID, is found among nobody's. When the user picks
//! the receiver it posts to /Ask what it wants to send (names, kinds, sizes)
//! and waits while the person at the receiver decides; a yes is answered
//! 200, and on the same connection the files follow, to /Upload, as one
//! archive (pack.rs).
//!
//! What a receiver answers is read as a stranger's: bounded, and only its
//! name taken from it, cleaned as a sender's is.

use std::net::{Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::http::Connection;
use crate::pack::Pack;
use crate::plist::{self, Value};
use crate::receiver;
use crate::sys;
use crate::tls;

/// How long a receiver has to take a connection: over AWDL a phone may come by on this channel
/// once a second, and a lost opening is tried again after one, three and seven.
const CONNECT_WITHIN: Duration = Duration::from_secs(15);
/// And to answer anything but the question, which a person answers.
const ANSWER_WITHIN: Duration = Duration::from_secs(15);
/// How long the person at the receiver may take to decide: longer than an iPhone shows the offer.
pub const DECIDE_WITHIN: Duration = Duration::from_secs(150);
/// Files that make no progress for this long: the receiver has stopped taking them.
const STALLED: Duration = Duration::from_secs(30);
/// The connection, the handshake and /Discover, all of it: a receiver that answers a byte at a
/// time is not waited for without end.
const DISCOVER_WITHIN: Duration = Duration::from_secs(20);
/// After the last of the files, for the receiver to say it has them all.
const FINISH_WITHIN: Duration = Duration::from_secs(30);
/// How often a watch looks.
const WATCH_EVERY: Duration = Duration::from_millis(100);
/// The files go in parts of this much, each a step of progress.
const PART: usize = 64 << 10;

/// This computer as a sender.
pub struct Sender {
    pub tls: tls::Client,
    /// What it calls itself to receivers, the kind of computer it says it is, and the instance
    /// its own service goes by this run.
    pub name: String,
    pub model: String,
    pub id: String,
    pub limits: Limits,
}

/// What a receiver said of itself.
#[derive(Debug, Clone, PartialEq)]
pub struct Listing {
    pub name: String,
    pub model: String,
    /// It said its name: it takes AirDrop from this computer.
    pub accepts: bool,
}

/// What the person at the receiver said to the question.
pub enum Answer<'a> {
    /// Yes: the files go on this connection.
    Yes(Connection<tls::Stream<'a>>),
    /// No, with the status it was said with.
    No(u16),
}

/// What kind of file a name is, in Apple's words: a receiver files a photo with the photos.
pub fn kind(name: &str) -> &'static str {
    let extension = name
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .unwrap_or_default();
    match extension.as_str() {
        "jpg" | "jpeg" => "public.jpeg",
        "heic" => "public.heic",
        "heif" => "public.heif",
        "png" => "public.png",
        "gif" => "com.compuserve.gif",
        "webp" => "org.webmproject.webp",
        "tif" | "tiff" => "public.tiff",
        "dng" => "com.adobe.raw-image",
        "mov" => "com.apple.quicktime-movie",
        "mp4" => "public.mpeg-4",
        "m4v" => "com.apple.m4v-video",
        "mp3" => "public.mp3",
        "m4a" => "com.apple.m4a-audio",
        "wav" => "com.microsoft.waveform-audio",
        "pdf" => "com.adobe.pdf",
        "txt" => "public.plain-text",
        "zip" => "public.zip-archive",
        _ => "public.data",
    }
}

/// The question: who asks, and each file by its name, kind and size, at the path it has in the
/// archive.
pub fn question(sender: &Sender, files: &[(String, u64)]) -> Vec<u8> {
    let files = files
        .iter()
        .map(|(name, bytes)| {
            Value::Dict(vec![
                ("FileName".into(), Value::Text(name.clone())),
                ("FileType".into(), Value::Text(kind(name).into())),
                ("FileSize".into(), Value::Int(*bytes as i64)),
                ("FileBomPath".into(), Value::Text(format!("./{name}"))),
                ("FileIsDirectory".into(), Value::Bool(false)),
                ("ConvertMediaFormats".into(), Value::Bool(false)),
            ])
        })
        .collect();
    plist::write(&Value::Dict(vec![
        (
            "SenderComputerName".into(),
            Value::Text(sender.name.clone()),
        ),
        ("SenderModelName".into(), Value::Text(sender.model.clone())),
        ("SenderID".into(), Value::Text(sender.id.clone())),
        ("BundleID".into(), Value::Text("com.apple.finder".into())),
        ("ConvertMediaFormats".into(), Value::Bool(false)),
        ("Items".into(), Value::List(Vec::new())),
        ("Files".into(), Value::List(files)),
    ]))
}

/// What a receiver's answer to /Discover says of it.
pub fn listing(answer: &[u8]) -> Listing {
    let answer = plist::parse(answer).unwrap_or(Value::Other);
    let text = |key: &str| receiver::shown(answer.get(key).and_then(Value::text).unwrap_or(""));
    let name = text("ReceiverComputerName");
    Listing {
        accepts: !name.is_empty(),
        name,
        model: text("ReceiverModelName"),
    }
}

fn words(error: impl std::fmt::Display) -> String {
    error.to_string()
}

/// How long each part of a send may take: the defaults, or a test's.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// For a receiver to be connected to, through the handshake, and to say who it is.
    pub discover: Duration,
    /// For the person at the receiver to decide, from the connection on.
    pub decide: Duration,
    /// For the files to make no progress at all, while they go.
    pub stall: Duration,
    /// For the receiver to say it has everything, once the last of it has gone.
    pub finish: Duration,
}

impl Default for Limits {
    fn default() -> Limits {
        Limits {
            discover: DISCOVER_WITHIN,
            decide: CONNECT_WITHIN + DECIDE_WITHIN + ANSWER_WITHIN,
            stall: STALLED,
            finish: FINISH_WITHIN,
        }
    }
}

/// What ends an exchange with a receiver from outside it: its deadline, its progress stalling,
/// or the user. Each shuts the connection, which ends whatever read or write it is blocked in.
pub struct Watch {
    socket: TcpStream,
    began: Instant,
    /// Microseconds from `began`: when it must be over (u64::MAX for no deadline), and when it
    /// last made progress.
    by: AtomicU64,
    moved: AtomicU64,
    stall: Option<Duration>,
    done: AtomicBool,
    why: Mutex<Option<&'static str>>,
}

impl Watch {
    fn micros(&self, at: Instant) -> u64 {
        at.saturating_duration_since(self.began).as_micros() as u64
    }

    /// It must be over by then.
    pub fn by(&self, deadline: Instant) {
        self.by.store(self.micros(deadline), Ordering::SeqCst);
    }

    /// It made progress.
    pub fn moved(&self) {
        self.moved
            .store(self.micros(Instant::now()), Ordering::SeqCst);
    }

    /// Why it was ended from outside, if it was.
    fn why(&self) -> Option<&'static str> {
        *self.why.lock().unwrap()
    }

    fn look(&self, cancelled: &(dyn Fn() -> bool + Sync)) -> Option<&'static str> {
        let now = self.micros(Instant::now());
        if cancelled() {
            Some("cancelled")
        } else if now >= self.by.load(Ordering::SeqCst) {
            Some("it took too long")
        } else if self.stall.is_some_and(|stall| {
            now >= self.moved.load(Ordering::SeqCst) + stall.as_micros() as u64
        }) {
            Some("it stopped taking the files")
        } else {
            None
        }
    }
}

/// Runs `work` on a connection to a receiver while a thread of its own watches it (Watch), from
/// now until `deadline`. Its error, if the watch ended it, is why.
fn watched<T>(
    socket: &TcpStream,
    deadline: Option<Instant>,
    stall: Option<Duration>,
    cancelled: &(dyn Fn() -> bool + Sync),
    work: impl FnOnce(&Watch) -> Result<T, String>,
) -> Result<T, String> {
    let watch = Watch {
        socket: socket.try_clone().map_err(words)?,
        began: Instant::now(),
        by: AtomicU64::new(u64::MAX),
        moved: AtomicU64::new(0),
        stall,
        done: AtomicBool::new(false),
        why: Mutex::new(None),
    };
    if let Some(deadline) = deadline {
        watch.by(deadline);
    }
    std::thread::scope(|scope| {
        let watching = std::thread::Builder::new()
            .name("airdrop-watch".into())
            .spawn_scoped(scope, || {
                while !watch.done.load(Ordering::SeqCst) {
                    if let Some(why) = watch.look(cancelled) {
                        *watch.why.lock().unwrap() = Some(why);
                        let _ = watch.socket.shutdown(Shutdown::Both);
                        return;
                    }
                    std::thread::sleep(WATCH_EVERY);
                }
            });
        if watching.is_err() {
            return Err("this computer could not start another thread".into());
        }
        let result = work(&watch);
        watch.done.store(true, Ordering::SeqCst);
        // Ended from outside, the connection is shut, whatever the work made of it.
        match watch.why() {
            Some(why) => Err(why.into()),
            None => result,
        }
    })
}

impl Sender {
    /// A connection to a receiver, not yet through the handshake.
    fn connect(at: &SocketAddr, within: Duration) -> Result<TcpStream, String> {
        let stream = TcpStream::connect_timeout(at, within.min(CONNECT_WITHIN))
            .map_err(|error| format!("no connection: {error}"))?;
        let _ = stream.set_nodelay(true);
        let _ = stream.set_read_timeout(Some(ANSWER_WITHIN));
        let _ = stream.set_write_timeout(Some(STALLED));
        sys::roomy(&stream);
        Ok(stream)
    }

    /// The handshake, on a connection that is watched.
    fn handshake(&self, stream: TcpStream) -> Result<Connection<tls::Stream<'_>>, String> {
        let tls = self
            .tls
            .connect(stream)
            .map_err(|error| format!("no handshake: {error}"))?;
        Ok(Connection::new(tls))
    }

    /// Asks a receiver who it is, and whether it takes AirDrop from this computer: all of it,
    /// the connection and the handshake too, within the limit.
    pub fn discover(&self, at: &SocketAddr, host: &str) -> Result<Listing, String> {
        let deadline = Instant::now() + self.limits.discover;
        let stream = Self::connect(at, self.limits.discover)?;
        watched(&stream, Some(deadline), None, &|| false, |_| {
            let mut connection = self.handshake(stream.try_clone().map_err(words)?)?;
            connection
                .post(
                    "/Discover",
                    host,
                    &plist::write(&Value::Dict(Vec::new())),
                    true,
                )
                .map_err(words)?;
            connection.within(Some(ANSWER_WITHIN));
            let reply = connection.reply().map_err(words)?;
            let body = connection
                .body(&reply)
                .and_then(|mut body| body.all(1 << 20))
                .map_err(words)?;
            match reply.status {
                200 => Ok(listing(&body)),
                // Turned away outright: listed as one that does not take it.
                status @ 400..=499 => Ok(Listing {
                    name: format!("a receiver that answered {status}"),
                    model: String::new(),
                    accepts: false,
                }),
                status => Err(format!("it answered {status}")),
            }
        })
    }

    /// Offers the files, and waits for the person at the receiver to decide, or for `cancelled`:
    /// all of it within the limit.
    pub fn ask(
        &self,
        at: &SocketAddr,
        host: &str,
        files: &[(String, u64)],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Answer<'_>, String> {
        let deadline = Instant::now() + self.limits.decide;
        let stream = Self::connect(at, self.limits.decide)?;
        watched(&stream, Some(deadline), None, cancelled, |_| {
            let mut connection = self.handshake(stream.try_clone().map_err(words)?)?;
            connection
                .post("/Ask", host, &question(self, files), false)
                .map_err(words)?;
            let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
            loop {
                if cancelled() {
                    return Err("cancelled".into());
                }
                if connection
                    .arrived()
                    .map_err(|_| "it went away without an answer")?
                {
                    break;
                }
                if Instant::now() >= deadline {
                    return Err("nobody answered".into());
                }
            }
            let _ = stream.set_read_timeout(Some(ANSWER_WITHIN));
            connection.within(Some(ANSWER_WITHIN));
            let reply = connection.reply().map_err(words)?;
            let _ = connection
                .body(&reply)
                .and_then(|mut body| body.all(1 << 20));
            connection.within(None);
            Ok(match reply.status {
                200 => Answer::Yes(connection),
                status => Answer::No(status),
            })
        })
        .map_err(|why| match why.as_str() {
            // The deadline is the decision's: nobody decided in time.
            "it took too long" => "nobody answered".into(),
            _ => why,
        })
    }

    /// The files, on the connection the yes came on; `sent` is told how many bytes of them have
    /// gone, as they go. It ends when they make no progress for the limit's while, when the
    /// receiver does not say it has them all in time after the last, and at `cancelled`.
    pub fn upload(
        &self,
        connection: &mut Connection<tls::Stream<'_>>,
        host: &str,
        pack: &mut Pack,
        sent: &mut dyn FnMut(u64),
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), String> {
        let socket = connection.stream().socket().try_clone().map_err(words)?;
        watched(&socket, None, Some(self.limits.stall), cancelled, |watch| {
            watch.moved();
            connection
                .post_in_pieces("/Upload", host, "application/x-cpio")
                .map_err(words)?;
            while let Some(piece) = pack.piece().map_err(words)? {
                if cancelled() {
                    return Err("cancelled".into());
                }
                // A piece in parts, each progress: a receiver that takes a few bytes now and then
                // is caught by its stall, not let take a piece at a time.
                for part in piece.chunks(PART) {
                    connection.chunk(part).map_err(|error| {
                        format!(
                            "it stopped taking the files after {} bytes: {error}",
                            pack.read
                        )
                    })?;
                    watch.moved();
                }
                sent(pack.read);
            }
            connection.finish().map_err(words)?;
            // The receiver answers once it has unpacked the last of it: by then, and with nothing
            // but its answer, however it trickles it or says to go on.
            let finished = Instant::now();
            watch.by(finished + self.limits.finish);
            let _ = socket.set_read_timeout(Some(Duration::from_millis(250)));
            while !connection
                .arrived()
                .map_err(|_| "it went away before it said it had everything")?
            {
                if cancelled() {
                    return Err("cancelled".into());
                }
                if finished.elapsed() >= self.limits.finish {
                    return Err("it never said it had everything".into());
                }
            }
            let _ = socket.set_read_timeout(Some(ANSWER_WITHIN));
            connection.within(Some(self.limits.finish.saturating_sub(finished.elapsed())));
            let reply = connection.reply().map_err(words)?;
            match reply.status {
                200 => Ok(()),
                status => Err(format!("it answered {status} to the files")),
            }
        })
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::pack::Item;
    use crate::receiver::{Happened, Receiver};
    use std::net::TcpListener;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::AtomicU64;
    use std::sync::{Arc, Mutex};

    pub fn scratch(name: &str) -> PathBuf {
        let folder =
            std::env::temp_dir().join(format!("nova-airdrop-send-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder).unwrap();
        folder
    }

    /// A certificate as the daemon makes its own.
    pub fn identity(folder: &Path) -> (PathBuf, PathBuf) {
        std::fs::create_dir_all(folder).unwrap();
        let (certificate, key) = (folder.join("cert.pem"), folder.join("key.pem"));
        let made = std::process::Command::new("openssl")
            .args([
                "req",
                "-x509",
                "-newkey",
                "ec",
                "-pkeyopt",
                "ec_paramgen_curve:prime256v1",
                "-nodes",
                "-days",
                "2",
                "-subj",
                "/CN=nova",
                "-keyout",
            ])
            .arg(&key)
            .arg("-out")
            .arg(&certificate)
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(made.success());
        (certificate, key)
    }

    pub fn sender(folder: &Path) -> Sender {
        let (certificate, key) = identity(&folder.join("ours"));
        Sender {
            tls: tls::Client::new(&certificate, &key).unwrap(),
            name: "Zoë's Nova".into(),
            model: "Nova".into(),
            id: "0123456789ab".into(),
            limits: Limits::default(),
        }
    }

    /// Nova's own receiver on the loopback, with real TLS, deciding by `yes`; what it told is kept.
    pub fn receiving(
        folder: &Path,
        name: &str,
        yes: bool,
    ) -> (SocketAddr, Arc<Mutex<Vec<Happened>>>) {
        let (certificate, key) = identity(&folder.join("theirs"));
        let told: Arc<Mutex<Vec<Happened>>> = Arc::default();
        let receiver = Arc::new(Receiver {
            tls: tls::Server::new(&certificate, &key).unwrap(),
            name: name.into(),
            model: "Nova".into(),
            folder: folder.join("received"),
            decide: Box::new(move |_, _| yes),
            tell: {
                let told = told.clone();
                Box::new(move |happened| told.lock().unwrap().push(happened))
            },
            questions: AtomicU64::new(0),
        });
        let listener = TcpListener::bind("[::1]:0").unwrap();
        let at = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let receiver = receiver.clone();
                std::thread::spawn(move || receiver.serve_one(stream.unwrap()));
            }
        });
        (at, told)
    }

    fn item(folder: &Path, name: &str, data: &[u8]) -> Item {
        let path = folder.join(format!("source-{name}"));
        std::fs::write(&path, data).unwrap();
        Item {
            name: name.into(),
            file: std::fs::File::open(&path).unwrap(),
            size: data.len() as u64,
            modified: 1_700_000_000,
        }
    }

    #[test]
    fn nova_sends_to_nova_over_tls_and_the_files_arrive_whole() {
        let folder = scratch("whole");
        let (at, told) = receiving(&folder, "Café table", true);
        let sender = sender(&folder);

        let listed = sender.discover(&at, "nova-abcdef.local").unwrap();
        assert_eq!(
            listed,
            Listing {
                name: "Café table".into(),
                model: "Nova".into(),
                accepts: true
            }
        );

        let photo: Vec<u8> = (0..900_000u32).map(|n| (n * 7 % 251) as u8).collect();
        let items = vec![
            item(&folder, "IMG_0001.JPG", &photo),
            item(&folder, "notes.txt", b"hello\n"),
        ];
        let offered: Vec<(String, u64)> = items.iter().map(|i| (i.name.clone(), i.size)).collect();
        let Answer::Yes(mut connection) = sender
            .ask(&at, "nova-abcdef.local", &offered, &|| false)
            .unwrap()
        else {
            panic!("the receiver said yes");
        };
        let mut pack = Pack::new(items).unwrap();
        let mut progress = Vec::new();
        sender
            .upload(
                &mut connection,
                "nova-abcdef.local",
                &mut pack,
                &mut |bytes| progress.push(bytes),
                &|| false,
            )
            .unwrap();
        assert_eq!(progress.last(), Some(&900_006));
        assert!(progress.windows(2).all(|pair| pair[0] <= pair[1]));

        let mut paths = Vec::new();
        for _ in 0..100 {
            if let Some(Happened::Received { paths: got, .. }) = told
                .lock()
                .unwrap()
                .iter()
                .find(|h| matches!(h, Happened::Received { .. }))
            {
                paths = got.clone();
            }
            if !paths.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        paths.sort();
        let into = folder.join("received");
        assert_eq!(
            paths,
            vec![into.join("IMG_0001.JPG"), into.join("notes.txt")]
        );
        assert_eq!(std::fs::read(into.join("IMG_0001.JPG")).unwrap(), photo);
        assert_eq!(std::fs::read(into.join("notes.txt")).unwrap(), b"hello\n");
        // What the receiver was offered is what was sent, under this computer's name.
        let asked = told
            .lock()
            .unwrap()
            .iter()
            .find_map(|h| match h {
                Happened::Asked { offer, .. } => Some(offer.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(asked.sender, "Zoë's Nova");
        assert_eq!(asked.files, offered);
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn a_no_is_a_no_and_a_receiver_that_will_not_list_this_computer_is_said_so() {
        let folder = scratch("no");
        let (at, _) = receiving(&folder, "Elsewhere", false);
        let sender = sender(&folder);
        assert!(matches!(
            sender.ask(&at, "h", &[("a.jpg".into(), 3)], &|| false),
            Ok(Answer::No(403))
        ));
        // A receiver that answers without its name: one set to Contacts Only.
        assert_eq!(
            listing(&plist::write(&Value::Dict(Vec::new()))),
            Listing {
                name: String::new(),
                model: String::new(),
                accepts: false
            }
        );
        assert!(!listing(b"not a list").accepts);
        assert_eq!(
            listing(&plist::write(&Value::Dict(vec![(
                "ReceiverComputerName".into(),
                Value::Text("Zoë\u{202e}s\n iPhone".into())
            )])))
            .name,
            "Zoës iPhone"
        );
        // Nobody there at all.
        let closed = TcpListener::bind("[::1]:0").unwrap().local_addr().unwrap();
        assert!(sender.discover(&closed, "h").is_err());
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn the_question_names_each_file_as_a_receiver_reads_it() {
        let folder = scratch("question");
        let sender = sender(&folder);
        let asked = plist::parse(&question(
            &sender,
            &[("IMG_0001.HEIC".into(), 1_044_468), ("notes".into(), 5)],
        ))
        .unwrap();
        let offer = crate::receiver::offer(&asked);
        assert_eq!(offer.sender, "Zoë's Nova");
        assert_eq!(
            offer.files,
            vec![("IMG_0001.HEIC".into(), 1_044_468), ("notes".into(), 5)]
        );
        let files = asked.get("Files").unwrap().list();
        assert_eq!(
            files[0].get("FileType").and_then(Value::text),
            Some("public.heic")
        );
        assert_eq!(
            files[0].get("FileBomPath").and_then(Value::text),
            Some("./IMG_0001.HEIC")
        );
        assert_eq!(
            files[1].get("FileType").and_then(Value::text),
            Some("public.data")
        );
        assert_eq!(kind("a.JPG"), "public.jpeg");
        assert_eq!(kind("film.mov"), "com.apple.quicktime-movie");
        std::fs::remove_dir_all(&folder).unwrap();
    }

    /// A receiver that takes the TLS handshake and then does as `act` says with the connection.
    fn hostile(
        folder: &Path,
        act: impl Fn(&mut Connection<tls::Stream<'_>>) + Send + Sync + 'static,
    ) -> SocketAddr {
        let (certificate, key) = identity(&folder.join("theirs"));
        let server = Arc::new(tls::Server::new(&certificate, &key).unwrap());
        let act = Arc::new(act);
        let listener = TcpListener::bind("[::1]:0").unwrap();
        let at = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let (server, act) = (server.clone(), act.clone());
                std::thread::spawn(move || {
                    if let Ok(tls) = server.accept(stream.unwrap()) {
                        act(&mut Connection::new(tls));
                    }
                });
            }
        });
        at
    }

    /// Yes to the question, and then nothing read of what follows, ever.
    fn yes_and_then_nothing(connection: &mut Connection<tls::Stream<'_>>) {
        let Ok(Some(head)) = connection.head() else {
            return;
        };
        let _ = connection
            .body(&head)
            .and_then(|mut body| body.all(1 << 20));
        let _ = connection.respond(200, b"", false);
        std::thread::sleep(Duration::from_secs(20));
    }

    /// Files that do not get smaller packed.
    fn noise(folder: &Path, bytes: usize) -> Pack {
        let mut state = 0x9e37_79b9_7f4a_7c15u64;
        let data: Vec<u8> = (0..bytes)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state as u8
            })
            .collect();
        Pack::new(vec![item(folder, "noise.bin", &data)]).unwrap()
    }

    fn quick(folder: &Path) -> Sender {
        let mut sender = sender(folder);
        sender.limits = Limits {
            discover: Duration::from_secs(1),
            decide: Duration::from_secs(5),
            stall: Duration::from_secs(1),
            finish: Duration::from_secs(1),
        };
        sender
    }

    #[test]
    fn a_receiver_that_never_finishes_its_handshake_is_not_waited_for_past_the_limit() {
        let folder = scratch("silent");
        let listener = TcpListener::bind("[::1]:0").unwrap();
        let at = listener.local_addr().unwrap();
        // It takes the connection and says nothing: each read's own timeout is longer than this.
        std::thread::spawn(move || {
            let _held: Vec<_> = listener.incoming().take(1).collect();
            std::thread::sleep(Duration::from_secs(20));
        });
        let began = Instant::now();
        assert_eq!(
            quick(&folder).discover(&at, "h").err().as_deref(),
            Some("it took too long")
        );
        assert!(
            began.elapsed() < Duration::from_secs(3),
            "{:?}",
            began.elapsed()
        );
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn a_receiver_that_says_go_on_for_ever_after_the_files_is_not_waited_for_past_the_limit() {
        let folder = scratch("go-on");
        let at = hostile(&folder, |connection| {
            for _ in 0..2 {
                let Ok(Some(head)) = connection.head() else {
                    return;
                };
                let _ = connection
                    .body(&head)
                    .and_then(|mut body| body.all(64 << 20));
                if head.path == "/Ask" {
                    let _ = connection.respond(200, b"", false);
                }
            }
            for _ in 0..400 {
                if connection.go_on().is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        });
        let sender = quick(&folder);
        let Ok(Answer::Yes(mut connection)) = sender.ask(&at, "h", &[("a".into(), 5)], &|| false)
        else {
            panic!("it said yes");
        };
        let mut pack = Pack::new(vec![item(&folder, "a", b"hello")]).unwrap();
        let began = Instant::now();
        let result = sender.upload(&mut connection, "h", &mut pack, &mut |_| {}, &|| false);
        assert!(result.is_err(), "{result:?}");
        assert!(
            began.elapsed() < Duration::from_secs(4),
            "{:?}",
            began.elapsed()
        );
        std::fs::remove_dir_all(&folder).unwrap();
    }

    #[test]
    fn files_a_receiver_stops_taking_end_after_the_stall_and_at_cancel_at_once() {
        let folder = scratch("stall");
        let at = hostile(&folder, yes_and_then_nothing);
        let sender = quick(&folder);
        let Ok(Answer::Yes(mut connection)) = sender.ask(&at, "h", &[("n".into(), 1)], &|| false)
        else {
            panic!("it said yes");
        };
        let mut pack = noise(&folder, 32 << 20);
        let began = Instant::now();
        let result = sender.upload(&mut connection, "h", &mut pack, &mut |_| {}, &|| false);
        assert_eq!(result.err().as_deref(), Some("it stopped taking the files"));
        assert!(
            began.elapsed() < Duration::from_secs(8),
            "{:?}",
            began.elapsed()
        );

        // Cancelled while a write is blocked: the connection is shut, and that is the end.
        drop(connection);
        let mut patient = sender;
        patient.limits.stall = Duration::from_secs(60);
        let Ok(Answer::Yes(mut connection)) = patient.ask(&at, "h", &[("n".into(), 1)], &|| false)
        else {
            panic!("it said yes");
        };
        let mut pack = noise(&folder, 32 << 20);
        let began = Instant::now();
        let cancelled = || began.elapsed() >= Duration::from_secs(2);
        let result = patient.upload(&mut connection, "h", &mut pack, &mut |_| {}, &cancelled);
        assert_eq!(result.err().as_deref(), Some("cancelled"));
        assert!(
            began.elapsed() < Duration::from_secs(4),
            "{:?}",
            began.elapsed()
        );
        std::fs::remove_dir_all(&folder).unwrap();
    }
}
