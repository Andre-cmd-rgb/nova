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

use std::net::{SocketAddr, TcpStream};
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
/// A write the receiver takes nothing of for this long: it has stopped.
const STALLED: Duration = Duration::from_secs(30);

/// This computer as a sender.
pub struct Sender {
    pub tls: tls::Client,
    /// What it calls itself to receivers, the kind of computer it says it is, and the instance
    /// its own service goes by this run.
    pub name: String,
    pub model: String,
    pub id: String,
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

impl Sender {
    /// A connection to a receiver, through the handshake.
    fn open(&self, at: &SocketAddr) -> Result<Connection<tls::Stream<'_>>, String> {
        let stream = TcpStream::connect_timeout(at, CONNECT_WITHIN)
            .map_err(|error| format!("no connection: {error}"))?;
        let _ = stream.set_nodelay(true);
        let _ = stream.set_read_timeout(Some(ANSWER_WITHIN));
        let _ = stream.set_write_timeout(Some(STALLED));
        sys::roomy(&stream);
        let tls = self
            .tls
            .connect(stream)
            .map_err(|error| format!("no handshake: {error}"))?;
        Ok(Connection::new(tls))
    }

    /// Asks a receiver who it is, and whether it takes AirDrop from this computer.
    pub fn discover(&self, at: &SocketAddr, host: &str) -> Result<Listing, String> {
        let mut connection = self.open(at)?;
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
    }

    /// Offers the files, and waits for the person at the receiver to decide, or for `cancelled`.
    pub fn ask(
        &self,
        at: &SocketAddr,
        host: &str,
        files: &[(String, u64)],
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Answer<'_>, String> {
        let mut connection = self.open(at)?;
        connection
            .post("/Ask", host, &question(self, files), false)
            .map_err(words)?;
        let _ = connection
            .stream()
            .socket()
            .set_read_timeout(Some(Duration::from_millis(250)));
        let asked = Instant::now();
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
            if asked.elapsed() >= DECIDE_WITHIN {
                return Err("nobody answered".into());
            }
        }
        let _ = connection
            .stream()
            .socket()
            .set_read_timeout(Some(ANSWER_WITHIN));
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
    }

    /// The files, on the connection the yes came on; `sent` is told how many bytes of them have
    /// gone, as they go.
    pub fn upload(
        &self,
        connection: &mut Connection<tls::Stream<'_>>,
        host: &str,
        pack: &mut Pack,
        sent: &mut dyn FnMut(u64),
        cancelled: &dyn Fn() -> bool,
    ) -> Result<(), String> {
        connection
            .post_in_pieces("/Upload", host, "application/x-cpio")
            .map_err(words)?;
        while let Some(piece) = pack.piece().map_err(words)? {
            if cancelled() {
                return Err("cancelled".into());
            }
            connection.chunk(&piece).map_err(|error| {
                format!(
                    "it stopped taking the files after {} bytes: {error}",
                    pack.read
                )
            })?;
            sent(pack.read);
        }
        connection.finish().map_err(words)?;
        // The receiver answers once it has unpacked the last of it.
        let _ = connection
            .stream()
            .socket()
            .set_read_timeout(Some(Duration::from_millis(250)));
        let finished = Instant::now();
        while !connection
            .arrived()
            .map_err(|_| "it went away before it said it had everything")?
        {
            if cancelled() {
                return Err("cancelled".into());
            }
            if finished.elapsed() >= STALLED {
                return Err("it never said it had everything".into());
            }
        }
        let _ = connection
            .stream()
            .socket()
            .set_read_timeout(Some(ANSWER_WITHIN));
        let reply = connection.reply().map_err(words)?;
        match reply.status {
            200 => Ok(()),
            status => Err(format!("it answered {status} to the files")),
        }
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
}
