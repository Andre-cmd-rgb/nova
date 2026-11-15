//! nova-airdropd: Nova as an AirDrop receiver.
//!
//! Started with a Wi-Fi card already set up for it (an ad-hoc cell on AWDL's
//! channel that acknowledges for this node's address, and a monitor
//! interface: nova-airdrop-radio's work, as root), it is an AWDL node on the
//! air and an AirDrop receiver on top: phones nearby see this computer in
//! their AirDrop sheet, and what they send lands in a folder.
//!
//!   nova-airdropd --monitor <interface>
//!                 [--name <shown to senders>] [--model <kind of computer>]
//!                 [--folder <where files land>] [--identity <folder>]
//!                 [--country <two letters>] [--channel <number>]
//!                 [--control <socket>] [--accept-all]
//!                 [--once] [--give-up-after <seconds>]
//!
//! It runs as the person whose files they will be, with one capability
//! (CAP_NET_RAW, for the socket on the monitor interface), and gives that up
//! with everything else of the system's network when it has the socket: see
//! sys.rs. Its certificate is its own, made on the first run and kept in
//! --identity (by default nova/airdrop under the user's state folder).
//!
//! The name is the computer's, the folder the user's downloads, the country
//! NOVA_AIRDROP_COUNTRY's, unless it is told otherwise. What is offered is put
//! to the user over the control socket (control.rs; `nova airdrop` and the
//! shell are at its other end), and taken unasked with --accept-all.
//!
//! --give-up-after ends the daemon when nobody has asked for that long, and
//! --once a moment after the first transfer has ended, either way: the Wi-Fi
//! is off the network while this runs, and should not be for long. A client
//! that says `stay` on the control socket takes --once back (control.rs).
//!
//! What it logs goes to standard error, a line an event.

mod control;
mod defaults;
mod http;
mod meet;
mod node;
mod packet;
mod plist;
mod receiver;
mod sys;
mod tls;
mod unpack;
mod wire;

use std::io::Write;
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use control::Control;
use node::{Event, Node, Settings};
use receiver::{Happened, Receiver};
use wire::Mac;

const PORT: u16 = 8771;
/// What fits in an AWDL data frame with room to spare; an iPhone's own is 1450.
const MTU: u32 = 1450;
/// How long after a transfer's end --once ends the daemon: the sender has its answer by then.
const AFTER_THE_LAST: u64 = 2_000_000;
/// How long what happened to a transfer is shown before a daemon that stays on says it waits again.
const SHOWN_FOR: u64 = 8_000_000;
/// How many of the peers' comings and goings are logged in a second.
const MOST_NOTED: u32 = 12;

struct Options {
    monitor: Option<String>,
    air_fd: Option<i32>,
    own_namespace: bool,
    tap: String,
    address: Option<Mac>,
    name: String,
    model: String,
    folder: PathBuf,
    identity: PathBuf,
    country: [u8; 2],
    channel: u8,
    control: PathBuf,
    accept_all: bool,
    once: bool,
    give_up_after: Option<u64>,
}

fn usage() -> String {
    // The comment at the top of this file, from its fifth paragraph's command to the options' meaning.
    include_str!("main.rs")
        .lines()
        .skip(1)
        .take_while(|line| line.starts_with("//!"))
        .map(|line| line.trim_start_matches("//!").trim_start_matches(' '))
        .collect::<Vec<_>>()
        .join("\n")
}

fn mac(text: &str) -> Option<Mac> {
    let parts: Vec<u8> = text
        .split(':')
        .filter_map(|part| u8::from_str_radix(part, 16).ok())
        .collect();
    parts.try_into().ok()
}

