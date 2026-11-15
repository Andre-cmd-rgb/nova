//! nova airdrop: receiving from iPhones nearby, switched on and off.
//!
//!   nova airdrop            how it is, in a line
//!   nova airdrop on         this computer shows in the AirDrop list of iPhones nearby
//!   nova airdrop off
//!   nova airdrop toggle
//!   nova airdrop accept     yes to what is being offered
//!   nova airdrop decline    no to it
//!   nova airdrop watch      how it is as lines of JSON, now and at each change (for the shell)
//!   nova airdrop active     succeeds while it is on
//!   nova airdrop available  succeeds if this computer's Wi-Fi card can do it, and says why not
//!
//! While AirDrop is on the Wi-Fi is off the network: the card can be on an
//! iPhone's channel or on the network's, not both. It ends by itself after a
//! transfer, or when nobody has sent anything for two minutes, and the Wi-Fi
//! connects again.
//!
//! The work is nova-airdropd's, started as a service of the system's by
//! nova-airdrop-apply (through pkexec: the person at the computer needs no
//! password); this command talks to it over its socket (meet.rs, control.rs).

#[path = "../meet.rs"]
mod meet;

use std::ffi::{c_char, c_int, CString};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{Duration, Instant};

extern "C" {
    fn inotify_init1(flags: c_int) -> c_int;
    fn inotify_add_watch(fd: c_int, path: *const c_char, mask: u32) -> c_int;
    fn prctl(option: c_int, ...) -> c_int;
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
    let mut stream = UnixStream::connect(meet::socket()).ok()?;
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
    let helper = helper("nova-airdrop-apply", "NOVA_AIRDROP_APPLY");
    let pkexec = std::env::var_os("NOVA_AIRDROP_PKEXEC").unwrap_or_else(|| "pkexec".into());
    match Command::new(&pkexec).arg(&helper).arg(word).status() {
        Ok(status) => status.success(),
        Err(error) => {
            eprintln!("nova airdrop: {}: {error}", pkexec.to_string_lossy());
            false
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

fn on() -> ExitCode {
    if ask("status").is_some() {
        println!("AirDrop is already on.");
        return ExitCode::SUCCESS;
    }
    if !apply("on") {
        return ExitCode::FAILURE;
    }
    println!("{}", status());
    ExitCode::SUCCESS
}

fn off() -> ExitCode {
    let borrowed = || Path::new(BORROWED).exists();
    let asked = ask("stop").is_some();
    if !asked && !borrowed() {
        println!("AirDrop is off.");
        return ExitCode::SUCCESS;
    }
    // The daemon ends by itself when asked. One that does not, and one that is not up yet, is the
    // system's to stop; so is waiting for a Wi-Fi that is being put back already.
    let ended = asked && waited(|| ask("status").is_none(), Duration::from_secs(3));
    if !ended && !apply("off") {
        return ExitCode::FAILURE;
    }
    // The helper says how handing the Wi-Fi back went when it is done with it: that is the end of this.
    waited(|| !borrowed(), Duration::from_secs(40));
    let verdict = std::fs::read_to_string(VERDICT).unwrap_or_default();
    match verdict.trim() {
        "" => println!("AirDrop is off."),
        verdict => println!("AirDrop is off. {verdict}"),
    }
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
fn something_new_in(folder: &Path) {
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
        Some(mut events) if UnixStream::connect(meet::socket()).is_err() => {
            let _ = events.read(&mut [0u8; 4096]);
        }
        Some(_) => {}
        None => std::thread::sleep(Duration::from_secs(1)),
    }
}

/// The daemon's lines for as long as there is a daemon, `off` in between, and never an end: the
/// shell reads this for as long as it runs.
fn watch() -> ExitCode {
    use std::os::unix::fs::DirBuilderExt;
    // It has nothing to write, and so no way to notice, when whoever reads it has gone without a
    // word (a shell that crashed): it is ended with them.
    // SAFETY: no pointers.
    unsafe { prctl(PR_SET_PDEATHSIG, SIGTERM) };
    let socket = meet::socket();
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
        something_new_in(&folder);
    }
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
        ["on"] => on(),
        ["off"] => off(),
        ["toggle"] => match ask("status") {
            Some(_) => off(),
            None => on(),
        },
        ["accept"] => answer("accept"),
        // A question's id is letters, digits and dashes: nothing that could be a second line.
        [word @ ("accept" | "decline"), id]
            if id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') =>
        {
            answer(&format!("{word} {id}"))
        }
        ["decline"] => answer("decline"),
        ["watch"] => watch(),
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
