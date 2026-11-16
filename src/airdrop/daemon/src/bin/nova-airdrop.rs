//! nova airdrop: receiving from iPhones nearby, switched on and off, and
//! sending to them.
//!
//!   nova airdrop            how it is, in a line
//!   nova airdrop on         this computer shows in the AirDrop list of iPhones nearby
//!   nova airdrop on --stay  and does not end after a transfer: only when switched off, or
//!                           when nobody has sent anything for two minutes
//!   nova airdrop off
//!   nova airdrop toggle
//!   nova airdrop accept     yes to what is being offered
//!   nova airdrop decline    no to it
//!   nova airdrop watch      how it is as lines of JSON, now and at each change (for the shell)
//!   nova airdrop active     succeeds while it is on
//!   nova airdrop available  succeeds if this computer's Wi-Fi card can do it, and says why not
//!
//!   nova airdrop send [--to <name>] <file>...
//!                           send files to an iPhone nearby: those that show are numbered as
//!                           they appear, and the one whose number is typed (or that is named)
//!                           is asked to take them. Only an iPhone set to Everyone for 10
//!                           Minutes takes them (Settings, General, AirDrop): this computer is
//!                           nobody's contact
//!   nova airdrop send --json <file>...
//!                           the same as lines of JSON (for the shell); `to <id>` or `cancel`
//!                           on its input
//!   nova airdrop send --window <file>...
//!                           the shell's window for it (Files' Open With)
//!
//!   nova airdrop bell       AirDrop's doorbell: how it is, in a line
//!   nova airdrop bell on    Bluetooth listens for your iPhone's share sheet, from now and at
//!                           each login, and the shell switches AirDrop on for it
//!   nova airdrop bell off
//!   nova airdrop bell learn listen for a minute for an iPhone to know
//!   nova airdrop bell forget
//!   nova airdrop bell watch how it is as lines of JSON (for the shell)
//!   nova airdrop bell rest  stop listening until `wake` (the shell, while locked)
//!   nova airdrop bell wake  listen again
//!
//! While AirDrop is on the Wi-Fi is off the network: the card can be on an
//! iPhone's channel or on the network's, not both. It ends by itself after a
//! transfer to this computer, or when nobody has sent anything for two
//! minutes, and the Wi-Fi connects again. A send switches it on if it is off,
//! and it goes off at the send's end unless it was switched on meanwhile: the
//! daemon knows who holds it on, and ends when the last lets go. Off lets go
//! of what on held; a send that is going on keeps it on until it is over.
//!
//! The work is nova-airdropd's, started as a service of the system's by
//! nova-airdrop-apply (through pkexec: the person at the computer needs no
//! password); this command talks to it over its socket (meet.rs, control.rs).
//! The doorbell is nova-airdrop-bell, a service of the system's too, enabled
//! for the user by the same helper.

#[path = "../meet.rs"]
mod meet;
#[path = "../picker.rs"]
mod picker;

