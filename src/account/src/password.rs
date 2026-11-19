// nova-password-change: Settings' Change Password (PasswordSheet.qml). The
// three passwords come on stdin, each ended by a NUL: the current one, the
// new one and the new one again. One line of JSON goes out, {"ok", "error"},
// and the status is 0 once the password is changed.
//
// passwd must own the PAM conversation so pwquality and the login keyring
// both take part. A pipe races PAM's terminal flush; each prompt is answered
// on a private terminal instead. Only a short diagnostic leaves this
// process, never the conversation, and never a password.
//
// NOVA_PASSWD names the passwd to run, for the tests.

use std::ffi::{c_char, c_int, c_void, CString};
use std::os::unix::ffi::OsStrExt;
use std::time::{Duration, Instant};

#[repr(C)]
#[derive(Clone, Copy)]
struct Termios {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [u8; 32],
    ispeed: u32,
    ospeed: u32,
}

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}

#[repr(C)]
struct Rlimit {
    current: u64,
    most: u64,
}

/// glibc's sigset_t: 1024 bits.
#[repr(C)]
struct SigSet([u64; 16]);

// The C library's terminal, process and signal calls, which std has not.
extern "C" {
    fn forkpty(
        master: *mut c_int,
        name: *mut c_char,
        termios: *const Termios,
        size: *const c_void,
    ) -> c_int;
    fn tcgetattr(fd: c_int, termios: *mut Termios) -> c_int;
    fn tcsetattr(fd: c_int, when: c_int, termios: *const Termios) -> c_int;
    fn execve(path: *const c_char, argv: *const *const c_char, envp: *const *const c_char)
        -> c_int;
    fn _exit(status: c_int) -> !;
    fn poll(fds: *mut PollFd, count: u64, timeout: c_int) -> c_int;
    fn read(fd: c_int, buffer: *mut c_void, count: usize) -> isize;
    fn write(fd: c_int, buffer: *const c_void, count: usize) -> isize;
    fn close(fd: c_int) -> c_int;
    fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
    fn killpg(group: c_int, signal: c_int) -> c_int;
    fn setrlimit(resource: c_int, limit: *const Rlimit) -> c_int;
    fn sigemptyset(set: *mut SigSet) -> c_int;
    fn sigaddset(set: *mut SigSet, signal: c_int) -> c_int;
    fn sigprocmask(how: c_int, set: *const SigSet, old: *mut SigSet) -> c_int;
    fn signalfd(fd: c_int, set: *const SigSet, flags: c_int) -> c_int;
    fn signal(signal: c_int, handler: usize) -> usize;
}

const ECHO: u32 = 0o10;
const ECHONL: u32 = 0o100;
const TCSANOW: c_int = 0;
const POLLIN: i16 = 1;
const WNOHANG: c_int = 1;
const SIGINT: c_int = 2;
const SIGKILL: c_int = 9;
const SIGPIPE: c_int = 13;
const SIGTERM: c_int = 15;
const SIG_DFL: usize = 0;
const RLIMIT_CORE: c_int = 4;
const SIG_BLOCK: c_int = 0;
const SIG_UNBLOCK: c_int = 1;
const SFD_CLOEXEC: c_int = 0o2000000;
const EIO: i32 = 5;

/// Why it stopped short.
enum Stop {
    /// Something to tell the person.
    Said(String),
    /// SIGTERM or SIGINT: Settings cancelled. Nothing is said.
    Cancelled,
}

/// Waits for <fd> to be readable, or <deadline>, or a signal on <signals>.
/// True once it is readable.
fn wait_for(fd: c_int, signals: c_int, deadline: Instant) -> Result<bool, Stop> {
    let left = deadline.saturating_duration_since(Instant::now());
    let mut fds = [
        PollFd {
            fd,
            events: POLLIN,
            revents: 0,
        },
        PollFd {
            fd: signals,
            events: POLLIN,
            revents: 0,
        },
    ];
    // SAFETY: two pollfds, as many as said.
    let ready = unsafe { poll(fds.as_mut_ptr(), 2, left.as_millis().min(60_000) as c_int) };
    if ready > 0 && fds[1].revents != 0 {
        return Err(Stop::Cancelled);
    }
    Ok(ready > 0 && fds[0].revents != 0)
}

