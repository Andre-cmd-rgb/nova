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
//! It runs as the person whose files they will be, with two capabilities:
//! CAP_NET_RAW, for the socket on the monitor interface, and CAP_NET_ADMIN,
//! for that socket's buffers and for the one on Bluetooth's management that
//! wakes an iPhone when it sends. That one is bound and kept by a process of
//! its own, forked first (announcer.rs); the daemon gives up both as soon as
//! it has its socket on the radio, before it runs anything, and leaves the
//! system's network for a namespace of its own: see sys.rs. Its certificate
//! is its own, made on the first run and kept in --identity (by default
//! nova/airdrop under the user's state folder).
//!
//! The name is the computer's, the folder the user's downloads, the country
//! NOVA_AIRDROP_COUNTRY's, unless it is told otherwise. What is offered is put
//! to the user over the control socket (control.rs; `nova airdrop` and the
//! shell are at its other end), and taken unasked with --accept-all. It sends
//! too, what a client hands it over that socket (send.rs).
//!
//! --give-up-after ends the daemon when nobody has asked for that long, and
//! --once when nobody holds it on any more: the Wi-Fi is off the network while
//! this runs, and should not be for long. Who does is said on the control
//! socket (control.rs): the user's on holds it until a transfer to this
//! computer has ended, either way, the doorbell until it lets go, and a send
//! until it is over or its client has gone; it ends a moment after the last
//! lets go, or 15 seconds after it is up if nobody takes hold of it at all,
//! but not while a transfer or a send is under way. The user's stop ends it
//! at once, whatever holds it.
//!
//! What it logs goes to standard error, a line an event.

mod announcer;
mod control;
mod defaults;
mod http;
mod meet;
mod mgmt;
mod node;
mod pack;
mod packet;
mod plist;
mod receiver;
mod send;
mod sender;
mod sys;
mod tls;
mod unpack;
mod wake;
mod wire;

use std::io::Write;
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use control::Control;
use node::{Event, Node, Settings};
use receiver::{Happened, Receiver};
use wire::Mac;

const PORT: u16 = 8771;
/// What fits in an AWDL data frame with room to spare; an iPhone's own is 1450.
const MTU: u32 = 1450;
/// How long after a transfer's end --once ends the daemon: the sender has its answer by then.
const AFTER_THE_LAST: u64 = 2_000_000;
/// How long --once waits, from when it is up (its socket listens), for somebody to take hold of
/// the daemon: whoever started it says so at once, unless they were killed meanwhile.
const UNCLAIMED_FOR: u64 = 15_000_000;
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
        // The channel nova-airdrop-radio put the card on, else 6.
        channel: std::env::var("NOVA_AIRDROP_CHANNEL")
            .ok()
            .and_then(|channel| channel.trim().parse().ok())
            .filter(|channel| (1..=196).contains(channel))
            .unwrap_or(6),
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

/// How things stand at a turn of the daemon's loop, for its own end.
#[derive(Debug, Clone, Copy)]
struct Turn {
    /// Microseconds since the start.
    now: u64,
    /// --once: it ends when nobody holds it on.
    once: bool,
    /// A question, a transfer, or a send's asking and sending, under way.
    busy: bool,
    /// Nobody has asked for as long as --give-up-after says.
    given_up: bool,
    held: control::Held,
}

/// What the loop keeps of its own end from one turn to the next.
#[derive(Debug, Default)]
struct Ending {
    /// Since when nobody has held AirDrop on and nothing has been under way, if so.
    free_since: Option<u64>,
    /// Somebody has held it, or something has been under way, since it was up.
    claimed: bool,
    /// The holds' count of claims (control.rs) at the last turn: one that came and went between
    /// two turns is a letting go too.
    claims: u64,
}