fn options() -> Result<Options, String> {
    // Whose files they will be says where they go: nothing is guessed for a user without a home.
    let home = match std::env::var_os("HOME") {
        Some(home) if !home.is_empty() => PathBuf::from(home),
        _ => return Err("HOME is not set: whose downloads would this be?".into()),
    };
    let mut o = Options {
        monitor: None,
        air_fd: None,
        own_namespace: true,
        tap: "awdl0".into(),
        address: None,
        name: defaults::name(),
        model: "Nova".into(),
        folder: defaults::folder(&home),
        identity: match std::env::var_os("XDG_STATE_HOME") {
            Some(folder) if !folder.is_empty() => PathBuf::from(folder),
            _ => home.join(".local/state"),
        }
        .join("nova/airdrop"),
        country: defaults::country(&std::env::var("NOVA_AIRDROP_COUNTRY").unwrap_or_default()),
        channel: 6,
        control: meet::socket(),
        accept_all: false,
        once: false,
        give_up_after: None,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "--monitor" => o.monitor = Some(value()?),
            // For tests: a socket to a made-up radio, a namespace already private.
            "--air-fd" => o.air_fd = Some(value()?.parse().map_err(|_| "--air-fd takes a number")?),
            "--same-namespace" => o.own_namespace = false,
            "--tap" => o.tap = value()?,
            "--address" => {
                o.address = Some(mac(&value()?).ok_or("--address takes six hex bytes with colons")?)
            }
            "--name" => o.name = value()?,
            "--model" => o.model = value()?,
            "--folder" => o.folder = value()?.into(),
            "--identity" => o.identity = value()?.into(),
            "--country" => o.country = defaults::country(&value()?),
            "--channel" => o.channel = value()?.parse().map_err(|_| "--channel takes a number")?,
            "--control" => o.control = value()?.into(),
            "--accept-all" => o.accept_all = true,
            "--once" => o.once = true,
            "--give-up-after" => {
                o.give_up_after = Some(
                    value()?
                        .parse()
                        .map_err(|_| "--give-up-after takes seconds")?,
                )
            }
            _ => return Err(format!("unknown option {arg}\n\n{}", usage())),
        }
    }
    if o.monitor.is_none() == o.air_fd.is_none() {
        return Err(format!("one of --monitor and --air-fd\n\n{}", usage()));
    }
    Ok(o)
}

/// The certificate and key this computer shows to senders, made the first time they are asked for.
/// AirDrop's receivers sign their own; the name in it is not shown to anybody.
fn identity(folder: &std::path::Path) -> Result<(PathBuf, PathBuf), String> {
    use std::os::unix::fs::DirBuilderExt;
    let (certificate, key) = (folder.join("certificate.pem"), folder.join("key.pem"));
    if certificate.exists() && key.exists() {
        return Ok((certificate, key));
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(folder)
        .map_err(|e| format!("{}: {e}", folder.display()))?;
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
            "3650",
            "-subj",
            "/CN=nova",
            "-keyout",
        ])
        .arg(&key)
        .arg("-out")
        .arg(&certificate)
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("openssl, to make this computer's certificate: {e}"))?;
    if !made.status.success() {
        return Err(format!(
            "openssl would not make a certificate: {}",
            String::from_utf8_lossy(&made.stderr).trim()
        ));
    }
    Ok((certificate, key))
}

fn text(address: &Mac) -> String {
    address
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<Vec<_>>()
        .join(":")
}

/// The folder the control socket goes in, made if the runtime folder is there for it to be made in.
fn meeting_place(socket: &std::path::Path) -> Result<(), String> {
    use std::os::unix::fs::DirBuilderExt;
    let folder = socket.parent().ok_or("--control takes a path")?;
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(folder)
        .or_else(|error| match error.kind() {
            std::io::ErrorKind::AlreadyExists => Ok(()),
            _ => Err(error),
        })
        .map_err(|error| {
            format!(
                "{}: {error} (is this user logged in? Nobody could be asked what to accept)",
                folder.display()
            )
        })
}