fn read_passwords(signals: c_int) -> Result<[Vec<u8>; 3], Stop> {
    let all_three = || Stop::Said("Enter all three passwords.".into());
    let mut values: Vec<Vec<u8>> = Vec::new();
    let mut value = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while values.len() < 3 {
        if !wait_for(0, signals, deadline)? {
            return Err(all_three());
        }
        let mut byte = 0u8;
        // SAFETY: one byte into one byte; stdin is read a byte at a time, so nothing past the third NUL is taken.
        let got = unsafe { read(0, (&mut byte as *mut u8).cast(), 1) };
        if got <= 0 {
            return Err(all_three());
        }
        if byte == 0 {
            values.push(std::mem::take(&mut value));
        } else if byte < 32 || byte == 127 || value.len() >= 1024 {
            return Err(Stop::Said(
                "That password contains unsupported characters or is too long.".into(),
            ));
        } else {
            value.push(byte);
        }
    }
    if values.iter().any(Vec::is_empty) {
        return Err(all_three());
    }
    if values[1] != values[2] {
        return Err(Stop::Said("The new passwords are not the same.".into()));
    }
    values.try_into().map_err(|_| all_three())
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Prompt {
    Current,
    New,
    Repeat,
}

/// passwd's prompts, as PAM's modules word them, in any case: the first one
/// found in <pending>, and where it ends. Where two begin at the same place,
/// the current password's is taken first, then the retyped one's.
fn prompt(pending: &[u8]) -> Option<(Prompt, usize)> {
    const PROMPTS: [(Prompt, &[&str]); 3] = [
        (
            Prompt::Current,
            &[
                "(current) password:",
                "(current) unix password:",
                "current password:",
                "current unix password:",
            ],
        ),
        (
            Prompt::Repeat,
            &[
                "retype password:",
                "retype new password:",
                "retype new unix password:",
            ],
        ),
        (
            Prompt::New,
            &[
                "new password:",
                "new unix password:",
                "enter new password:",
                "enter new unix password:",
            ],
        ),
    ];
    let lower = pending.to_ascii_lowercase();
    let mut best: Option<(usize, usize, Prompt, usize)> = None;
    for (rank, (kind, words)) in PROMPTS.iter().enumerate() {
        for word in *words {
            if let Some(at) = find(&lower, word.as_bytes()) {
                let candidate = (at, rank, *kind, at + word.len());
                if best.is_none_or(|b| (at, rank) < (b.0, b.1)) {
                    best = Some(candidate);
                }
            }
        }
    }
    best.map(|(_, _, kind, end)| (kind, end))
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn replace(haystack: &[u8], needle: &[u8], with: &[u8]) -> Vec<u8> {
    if needle.is_empty() {
        return haystack.to_vec();
    }
    let mut out = Vec::with_capacity(haystack.len());
    let mut at = 0;
    while at < haystack.len() {
        if haystack[at..].starts_with(needle) {
            out.extend_from_slice(with);
            at += needle.len();
        } else {
            out.push(haystack[at]);
            at += 1;
        }
    }
    out
}

/// White space as Python's str.isspace() has it, which the old helper's
/// patterns and strip() went by: Unicode's, and the four separators.
fn space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// The first <most> characters of <text>.
fn first(text: &str, most: usize) -> String {
    text.chars().take(most).collect()
}

/// The lines of <text>, at every line break a Python reads as one.
fn lines(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        let breaks = matches!(
            c,
            '\n' | '\r'
                | '\u{b}'
                | '\u{c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        );
        if breaks {
            out.push(&text[start..at]);
            let mut next = at + c.len_utf8();
            if c == '\r' {
                if let Some(&(_, '\n')) = chars.peek() {
                    chars.next();
                    next += 1;
                }
            }
            start = next;
        }
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

/// What passwd's weak-password complaint says, after "BAD PASSWORD:".
fn weak_reason(text: &str) -> Option<String> {
    let lower = text.to_ascii_lowercase();
    let mut from = 0;
    while let Some(found) = lower[from..].find("bad password:") {
        let rest = &text[from + found + "bad password:".len()..];
        let spaces = rest.len() - rest.trim_start_matches(space).len();
        let line = rest[spaces..].split(['\r', '\n']).next().unwrap_or("");
        if !line.is_empty() {
            return Some(first(line.trim_matches(space), 160));
        }
        // Only spaces to the line's end: a reason of nothing.
        if rest[..spaces].chars().any(|c| c != '\r' && c != '\n') {
            return Some(String::new());
        }
        from += found + 1;
    }
    None
}

/// The one short diagnostic that leaves this process: never the
/// conversation, and never a password, should passwd say one back.
fn reason(output: &[u8], sent: usize, passwords: &[Vec<u8>; 3]) -> String {
    let mut sorted: Vec<&Vec<u8>> = passwords.iter().collect();
    sorted.sort_by_key(|p| std::cmp::Reverse(p.len()));
    let mut output = output.to_vec();
    for password in sorted {
        output = replace(&output, password, b"[hidden]");
    }
    let text = String::from_utf8_lossy(&output).into_owned();
    if let Some(weak) = weak_reason(&text) {
        return weak;
    }
    let lower = text.to_ascii_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| lower.contains(w));
    if sent <= 1
        && has(&[
            "authentication failure",
            "authentication token manipulation error",
            "incorrect",
            "wrong",
        ])
    {
        return "The current password is not right.".into();
    }
    if has(&["do not match", "not match", "mismatch"]) {
        return "The new passwords are not the same.".into();
    }
    for line in lines(&text) {
        let line = line.trim_matches(space);
        if !line.starts_with("passwd:") {
            continue;
        }
        let low = line.to_ascii_lowercase();
        if !low.contains("unchanged") && !low.contains("changing password") {
            return first(line["passwd:".len()..].trim_matches(space), 160);
        }
    }
    "Could not change the password.".into()
}

/// The exit status a wait status stands for: a signal's, negative.
fn exit_code(status: c_int) -> i32 {
    if status & 0x7f == 0 {
        (status >> 8) & 0xff
    } else {
        -(status & 0x7f)
    }
}

/// passwd, run on a terminal of its own, each prompt answered in turn.
fn change(passwords: &[Vec<u8>; 3], signals: c_int) -> Result<(), Stop> {
    // Everything the child needs is made before the fork: after it, only
    // calls that are safe in a forked child.
    let program = std::env::var_os("NOVA_PASSWD")
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "/usr/bin/passwd".into());
    // By its path: a passwd earlier in PATH (~/.local/bin) would be handed
    // the current password.
    let path = CString::new(program.as_bytes()).map_err(|_| Stop::Said(start_failed()))?;
    let name = CString::new("passwd").unwrap();
    let argv = [name.as_ptr(), std::ptr::null()];
    let environment: Vec<CString> = std::env::vars_os()
        .filter(|(key, _)| key != "LC_ALL")
        .filter_map(|(key, value)| {
            let mut entry = key.as_bytes().to_vec();
            entry.push(b'=');
            entry.extend_from_slice(value.as_bytes());
            CString::new(entry).ok()
        })
        .chain([CString::new("LC_ALL=C").unwrap()])
        .collect();
    let mut envp: Vec<*const c_char> = environment.iter().map(|e| e.as_ptr()).collect();
    envp.push(std::ptr::null());
    let set = cancel_signals();

    let mut terminal: c_int = -1;
    // SAFETY: a valid out-pointer for the terminal; no name, settings or size asked.
    let pid = unsafe {
        forkpty(
            &mut terminal,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    if pid < 0 {
        return Err(Stop::Said(start_failed()));
    }
    if pid == 0 {
        // SAFETY: the child, alone in it: the terminal's settings, the signals
        // given back to passwd, and the exec, with what was made before the
        // fork. Rust ignores SIGPIPE for itself; passwd gets the default back.
        unsafe {
            let mut attributes = std::mem::zeroed::<Termios>();
            if tcgetattr(0, &mut attributes) == 0 {
                attributes.lflag &= !(ECHO | ECHONL);
                tcsetattr(0, TCSANOW, &attributes);
            }
            signal(SIGPIPE, SIG_DFL);
            sigprocmask(SIG_UNBLOCK, &set, std::ptr::null_mut());
            execve(path.as_ptr(), argv.as_ptr(), envp.as_ptr());
            _exit(127);
        }
    }
    let mut child = Child { pid, terminal };
    let result = converse(&mut child, passwords, signals);
    child.end();
    result
}

fn start_failed() -> String {
    "Could not start the password change.".into()
}

/// passwd and its terminal, which go together.
struct Child {
    pid: c_int,
    terminal: c_int,
}

impl Child {
    /// Whether passwd has ended, and how.
    fn ended(&mut self) -> Option<c_int> {
        if self.pid == 0 {
            return None;
        }
        let mut status = 0;
        // SAFETY: our child, and a valid pointer.
        if unsafe { waitpid(self.pid, &mut status, WNOHANG) } == self.pid {
            self.pid = 0;
            return Some(status);
        }
        None
    }

    /// The terminal closed and, should passwd still run, it and its PAM
    /// session ended: cancelling Settings ends them too.
    fn end(&mut self) {
        if self.terminal >= 0 {
            // SAFETY: our terminal, closed once.
            unsafe { close(self.terminal) };
            self.terminal = -1;
        }
        if self.pid > 0 {
            let mut status = 0;
            // SAFETY: passwd leads its own session (forkpty), so its group is its pid.
            unsafe {
                killpg(self.pid, SIGKILL);
                waitpid(self.pid, &mut status, 0);
            }
            self.pid = 0;
        }
    }
}

fn converse(child: &mut Child, passwords: &[Vec<u8>; 3], signals: c_int) -> Result<(), Stop> {
    let mut output: Vec<u8> = Vec::new();
    let mut pending: Vec<u8> = Vec::new();
    let mut sent = 0;
    let mut status = None;
    let deadline = Instant::now() + Duration::from_secs(45);
    let expected = [Prompt::Current, Prompt::New, Prompt::Repeat];
    while Instant::now() < deadline {
        let soon = Instant::now() + Duration::from_millis(100);
        if wait_for(child.terminal, signals, soon)? {
            let mut buffer = [0u8; 4096];
            // SAFETY: a buffer as long as said, and our terminal.
            let got = unsafe { read(child.terminal, buffer.as_mut_ptr().cast(), buffer.len()) };
            let chunk: &[u8] = if got > 0 {
                &buffer[..got as usize]
            } else if got < 0 && std::io::Error::last_os_error().raw_os_error() != Some(EIO) {
                return Err(Stop::Said(start_failed()));
            } else {
                &[]
            };
            output.extend_from_slice(chunk);
            if output.len() > 16384 {
                output.drain(..output.len() - 16384);
            }
            pending.extend_from_slice(chunk);
            while let Some((kind, end)) = prompt(&pending) {
                pending.drain(..end);
                // Some accounts have no old password; passwd starts at new.
                if sent == 0 && kind == Prompt::New {
                    sent = 1;
                }
                if sent >= 3 || kind != expected[sent] {
                    return Err(Stop::Said(reason(&output, sent, passwords)));
                }
                let mut answer = passwords[sent].clone();
                answer.push(b'\n');
                // SAFETY: the answer's bytes, to our terminal.
                if unsafe { write(child.terminal, answer.as_ptr().cast(), answer.len()) } < 0 {
                    return Err(Stop::Said(start_failed()));
                }
                sent += 1;
            }
            if pending.len() > 4096 {
                pending.drain(..pending.len() - 4096);
            }
        }
        if let Some(ended) = child.ended() {
            status = Some(ended);
            break;
        }
    }
    if status.is_none() {
        status = child.ended();
    }
    match status {
        Some(status) if exit_code(status) == 0 && sent == 3 => Ok(()),
        _ => Err(Stop::Said(reason(&output, sent, passwords))),
    }
}

fn cancel_signals() -> SigSet {
    let mut set = SigSet([0; 16]);
    // SAFETY: a sigset_t of glibc's size.
    unsafe {
        sigemptyset(&mut set);
        sigaddset(&mut set, SIGINT);
        sigaddset(&mut set, SIGTERM);
    }
    set
}

fn json_string(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out + "\""
}

fn main() {
    // No core file of a process that held passwords.
    // SAFETY: a valid rlimit.
    unsafe {
        setrlimit(
            RLIMIT_CORE,
            &Rlimit {
                current: 0,
                most: 0,
            },
        );
    }
    // SIGTERM and SIGINT, Settings cancelling, are read from a descriptor
    // where the waits look for them, so that passwd is ended with this.
    let set = cancel_signals();
    // SAFETY: the set just made; the descriptor is new and ours.
    let signals = unsafe {
        sigprocmask(SIG_BLOCK, &set, std::ptr::null_mut());
        let fd = signalfd(-1, &set, SFD_CLOEXEC);
        if fd < 0 {
            // Without one, the signals end this as they would by default.
            sigprocmask(SIG_UNBLOCK, &set, std::ptr::null_mut());
        }
        fd
    };
    let result = read_passwords(signals).and_then(|passwords| change(&passwords, signals));
    let (ok, error) = match result {
        Ok(()) => (true, String::new()),
        Err(Stop::Said(error)) => (false, error),
        Err(Stop::Cancelled) => std::process::exit(1),
    };
    println!("{{\"ok\": {ok}, \"error\": {}}}", json_string(&error));
    std::process::exit(if ok { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_as_pam_words_them() {
        assert_eq!(prompt(b"Current password: "), Some((Prompt::Current, 17)));
        assert_eq!(
            prompt(b"(current) UNIX password:"),
            Some((Prompt::Current, 24))
        );
        assert_eq!(prompt(b"New password: "), Some((Prompt::New, 13)));
        assert_eq!(prompt(b"Enter new UNIX password:"), Some((Prompt::New, 24)));
        // The retyped one, though "new password:" is in it.
        assert_eq!(prompt(b"Retype new password: "), Some((Prompt::Repeat, 20)));
        assert_eq!(prompt(b"Curr"), None);
        assert_eq!(prompt(b"Changing password for anna."), None);
    }

    #[test]
    fn a_reason_never_holds_a_password() {
        let passwords = [
            b"old".to_vec(),
            b"new secret".to_vec(),
            b"new secret".to_vec(),
        ];
        assert_eq!(
            reason(b"passwd: rejected new secret\n", 3, &passwords),
            "rejected [hidden]"
        );
        assert_eq!(
            reason(
                b"BAD PASSWORD: The password is shorter than 12 characters\r\n",
                2,
                &passwords
            ),
            "The password is shorter than 12 characters"
        );
        assert_eq!(
            reason(
                b"passwd: Authentication token manipulation error\n",
                1,
                &passwords
            ),
            "The current password is not right."
        );
        assert_eq!(
            reason(b"Sorry, passwords do not match.\n", 3, &passwords),
            "The new passwords are not the same."
        );
        assert_eq!(
            reason(
                b"Changing password for anna.\npasswd: password unchanged\n",
                3,
                &passwords
            ),
            "Could not change the password."
        );
    }

    #[test]
    fn lines_break_where_a_python_breaks_them() {
        assert_eq!(lines("a\r\nb\rc\nd"), vec!["a", "b", "c", "d"]);
        assert_eq!(lines("a\n"), vec!["a"]);
    }
}