/// Whether the daemon ends at this turn: given up, at once; with --once, a moment after nobody
/// holds AirDrop on and nothing is under way any more, or a while after it is up if nobody ever
/// takes hold of it (its loop's first turn is when it is up).
fn ends_now(turn: Turn, ending: &mut Ending) -> bool {
    if turn.given_up {
        return true;
    }
    let held = turn.held;
    if turn.busy || held.held || held.sending || held.claims != ending.claims {
        ending.claimed = true;
        ending.claims = held.claims;
        ending.free_since = None;
        return false;
    }
    if !turn.once {
        return false;
    }
    let since = *ending.free_since.get_or_insert(turn.now);
    let wait = if ending.claimed {
        AFTER_THE_LAST
    } else {
        UNCLAIMED_FOR
    };
    turn.now >= since + wait
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

    // What wakes an iPhone when this computer sends, in a process of its own that keeps the
    // capability to tell Bluetooth what to announce, and nothing else: forked before anything is
    // open (announcer.rs). Without it, a send says why.
    let announcer = announcer::Announcer::fork();
    // The socket on the monitor interface: it stays in the namespace the card is in.
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
    // That was all the capabilities were for: none for openssl, or for anything a phone could reach.
    // A user namespace it makes later is its own, with what it takes to set up a network in it.
    mgmt::give_up_capabilities().map_err(|e| format!("giving up its capabilities: {e}"))?;
    // The certificate while the files of the system are still as they were named, and systemd's ear.
    let (certificate, key) = identity(&o.identity)?;
    let tls = tls::Server::new(&certificate, &key)?;
    let client = tls::Client::new(&certificate, &key)?;
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
    let scope = sys::interface_index(tap.name());
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

    // When nobody has asked for long enough (--give-up-after), counted from the start and from each
    // transfer's end; when it ends otherwise, the loop sees (ends_now).
    let quiet_since = Arc::new(AtomicU64::new(0));
    let (accept_all, once) = (o.accept_all, o.once);
    // A send's start and end count as a transfer's for when this ends by itself.
    let sent_since = Arc::new(AtomicU64::new(0));
    let sending = send::Sending::new(
        sender::Sender {
            tls: client,
            name: o.name.clone(),
            model: o.model.clone(),
            id: settings.instance.clone(),
            limits: sender::Limits::default(),
        },
        scope,
        announcer,
        {
            let sent_since = sent_since.clone();
            Box::new(move |told| {
                let now = started.elapsed().as_micros() as u64;
                match told {
                    send::Told::Began => {
                        sent_since.store(now, Ordering::SeqCst);
                        log("sending: Bluetooth says so, and the air is asked who receives".into());
                    }
                    send::Told::Ended { transfer } => {
                        sent_since.store(now, Ordering::SeqCst);
                        log(match transfer {
                            true => "the send is over".into(),
                            false => "the send is over: nobody was asked".into(),
                        });
                    }
                    send::Told::Log(line) => log(format!("sending: {line}")),
                }
            })
        },
        // AirDrop stays on after a send if somebody else holds it, and it is not on its way out.
        {
            let control = control.clone();
            Box::new(move || !sys::stopping() && !control.closing() && (!once || control.held()))
        },
    );
    {
        let (preparing, on) = (sending.clone(), sending.clone());
        control.on_send(control::Sends {
            prepare: Box::new(move |files, icon| {
                let ready: Box<dyn control::Ready> = Box::new(preparing.prepare(files, icon)?);
                Ok(ready)
            }),
            on: Box::new(move || on.on()),
        });
    }
    let receiver = Arc::new(Receiver {
        tls,
        name: o.name.clone(),
        model: o.model.clone(),
        folder: o.folder.clone(),
        decide: {
            let control = control.clone();
            Box::new(move |question, offer| {
                let yes = control.ask(question, offer, accept_all);
                if yes && !offer.sender.is_empty() {
                    // The doorbell keeps the name for the user's iPhone, if that is the one showing
                    // AirDrop: an iPhone's announcement does not carry its name. On a thread of its
                    // own, as the sender waits for its yes meanwhile.
                    let line = format!("name {}", offer.sender);
                    let _ = std::thread::Builder::new()
                        .name("airdrop-bell".into())
                        .spawn(move || meet::ask(&meet::bell(), &line, Duration::from_secs(2)));
                }
                yes
            })
        },
        tell: {
            let (quiet_since, control) = (quiet_since.clone(), control.clone());
            Box::new(move |happened| {
                // The end of the question that was open, whichever way, is what the user's on was
                // for; what another sender's connection came to meanwhile is not.
                if control.happened(&happened) {
                    quiet_since.store(started.elapsed().as_micros() as u64, Ordering::SeqCst);
                    control.used();
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
    std::thread::Builder::new()
        .name("airdrop-receiver".into())
        .spawn(move || receiver.serve(listener))
        .map_err(|e| format!("the receiver: {e}"))?;
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
    let mut ending = Ending::default();
    while !sys::stopping() {
        let now = clock();
        node.browsing = sending.browsing();
        let next = node.tick(now);
        while let Some(frame) = node.for_air() {
            dropped += u64::from(!air.send(&frame));
        }
        while let Some(frame) = node.for_kernel() {
            tap.receive(&frame);
        }
        while let Some(event) = node.events.pop_front() {
            // What a send needs to hear, whatever is logged.
            match &event {
                Event::Receiver { peer, receiver } => sending.heard_on_air(*peer, receiver.clone()),
                Event::Lost(peer) => sending.gone(*peer),
                _ => {}
            }
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
                // Said once a second while it is asked; the send logs those it lists.
                Event::Receiver { .. } => {}
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
        if elapsed >= shown_until {
            shown_until = u64::MAX;
            control.waiting();
        }
        let busy = control.busy() || sending.busy();
        let given_up = !busy
            && o.give_up_after.is_some_and(|seconds| {
                elapsed >= quiet.max(sent_since.load(Ordering::SeqCst)) + seconds * 1_000_000
            });
        let ends = control.close_if(|held| {
            let turn = Turn {
                now: elapsed,
                once,
                busy,
                given_up,
                held,
            };
            ends_now(turn, &mut ending)
        });
        if ends {
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
                log(format!("link: {} packets in, {} frames out ({} held for a slot, {} on the chance, {} again), {} repeats heard, {} the driver refused{}", c.to_kernel, c.to_air, c.held, c.sent_on_the_chance, c.repeated, c.duplicates, dropped, c.rates_heard()));
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
    // Whatever is under way ends with the daemon: a send that was looking says so to its client.
    sys::stop();
    sending.finish(std::time::Duration::from_secs(2));
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

#[cfg(test)]
mod tests {
    use super::*;
    use control::Held;

    #[test]
    fn the_daemon_ends_when_nobody_holds_it_and_nothing_is_under_way() {
        let turn = |now, busy, held| Turn {
            now,
            once: true,
            busy,
            given_up: false,
            held,
        };
        let nobody = Held::default();
        let sending = Held {
            sending: true,
            ..Held::default()
        };
        let user = Held {
            held: true,
            ..Held::default()
        };
        // Up at 3 s (a slow start), and nobody takes hold of it: it ends 15 s on from then.
        let up = 3_000_000;
        let mut ending = Ending::default();
        assert!(!ends_now(turn(up, false, nobody), &mut ending));
        assert!(!ends_now(
            turn(up + UNCLAIMED_FOR - 1, false, nobody),
            &mut ending
        ));
        assert!(ends_now(
            turn(up + UNCLAIMED_FOR, false, nobody),
            &mut ending
        ));
        // A send holds it, whatever else ends meanwhile (a stranger's question); once it is over,
        // or its client has gone, AirDrop ends a moment after.
        let mut ending = Ending::default();
        assert!(!ends_now(turn(1, false, sending), &mut ending));
        assert!(!ends_now(turn(9_000_000, false, sending), &mut ending));
        assert!(!ends_now(turn(10_000_000, false, nobody), &mut ending));
        assert!(!ends_now(
            turn(10_000_000 + AFTER_THE_LAST - 1, false, nobody),
            &mut ending
        ));
        assert!(ends_now(
            turn(10_000_000 + AFTER_THE_LAST, false, nobody),
            &mut ending
        ));
        // Nothing ends it while a transfer or a send is under way, and the moment counts from the
        // end of it: a send's end does not end a transfer to this computer, nor the other way.
        let mut ending = Ending::default();
        assert!(!ends_now(turn(1, true, nobody), &mut ending));
        assert!(!ends_now(turn(60_000_000, true, nobody), &mut ending));
        assert!(!ends_now(turn(61_000_000, false, nobody), &mut ending));
        assert!(ends_now(
            turn(61_000_000 + AFTER_THE_LAST, false, nobody),
            &mut ending
        ));
        // A send that came and went between two turns, too quick for the loop to see it on: its
        // end is the moment's start all the same, and not a while after the daemon was up.
        let mut ending = Ending::default();
        assert!(!ends_now(turn(1, false, nobody), &mut ending));
        let came_and_went = Held {
            claims: 1,
            ..Held::default()
        };
        assert!(!ends_now(turn(500_000, false, came_and_went), &mut ending));
        assert!(!ends_now(turn(600_000, false, came_and_went), &mut ending));
        assert!(ends_now(
            turn(600_000 + AFTER_THE_LAST, false, came_and_went),
            &mut ending
        ));
        // The user's on holds it for as long as it is held.
        let mut ending = Ending::default();
        assert!(!ends_now(turn(1, false, user), &mut ending));
        assert!(!ends_now(turn(1 << 40, false, user), &mut ending));
        // Given up, held or not.
        let given_up = Turn {
            given_up: true,
            ..turn(1, false, user)
        };
        assert!(ends_now(given_up, &mut ending));
        // Without --once only giving up ends it (and the user's stop, which is the control's).
        let mut ending = Ending::default();
        for now in [1, 1 << 40] {
            let without = Turn {
                once: false,
                ..turn(now, false, nobody)
            };
            assert!(!ends_now(without, &mut ending));
        }
    }
}