fn run() -> Result<(), String> {
    let o = options()?;
    let started = Instant::now();
    // Whoever read the log may be gone (a terminal closed): that is no reason to stop.
    let log = move |line: String| {
        let _ = writeln!(
            std::io::stderr(),
            "{:7.2} s  {line}",
            started.elapsed().as_secs_f64()
        );
    };

    // The socket on the monitor interface first: it stays in the namespace the card is in.
    let (air, address) = match (&o.monitor, o.air_fd) {
        (Some(interface), _) => {
            let address = match o.address {
                Some(address) => address,
                None => sys::hardware_address(interface).map_err(|e| e.to_string())?,
            };
            (
                sys::Air::monitor(interface).map_err(|e| e.to_string())?,
                address,
            )
        }
        (None, Some(fd)) => (
            sys::Air::inherited(fd),
            o.address.ok_or("--air-fd needs --address")?,
        ),
        _ => unreachable!(),
    };
    // The certificate while the files of the system are still as they were named, and systemd's ear.
    let (certificate, key) = identity(&o.identity)?;
    let tls = tls::Server::new(&certificate, &key)?;
    let notify = sys::Notify::connect();
    // A daemon that takes everything can do without anybody to ask.
    let asks = match meeting_place(&o.control) {
        Ok(()) => true,
        Err(why) if o.accept_all => {
            log(format!("nobody will be told how it goes: {why}"));
            false
        }
        Err(why) => return Err(why),
    };
    if o.own_namespace {
        sys::own_namespace().map_err(|e| e.to_string())?;
    }
    let tap = sys::Tap::open(&o.tap, &address, MTU).map_err(|e| e.to_string())?;
    let listener = TcpListener::bind(("::", PORT)).map_err(|e| format!("port {PORT}: {e}"))?;
    sys::stop_on_signals();
    let control = Control::new(&o.name);
    if asks {
        control.listen(&o.control)?;
    }
    // This is the one daemon receiving into the folder: what an earlier one that was killed left
    // half-unpacked in it goes.
    unpack::sweep(&o.folder);

    // The service's instance and this node's name on the link: made up for each run, as an iPhone's are.
    let mut random = [0u8; 6];
    std::io::Read::read_exact(
        &mut std::fs::File::open("/dev/urandom").map_err(|e| e.to_string())?,
        &mut random,
    )
    .map_err(|e| e.to_string())?;
    let instance: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let settings = Settings {
        address,
        host: format!("nova-{}", &instance[..6]),
        instance,
        port: PORT,
        country: o.country,
        channel: o.channel,
        manner: wire::Manner::default(),
    };
    log(format!(
        "this computer is {:?} to senders, {} on the air (channel {}), {} on {}; what they send goes to {}",
        o.name,
        text(&address),
        o.channel,
        settings.host,
        tap.name(),
        o.folder.display()
    ));

    // When this ends by itself: a moment after a transfer has (--once), or when nobody has asked
    // for long enough (--give-up-after), counted from the start and from each transfer's end.
    let ending = Arc::new(AtomicU64::new(u64::MAX));
    let quiet_since = Arc::new(AtomicU64::new(0));
    let (accept_all, once) = (o.accept_all, o.once);
    let receiver = Arc::new(Receiver {
        tls,
        name: o.name.clone(),
        model: o.model.clone(),
        folder: o.folder.clone(),
        decide: {
            let control = control.clone();
            Box::new(move |question, offer| control.ask(question, offer, accept_all))
        },
        tell: {
            let (ending, quiet_since, control) =
                (ending.clone(), quiet_since.clone(), control.clone());
            Box::new(move |happened| {
                // The end of the question that was open, whichever way, starts the count to this
                // daemon's own end; what another sender's connection came to meanwhile does not.
                if control.happened(&happened) {
                    let now = started.elapsed().as_micros() as u64;
                    quiet_since.store(now, Ordering::SeqCst);
                    if once && !control.stays() {
                        ending.store(now + AFTER_THE_LAST, Ordering::SeqCst);
                    }
                }
                match happened {
                    Happened::Listed => log(
                        "a sender was told this computer's name: it is in that sender's list"
                            .into(),
                    ),
                    Happened::Asked { question, offer } => log(format!(
                        "question {question}: {:?} asks to send {}",
                        offer.sender,
                        control::offered(&offer)
                    )),
                    Happened::Declined { question, .. } => {
                        log(format!("question {question}: declined"))
                    }
                    Happened::Receiving {
                        question,
                        bytes,
                        of,
                    } => log(format!(
                        "question {question}: receiving, {} of {}",
                        control::size(bytes),
                        control::size(of)
                    )),
                    Happened::Received {
                        question,
                        paths,
                        bytes,
                        seconds,
                    } => log(format!(
                        "question {question}: received {} in {seconds:.2} s ({:.0} kB/s): {}",
                        control::size(bytes),
                        bytes as f64 / 1024.0 / seconds.max(0.001),
                        paths
                            .iter()
                            .map(|path| path.display().to_string())
                            .collect::<Vec<_>>()
                            .join(", ")
                    )),
                    Happened::Links { question, links } => {
                        log(format!("question {question}: links: {}", links.join(" ")))
                    }
                    Happened::Failed { question, why } => log(match question {
                        Some(question) => format!("question {question}: failed: {why}"),
                        None => format!("a connection came to nothing: {why}"),
                    }),
                }
            })
        },
        questions: AtomicU64::new(0),
    });
    std::thread::spawn(move || receiver.serve(listener));
    notify.ready("In the air: senders nearby can see this computer");

    // The node's clock: microseconds, from somewhere a phone cannot guess.
    let origin = u64::from(u32::from_le_bytes([random[0], random[1], random[2], 0]));
    let clock = || started.elapsed().as_micros() as u64 + origin;
    let mut node = Node::new(&settings, clock());
    let mut buffer = vec![0u8; 4096];
    let (mut dropped, mut said) = (0u64, 0u64);
    let (mut counted_from, mut shown_until) = (u64::MAX, u64::MAX);
    // Comings and goings logged this second: anybody in range can make them, and not a log of them.
    let mut noted = 0u32;
    while !sys::stopping() {
        let now = clock();
        let next = node.tick(now);
        while let Some(frame) = node.for_air() {
            dropped += u64::from(!air.send(&frame));
        }
        while let Some(frame) = node.for_kernel() {
            tap.receive(&frame);
        }
        while let Some(event) = node.events.pop_front() {
            noted += 1;
            if noted > MOST_NOTED {
                continue;
            }
            match event {
                Event::Found(peer) => log(format!("{} is in range", text(&peer))),
                Event::Lost(peer) => log(format!("{} is gone", text(&peer))),
                Event::Plan {
                    peer,
                    channels,
                    here,
                } => log(format!(
                    "{} is on this channel in {here} slots of 16: {}",
                    text(&peer),
                    channels.map(|channel| channel.to_string()).join(" ")
                )),
            }
        }
        let elapsed = started.elapsed().as_micros() as u64;
        // Stored by the receiver, it can be a moment newer than elapsed.
        let quiet = quiet_since.load(Ordering::SeqCst);
        if quiet != counted_from {
            // The count begins, or begins again after a transfer: those who show it are told when it runs out.
            if counted_from != u64::MAX {
                shown_until = quiet + SHOWN_FOR;
            }
            counted_from = quiet;
            if let Some(seconds) = o.give_up_after {
                let unix = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_or(0, |since| since.as_secs());
                control.ends(
                    unix + seconds
                        - elapsed.saturating_sub(quiet).min(seconds * 1_000_000) / 1_000_000,
                );
            }
        }
        let once = once && !control.stays();
        if elapsed >= shown_until && !once {
            shown_until = u64::MAX;
            control.waiting();
        }
        if (once && elapsed >= ending.load(Ordering::SeqCst))
            || o.give_up_after
                .is_some_and(|seconds| elapsed >= quiet + seconds * 1_000_000 && !control.busy())
        {
            break;
        }
        // Once a second, how the link is doing, while it is doing anything.
        if elapsed / 1_000_000 != said {
            said = elapsed / 1_000_000;
            notify.alive();
            if noted > MOST_NOTED {
                log(format!(
                    "and {} more comings and goings",
                    noted - MOST_NOTED
                ));
            }
            noted = 0;
            let c = std::mem::take(&mut node.counts);
            if c.to_kernel + c.to_air > 20 {
                log(format!("link: {} packets in, {} frames out ({} held for a slot, {} on the chance, {} again), {} repeats heard, {} the driver refused", c.to_kernel, c.to_air, c.held, c.sent_on_the_chance, c.repeated, c.duplicates, dropped));
            }
        }
        sys::wait(
            std::os::fd::AsRawFd::as_raw_fd(&air),
            std::os::fd::AsRawFd::as_raw_fd(&tap),
            next.saturating_sub(clock()).min(100_000),
        );
        // What has come in, both ways; not without end, so that the announcements keep their beat.
        // What each side's frames call for goes on at once: a packet to the kernel, its answer to
        // the air while the phone that asked is still here.
        for _ in 0..256 {
            let Some(size) = air.heard(&mut buffer) else {
                break;
            };
            node.heard(clock(), &buffer[..size]);
            while let Some(frame) = node.for_kernel() {
                tap.receive(&frame);
            }
            while let Some(frame) = node.for_air() {
                dropped += u64::from(!air.send(&frame));
            }
        }
        for _ in 0..256 {
            let Some(size) = tap.sent(&mut buffer) else {
                break;
            };
            node.kernel_sent(clock(), &buffer[..size]);
            while let Some(frame) = node.for_kernel() {
                tap.receive(&frame);
            }
            while let Some(frame) = node.for_air() {
                dropped += u64::from(!air.send(&frame));
            }
        }
    }
    log("stopping".into());
    control::close(&control);
    // A transfer cut off by the end leaves nothing half-unpacked behind.
    unpack::sweep(&o.folder);
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(why) => {
            let _ = writeln!(std::io::stderr(), "nova-airdropd: {why}");
            ExitCode::FAILURE
        }
    }
}