use std::ffi::{c_char, c_int, c_void, CString};
use std::fs::File;
use std::io::{BufRead, BufReader, IsTerminal, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{mpsc, Mutex};
use std::time::{Duration, Instant};

use picker::{End, Picker};

extern "C" {
    fn inotify_init1(flags: c_int) -> c_int;
    fn inotify_add_watch(fd: c_int, path: *const c_char, mask: u32) -> c_int;
    fn prctl(option: c_int, ...) -> c_int;
    fn signal(signal: c_int, handler: usize) -> usize;
    fn write(fd: c_int, buffer: *const c_void, length: usize) -> isize;
    fn _exit(status: c_int) -> !;
}

const PR_SET_PDEATHSIG: c_int = 1;
const SIGTERM: std::ffi::c_ulong = 15;

const IN_CREATE: u32 = 0x100;
const IN_MOVED_TO: u32 = 0x80;
const IN_CLOEXEC: c_int = 0o2000000;

/// What the radio's helper leaves while there is something of the Wi-Fi's to put back, and what it
/// leaves when it has: how that went, in a line.
const BORROWED: &str = "/run/nova-airdrop/wifi";
const VERDICT: &str = "/run/nova-airdrop/last";

/// A helper of Nova's, where the package puts it, or where a test says it is.
fn helper(name: &str, variable: &str) -> PathBuf {
    match std::env::var_os(variable) {
        Some(path) if !path.is_empty() => PathBuf::from(path),
        _ => Path::new("/usr/lib/nova").join(name),
    }
}

/// Says one thing to the daemon and has its answer: None if no daemon is there.
fn ask(what: &str) -> Option<String> {
    ask_at(&meet::socket(), what)
}

fn ask_at(socket: &Path, what: &str) -> Option<String> {
    let mut stream = UnixStream::connect(socket).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    writeln!(stream, "{what}").ok()?;
    let mut answer = String::new();
    BufReader::new(stream.take(1 << 20))
        .read_line(&mut answer)
        .ok()?;
    Some(answer.trim_end().to_owned())
}

fn waited(until: impl Fn() -> bool, at_most: Duration) -> bool {
    let began = Instant::now();
    while !until() {
        if began.elapsed() >= at_most {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    true
}

/// The root half, through pkexec. What it has to say, it says on this command's own output.
fn apply(word: &str) -> bool {
    applied(word, false).is_ok()
}

/// The same, with what it says kept (`keep`) for whoever asked, rather than said: the shell's
/// send reads this command's output as JSON.
fn applied(word: &str, keep: bool) -> Result<(), String> {
    let helper = helper("nova-airdrop-apply", "NOVA_AIRDROP_APPLY");
    let pkexec = std::env::var_os("NOVA_AIRDROP_PKEXEC").unwrap_or_else(|| "pkexec".into());
    let mut command = Command::new(&pkexec);
    command.arg(&helper).arg(word);
    let ran = if keep {
        // Its words are on stderr; nothing it leaves running keeps this waiting on its stdout.
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .output()
            .map(|output| {
                let said = String::from_utf8_lossy(&output.stderr);
                let said = said.split_whitespace().collect::<Vec<_>>().join(" ");
                (output.status.success(), said)
            })
    } else {
        command
            .status()
            .map(|status| (status.success(), String::new()))
    };
    match ran {
        Ok((true, _)) => Ok(()),
        Ok((false, said)) => Err(said),
        Err(error) => {
            let said = format!("{}: {error}", pkexec.to_string_lossy());
            if !keep {
                eprintln!("nova airdrop: {said}");
            }
            Err(said)
        }
    }
}

fn status() -> String {
    match ask("status") {
        Some(words) => words,
        None if Path::new(BORROWED).exists() => {
            "AirDrop is off: the Wi-Fi is being put back.".into()
        }
        None => "AirDrop is off.".into(),
    }
}

fn on(stay: bool) -> ExitCode {
    // The daemon is told who holds it on: the user, or (--stay) the doorbell, for the shell.
    let word = if stay { "stay" } else { "hold" };
    let mut started = false;
    // One on its way out is waited for, and started again.
    for _ in 0..3 {
        match ask(word).as_deref() {
            Some("ok") if started => {
                println!("{}", status());
                return ExitCode::SUCCESS;
            }
            Some("ok") => {
                println!("AirDrop is already on.");
                return ExitCode::SUCCESS;
            }
            Some(meet::GOING_OFF) => {
                waited(|| ask("status").is_none(), Duration::from_secs(10));
            }
            Some(why) => {
                eprintln!("nova airdrop: {why}");
                return ExitCode::FAILURE;
            }
            None => {}
        }
        // Up means its socket is there: it is told before anybody could have sent anything.
        if !apply("on") {
            return ExitCode::FAILURE;
        }
        started = true;
    }
    eprintln!("nova airdrop: AirDrop went off as soon as it came on: try again");
    ExitCode::FAILURE
}

fn off() -> ExitCode {
    let borrowed = || Path::new(BORROWED).exists();
    let answer = ask("stop");
    match answer.as_deref() {
        // A send holds it on: it goes off by itself when the send is over.
        Some(meet::AFTER_THE_SEND) => {
            println!("{}", meet::AFTER_THE_SEND);
            return ExitCode::SUCCESS;
        }
        None if !borrowed() => {
            println!("AirDrop is off.");
            return ExitCode::SUCCESS;
        }
        _ => {}
    }
    // The daemon ends by itself when asked. One that does not, and one that is not up yet, is the
    // system's to stop; so is waiting for a Wi-Fi that is being put back already.
    let ended = answer.is_some() && waited(|| ask("status").is_none(), Duration::from_secs(3));
    if !ended && !apply("off") {
        return ExitCode::FAILURE;
    }
    println!("{}", handed_back());
    ExitCode::SUCCESS
}

/// Waits for the radio's helper to hand the Wi-Fi back, which it says it has done when it is done
/// with it, and says how that went.
fn handed_back() -> String {
    waited(|| !Path::new(BORROWED).exists(), Duration::from_secs(40));
    let verdict = std::fs::read_to_string(VERDICT).unwrap_or_default();
    match verdict.trim() {
        "" => "AirDrop is off.".into(),
        verdict => format!("AirDrop is off. {verdict}"),
    }
}

fn bell_status() -> String {
    ask_at(&meet::bell(), "status").unwrap_or_else(|| "AirDrop's doorbell is off.".into())
}

/// Switched on, it learns the first time: an iPhone shown AirDrop beside the computer in the
/// minute after is the one it listens for.
fn bell_on() -> ExitCode {
    if !apply("bell-on") {
        return ExitCode::FAILURE;
    }
    let bell = meet::bell();
    waited(
        || UnixStream::connect(&bell).is_ok(),
        Duration::from_secs(5),
    );
    let knows_none = ask_at(&bell, "watch").is_some_and(|json| json.contains(r#""phones":0"#));
    if knows_none {
        ask_at(&bell, "learn");
    }
    println!("{}", bell_status());
    ExitCode::SUCCESS
}

fn answer(what: &str) -> ExitCode {
    match ask(what).as_deref() {
        Some("ok") => ExitCode::SUCCESS,
        Some(why) => {
            eprintln!("nova airdrop: {why}");
            ExitCode::FAILURE
        }
        None => {
            eprintln!("nova airdrop: AirDrop is off");
            ExitCode::FAILURE
        }
    }
}

/// Waits until something is made in a folder, or for a second where that cannot be watched.
fn something_new_in(folder: &Path, socket: &Path) {
    use std::os::fd::{AsRawFd, FromRawFd};
    let watch = || {
        let name = CString::new(folder.as_os_str().as_bytes()).ok()?;
        // SAFETY: no pointers; the descriptor is owned, and so closed, from the moment it exists.
        let events = unsafe {
            let fd = inotify_init1(IN_CLOEXEC);
            (fd >= 0).then(|| std::fs::File::from_raw_fd(fd))?
        };
        // SAFETY: the name is NUL-terminated and lives across the call.
        let added = unsafe {
            inotify_add_watch(events.as_raw_fd(), name.as_ptr(), IN_CREATE | IN_MOVED_TO)
        };
        (added >= 0).then_some(events)
    };
    match watch() {
        // Looked again with the watch in place, so that a socket made in between is not waited for.
        Some(mut events) if UnixStream::connect(socket).is_err() => {
            let _ = events.read(&mut [0u8; 4096]);
        }
        Some(_) => {}
        None => std::thread::sleep(Duration::from_secs(1)),
    }
}

/// The daemon's lines for as long as there is a daemon, `off` in between, and never an end: the
/// shell reads this for as long as it runs. The same for the doorbell.
fn watch(socket: PathBuf) -> ExitCode {
    use std::os::unix::fs::DirBuilderExt;
    // It has nothing to write, and so no way to notice, when whoever reads it has gone without a
    // word (a shell that crashed): it is ended with them.
    // SAFETY: no pointers.
    unsafe { prctl(PR_SET_PDEATHSIG, SIGTERM) };
    let folder = socket.parent().unwrap_or(Path::new("/")).to_owned();
    let _ = std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&folder);
    let mut out = std::io::stdout().lock();
    let mut told_off = false;
    loop {
        // A socket that is there but not listened on yet is tried again for a moment.
        let mut stream = None;
        for _ in 0..10 {
            stream = UnixStream::connect(&socket).ok();
            if stream.is_some() || !socket.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        if let Some(mut stream) = stream {
            if writeln!(stream, "watch").is_ok() {
                for line in BufReader::new(stream).lines() {
                    let Ok(line) = line else { break };
                    if writeln!(out, "{line}").and_then(|_| out.flush()).is_err() {
                        return ExitCode::SUCCESS;
                    }
                    told_off = false;
                }
            }
        }
        if !told_off {
            if writeln!(out, r#"{{"state":"off"}}"#)
                .and_then(|_| out.flush())
                .is_err()
            {
                return ExitCode::SUCCESS;
            }
            told_off = true;
        }
        something_new_in(&folder, &socket);
    }
}

// ------------------------------------------------------------------ sending

/// What `send` was asked.
#[derive(Debug, Default, PartialEq)]
struct Asked {
    to: Option<String>,
    json: bool,
    window: bool,
    files: Vec<PathBuf>,
}

impl Asked {
    fn from(words: &[&str]) -> Result<Asked, String> {
        let mut asked = Asked::default();
        let mut words = words.iter();
        let mut options = true;
        while let Some(&word) = words.next() {
            match word {
                "--" if options => options = false,
                "--to" if options => match words.next() {
                    Some(name) if !name.trim().is_empty() => asked.to = Some(name.to_string()),
                    _ => return Err("--to wants the name of the iPhone".into()),
                },
                "--json" if options => asked.json = true,
                "--window" if options => asked.window = true,
                option if options && option.starts_with("--") => {
                    return Err(format!("{option} is not an option of send"))
                }
                file => asked.files.push(PathBuf::from(file)),
            }
        }
        if asked.files.is_empty() {
            return Err("send wants the files to send".into());
        }
        Ok(asked)
    }
}

/// A file to send, open, or why not, in a sentence.
fn opened(path: &Path) -> Result<File, String> {
    let name = path.display();
    let file = File::open(path).map_err(|error| match error.kind() {
        std::io::ErrorKind::NotFound => format!("{name} is not there."),
        std::io::ErrorKind::PermissionDenied => format!("{name} cannot be read."),
        _ => format!("{name}: {error}"),
    })?;
    let about = file
        .metadata()
        .map_err(|error| format!("{name}: {error}"))?;
    if about.is_dir() {
        return Err(format!("{name} is a folder: only files can be sent."));
    }
    if !about.is_file() {
        return Err(format!("{name} is not a file."));
    }
    Ok(file)
}

static CANCELLED: AtomicBool = AtomicBool::new(false);
/// The daemon's socket while a send is going on: a signal says cancel to it.
static CANCEL_TO: AtomicI32 = AtomicI32::new(-1);
/// The same, where the shell's words go (--json).
static TO_DAEMON: Mutex<Option<UnixStream>> = Mutex::new(None);

// Async-signal-safe: a flag, and a write. The second time, it is the end at once: the daemon lets
// go of AirDrop when the send's connection closes, or nobody takes hold of the one just started.
extern "C" fn on_stop(_: c_int) {
    if CANCELLED.swap(true, Ordering::SeqCst) {
        // SAFETY: no pointers; it does not return.
        unsafe { _exit(130) }
    }
    let fd = CANCEL_TO.load(Ordering::SeqCst);
    if fd >= 0 {
        // SAFETY: a static buffer of the length given.
        unsafe { write(fd, b"cancel\n".as_ptr().cast(), 7) };
    }
}

fn cancelled() -> bool {
    CANCELLED.load(Ordering::SeqCst)
}

/// A program of Nova's beside this one, where it is installed, else on the PATH.
fn beside(name: &str) -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|me| Some(me.parent()?.join(name)))
        .filter(|path| path.exists())
        .unwrap_or_else(|| PathBuf::from(name))
}

/// What the shell's IPC is given: a JSON list, percent-encoded, as qs's command line takes a
/// comma or brackets in an argument for a list of its own.
fn encoded(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                char::from(b).to_string()
            }
            b => format!("%{b:02X}"),
        })
        .collect()
}

/// The files in the shell's window: Files' Open With has no terminal.
fn window(files: &[PathBuf]) -> ExitCode {
    let here = std::env::current_dir().unwrap_or_default();
    let mut paths = Vec::new();
    for file in files {
        let path = if file.is_absolute() {
            file.clone()
        } else {
            here.join(file)
        };
        let Some(path) = path.to_str() else {
            eprintln!(
                "{} has a name that is not text: send it from a terminal.",
                path.display()
            );
            return ExitCode::FAILURE;
        };
        paths.push(meet::quoted(path));
    }
    let paths = encoded(&format!("[{}]", paths.join(",")));
    match Command::new(beside("nova-shell"))
        .args(["airdrop", "send", &paths])
        .stdout(Stdio::null())
        .status()
    {
        Ok(status) if status.success() => ExitCode::SUCCESS,
        _ => ExitCode::FAILURE,
    }
}

/// Words for the user, or for the shell: the same thing said either way.
fn failed(json: bool, why: &str) -> ExitCode {
    if json {
        println!(r#"{{"state":"failed","why":{}}}"#, meet::quoted(why));
    } else {
        eprintln!("{why}");
    }
    ExitCode::FAILURE
}

fn send(words: &[&str]) -> ExitCode {
    let asked = match Asked::from(words) {
        Ok(asked) => asked,
        Err(why) => {
            eprintln!("nova airdrop: {why}\n\n{}", usage());
            return ExitCode::from(2);
        }
    };
    if asked.window {
        return window(&asked.files);
    }
    let json = asked.json;
    let mut files = Vec::new();
    for path in &asked.files {
        match opened(path) {
            Ok(file) => files.push(file),
            Err(why) => return failed(json, &why),
        }
    }
    if files.len() > 200 {
        return failed(json, "AirDrop sends up to 200 files at a time.");
    }
    // SAFETY: the handler is async-signal-safe; no pointers.
    unsafe {
        signal(2, on_stop as *const () as usize);
        signal(15, on_stop as *const () as usize);
        // The shell's send ends with the shell, however that ends.
        if json {
            prctl(PR_SET_PDEATHSIG, SIGTERM);
        }
    }
    let typed = listen(json);
    let terminal = std::io::stdout().is_terminal();
    let mut picker = Picker::new(asked.to.clone(), terminal, Instant::now());
    // Switched on for the send if it is off; one on its way out is waited for, and asked again.
    let (mut ours, mut end) = (false, End::Again);
    for _ in 0..3 {
        if ask("status").is_none() {
            if cancelled() {
                if json {
                    println!(r#"{{"state":"cancelled"}}"#);
                } else {
                    println!("Cancelled.");
                }
                end = End::NotSent;
                break;
            }
            if !ours {
                if json {
                    println!(r#"{{"state":"starting"}}"#);
                } else {
                    println!(
                        "Switching AirDrop on: the Wi-Fi is off the network until it is done."
                    );
                }
            }
            ours = true;
            if let Err(why) = applied("on", json) {
                return if json {
                    failed(
                        json,
                        if why.is_empty() {
                            "AirDrop did not start."
                        } else {
                            &why
                        },
                    )
                } else {
                    ExitCode::FAILURE
                };
            }
        }
        end = sending(json, &files, &mut picker, &typed);
        if end != End::Again {
            break;
        }
        waited(|| ask("status").is_none(), Duration::from_secs(10));
    }
    drop(files);
    if end == End::Again {
        let _ = failed(json, picker::WENT_OFF);
        end = End::NotSent;
    }
    // The daemon ends by itself once nobody holds AirDrop on: the shell's watch says so, and the
    // command at a terminal says how handing the Wi-Fi back went.
    if !json {
        match picker.stays {
            Some(false) => {
                println!("Switching AirDrop off…");
                if waited(|| ask("status").is_none(), Duration::from_secs(10)) {
                    println!("{}", handed_back());
                } else {
                    println!("{}", status());
                }
            }
            Some(true) if ours => println!("AirDrop stays on, as it was switched on meanwhile."),
            Some(true) => {}
            None if ours && ask("status").is_none() && Path::new(BORROWED).exists() => {
                println!("{}", handed_back());
            }
            None => {}
        }
    }
    match end {
        End::Sent => ExitCode::SUCCESS,
        End::NotSent | End::Again => ExitCode::FAILURE,
    }
}

/// What the user, or the shell, says, a line at a time: at a terminal for the picker, and from the
/// shell (--json) for the send that is going on; a cancel before there is one is kept for it.
fn listen(json: bool) -> mpsc::Receiver<String> {
    let (typing, typed) = mpsc::channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            let words = line.trim();
            if !json {
                if typing.send(line).is_err() {
                    break;
                }
            } else if picker::passable(words) {
                let to = TO_DAEMON.lock().unwrap();
                match to.as_ref() {
                    Some(mut stream) => {
                        let _ = writeln!(stream, "{words}");
                    }
                    None if words == "cancel" => CANCELLED.store(true, Ordering::SeqCst),
                    None => {}
                }
            }
        }
    });
    typed
}

/// The send itself, once AirDrop is on: the files handed to the daemon, and the conversation. Again
/// if the daemon was not there to take them, or was on its way out.
fn sending(json: bool, files: &[File], picker: &mut Picker, typed: &mpsc::Receiver<String>) -> End {
    let Ok(stream) = UnixStream::connect(meet::socket()) else {
        return End::Again;
    };
    let fds: Vec<RawFd> = files.iter().map(AsRawFd::as_raw_fd).collect();
    if meet::send_with_files(stream.as_raw_fd(), b"send\n", &fds) != 5 {
        return End::Again;
    }
    CANCEL_TO.store(stream.as_raw_fd(), Ordering::SeqCst);
    *TO_DAEMON.lock().unwrap() = stream.try_clone().ok();
    // A signal, or the shell's cancel, that came before there was a socket to tell.
    if cancelled() {
        let _ = (&stream).write_all(b"cancel\n");
    }
    let mut out = std::io::stdout().lock();
    let end = if json {
        picker::pass_on(&stream, &mut out)
    } else {
        picker::converse(&stream, picker, typed, &mut out)
    };
    *TO_DAEMON.lock().unwrap() = None;
    CANCEL_TO.store(-1, Ordering::SeqCst);
    end
}

fn usage() -> String {
    include_str!("nova-airdrop.rs")
        .lines()
        .take_while(|line| line.starts_with("//!"))
        .map(|line| line.trim_start_matches("//!").trim_start_matches(' '))
        .collect::<Vec<_>>()
        .join("\n")
}

fn main() -> ExitCode {
    let words: Vec<String> = std::env::args().skip(1).collect();
    let words: Vec<&str> = words.iter().map(String::as_str).collect();
    match words.as_slice() {
        [] | ["status"] => {
            println!("{}", status());
            ExitCode::SUCCESS
        }
        ["on"] => on(false),
        ["on", "--stay"] => on(true),
        ["off"] => off(),
        ["toggle"] => match ask("status") {
            Some(_) => off(),
            None => on(false),
        },
        ["accept"] => answer("accept"),
        // A question's id is letters, digits and dashes: nothing that could be a second line.
        [word @ ("accept" | "decline"), id]
            if id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') =>
        {
            answer(&format!("{word} {id}"))
        }
        ["decline"] => answer("decline"),
        ["watch"] => watch(meet::socket()),
        ["bell"] => {
            println!("{}", bell_status());
            ExitCode::SUCCESS
        }
        ["bell", "on"] => bell_on(),
        ["bell", "off"] => {
            if !apply("bell-off") {
                return ExitCode::FAILURE;
            }
            println!("AirDrop's doorbell is off.");
            ExitCode::SUCCESS
        }
        ["bell", word @ ("learn" | "forget" | "rest" | "wake")] => {
            match ask_at(&meet::bell(), word).as_deref() {
                Some("ok") => {
                    println!("{}", bell_status());
                    ExitCode::SUCCESS
                }
                Some(why) => {
                    eprintln!("nova airdrop bell: {why}");
                    ExitCode::FAILURE
                }
                None => {
                    eprintln!("nova airdrop bell: the doorbell is off (nova airdrop bell on)");
                    ExitCode::FAILURE
                }
            }
        }
        ["bell", "watch"] => watch(meet::bell()),
        ["send", rest @ ..] => send(rest),
        ["active"] => match ask("status") {
            Some(_) => ExitCode::SUCCESS,
            None => ExitCode::FAILURE,
        },
        ["available"] => {
            let radio = helper("nova-airdrop-radio", "NOVA_AIRDROP_RADIO");
            match Command::new(radio).arg("check").status() {
                Ok(status) if status.success() => ExitCode::SUCCESS,
                _ => ExitCode::FAILURE,
            }
        }
        ["help"] | ["--help"] | ["-h"] => {
            println!("{}", usage());
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("{}", usage());
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn send_reads_its_options_and_files() {
        assert_eq!(
            Asked::from(&["--to", "Zoë’s iPhone", "a.jpg", "--", "--json"]),
            Ok(Asked {
                to: Some("Zoë’s iPhone".into()),
                files: vec!["a.jpg".into(), "--json".into()],
                ..Asked::default()
            })
        );
        let shell = Asked::from(&["--json", "--window", "b c.png"]).unwrap();
        assert!(shell.json && shell.window && shell.files == [PathBuf::from("b c.png")]);
        for wrong in [
            &[][..],
            &["--to"],
            &["--to", " ", "a"],
            &["--fast", "a"],
            &["--json"],
        ] {
            assert!(Asked::from(wrong).is_err(), "{wrong:?}");
        }
    }

    #[test]
    fn only_files_are_sent_and_what_is_not_one_is_said_plainly() {
        assert!(opened(Path::new("/proc/self/stat")).is_ok());
        assert_eq!(
            opened(Path::new("/nonexistent/a.jpg")).unwrap_err(),
            "/nonexistent/a.jpg is not there."
        );
        assert_eq!(
            opened(Path::new("/proc")).unwrap_err(),
            "/proc is a folder: only files can be sent."
        );
        assert_eq!(
            opened(Path::new("/dev/null")).unwrap_err(),
            "/dev/null is not a file."
        );
    }

    #[test]
    fn the_shell_is_given_its_list_with_nothing_qs_would_split() {
        assert_eq!(
            encoded(r#"["/a b/c,d.jpg","/é%"]"#),
            "%5B%22/a%20b/c%2Cd.jpg%22%2C%22/%C3%A9%25%22%5D"
        );
    }
}
