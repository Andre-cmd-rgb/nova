//! What the duties share: where the session's files are, how a helper is
//! run, and the few C library calls std lacks.

use std::ffi::{c_char, c_int, CString};
use std::fs;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

/// A line for the journal, from one duty.
#[macro_export]
macro_rules! say {
    ($duty:expr, $($arg:tt)*) => {
        eprintln!("{}: {}", $duty, format!($($arg)*))
    };
}

/// Where a duty finds the session, and its helpers.
#[derive(Debug, Clone)]
pub struct Context {
    /// $XDG_RUNTIME_DIR/nova: Nova's runtime files.
    pub runtime: PathBuf,
    /// $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE, outside a Hyprland session none.
    pub hypr: Option<PathBuf>,
    /// $HYPRLAND_INSTANCE_SIGNATURE: which session this is, or empty.
    pub session: String,
    /// The folder Nova's helpers are run from; none to find them on PATH (tests put stubs here).
    pub bin: Option<PathBuf>,
    /// /proc, or a stand-in.
    pub proc: PathBuf,
}

impl Context {
    /// The session's, from the environment systemd gave the daemon.
    pub fn from_env() -> Result<Context, String> {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR")
            .filter(|r| !r.is_empty())
            .ok_or("XDG_RUNTIME_DIR is not set")?;
        let runtime = PathBuf::from(runtime);
        let session = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_default();
        let hypr = (!session.is_empty() && !session.contains('/'))
            .then(|| runtime.join("hypr").join(&session));
        Ok(Context {
            runtime: runtime.join("nova"),
            hypr,
            session,
            bin: None,
            proc: PathBuf::from("/proc"),
        })
    }

    /// $XDG_RUNTIME_DIR/nova, made if it is not there yet (private to the user).
    pub fn runtime_dir(&self) -> io::Result<&Path> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.runtime)?;
        Ok(&self.runtime)
    }

    /// A helper of Nova's (or a program on PATH), ready to run, reading nothing.
    pub fn command(&self, program: &str) -> Command {
        let path = match &self.bin {
            Some(bin) => bin.join(program),
            None => PathBuf::from(program),
        };
        let mut command = Command::new(path);
        command.stdin(Stdio::null());
        command
    }

    /// Runs a helper and waits for it: its exit status, or none when it
    /// could not start or a signal ended it.
    pub fn run(&self, argv: &[&str]) -> Option<i32> {
        let (program, args) = argv.split_first()?;
        let mut command = self.command(program);
        command.args(args);
        match retry_busy(|| command.status()) {
            Ok(status) => status.code(),
            Err(e) => {
                say!("nova-sessiond", "could not run {program}: {e}");
                None
            }
        }
    }

    /// Starts a helper without waiting for it, and reaps it once it ends.
    pub fn spawn(&self, argv: &[&str], quiet: bool) -> Option<u32> {
        let (program, args) = argv.split_first()?;
        let mut command = self.command(program);
        command.args(args);
        if quiet {
            command.stdout(Stdio::null()).stderr(Stdio::null());
        }
        match retry_busy(|| command.spawn()) {
            Ok(child) => {
                let pid = child.id();
                reap(child);
                Some(pid)
            }
            Err(e) => {
                say!("nova-sessiond", "could not run {program}: {e}");
                None
            }
        }
    }
}

/// Starts a program, and again for up to half a second while the kernel
/// says it is busy (ETXTBSY): open for writing somewhere, as a helper is
/// while pacman writes it in an update, or a test's stub while a child that
/// another thread forked has not yet closed it.
pub fn retry_busy<T>(mut start: impl FnMut() -> io::Result<T>) -> io::Result<T> {
    const ETXTBSY: i32 = 26;
    let mut tries = 0;
    loop {
        match start() {
            Err(e) if e.raw_os_error() == Some(ETXTBSY) && tries < 50 => {
                tries += 1;
                thread::sleep(Duration::from_millis(10));
            }
            other => return other,
        }
    }
}

/// Waits for <child> on a small thread of its own, so that it leaves no zombie.
pub fn reap(mut child: Child) {
    let reaper = thread::Builder::new()
        .name("reaper".into())
        .stack_size(64 * 1024)
        .spawn(move || {
            let _ = child.wait();
        });
    if let Err(e) = reaper {
        say!("nova-sessiond", "could not wait for a helper: {e}");
    }
}

/// Writes <text> to <path> through a file beside it, so that a reader sees
/// the old contents or the new, never half of them. Each write has a file of
/// its own, so that two duties writing the same path at once (the clock's
/// stamp, at a wake) do not write into each other's.
pub fn write_atomically(path: &Path, text: &str) -> io::Result<()> {
    static WRITES: AtomicU64 = AtomicU64::new(0);
    let n = WRITES.fetch_add(1, Ordering::Relaxed);
    let temporary = path.with_extension(format!("{}.{n}.new", std::process::id()));
    fs::write(&temporary, text)?;
    fs::rename(&temporary, path).inspect_err(|_| {
        let _ = fs::remove_file(&temporary);
    })
}

/// Removes <path>; one that is not there is no error.
pub fn remove(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// Waits a little before a duty tries again, longer after each failure in a row.
pub struct Backoff {
    next: Duration,
    longest: Duration,
}

impl Backoff {
    pub fn new(first: Duration, longest: Duration) -> Backoff {
        Backoff {
            next: first,
            longest,
        }
    }

    pub fn pause(&mut self) -> Duration {
        let pause = self.next;
        self.next = (self.next * 2).min(self.longest);
        pause
    }
}

extern "C" {
    fn inotify_init1(flags: c_int) -> c_int;
    fn inotify_add_watch(fd: c_int, path: *const c_char, mask: u32) -> c_int;
    fn pipe2(fds: *mut c_int, flags: c_int) -> c_int;
    fn flock(fd: c_int, operation: c_int) -> c_int;
}

pub const IN_CLOSE_WRITE: u32 = 0x8;
pub const IN_MOVED_FROM: u32 = 0x40;
pub const IN_MOVED_TO: u32 = 0x80;
pub const IN_CREATE: u32 = 0x100;
pub const IN_DELETE: u32 = 0x200;
const IN_NONBLOCK: c_int = 0o4000;
const IN_CLOEXEC: c_int = 0o2000000;

/// An inotify descriptor watching one folder for files written, made,
/// moved and removed in it.
pub struct FolderWatch {
    file: fs::File,
}

impl FolderWatch {
    pub fn new(folder: &Path, mask: u32) -> io::Result<FolderWatch> {
        // SAFETY: no pointers; a new descriptor or -1.
        let fd = unsafe { inotify_init1(IN_NONBLOCK | IN_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a descriptor just made, and ours alone.
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let path = CString::new(folder.as_os_str().as_encoded_bytes())
            .map_err(|_| io::ErrorKind::InvalidInput)?;
        // SAFETY: a live inotify descriptor and a NUL-terminated path.
        if unsafe { inotify_add_watch(fd.as_raw_fd(), path.as_ptr(), mask) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(FolderWatch {
            file: fs::File::from(fd),
        })
    }

    pub fn fd(&self) -> RawFd {
        self.file.as_raw_fd()
    }

    /// The names of the files the events waiting were about, and empties the queue.
    pub fn names(&self) -> Vec<String> {
        let mut names = Vec::new();
        let mut buffer = [0u8; 4096];
        // Read until it would block: the descriptor is non-blocking.
        while let Ok(length) = io::Read::read(&mut &self.file, &mut buffer) {
            if length == 0 {
                break;
            }
            let mut at = 0;
            // struct inotify_event: wd, mask, cookie, len, then len bytes of name.
            while at + 16 <= length {
                let len =
                    u32::from_ne_bytes(buffer[at + 12..at + 16].try_into().unwrap_or_default())
                        as usize;
                let name = &buffer[at + 16..(at + 16 + len).min(length)];
                let name = name.split(|&b| b == 0).next().unwrap_or_default();
                names.push(String::from_utf8_lossy(name).into_owned());
                at += 16 + len;
            }
        }
        names
    }
}

/// A pipe that wakes a thread asleep in poll(): another thread writes a
/// byte, and the sleeper empties it.
pub struct Waker {
    read: fs::File,
    write: fs::File,
}

impl Waker {
    pub fn new() -> io::Result<Waker> {
        let mut fds = [0; 2];
        // O_NONBLOCK | O_CLOEXEC. SAFETY: a valid array of two.
        if unsafe { pipe2(fds.as_mut_ptr(), 0o4000 | 0o2000000) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: both just made, and ours alone.
        let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        Ok(Waker {
            read: read.into(),
            write: write.into(),
        })
    }

    pub fn fd(&self) -> RawFd {
        self.read.as_raw_fd()
    }

    pub fn wake(&self) {
        // A full pipe wakes the sleeper as well as one more byte would.
        let _ = io::Write::write(&mut &self.write, &[1]);
    }

    pub fn drain(&self) {
        let mut buffer = [0u8; 64];
        while matches!(io::Read::read(&mut &self.read, &mut buffer), Ok(n) if n > 0) {}
    }
}

/// A lock on a file, shared with Nova's helpers that take the same one
/// (`flock`), held until it is dropped.
pub struct FileLock {
    _file: fs::File,
}

impl FileLock {
    /// The lock, if nobody holds it now.
    pub fn try_take(path: &Path) -> Option<FileLock> {
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path)
            .ok()?;
        // LOCK_EX | LOCK_NB. SAFETY: an open descriptor.
        (unsafe { flock(file.as_raw_fd(), 2 | 4) } == 0).then_some(FileLock { _file: file })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_busy_program_is_started_again_and_another_error_is_not() {
        let mut tries = 0;
        let started = retry_busy(|| {
            tries += 1;
            if tries < 3 {
                Err(io::Error::from_raw_os_error(26))
            } else {
                Ok(tries)
            }
        });
        assert_eq!(started.unwrap(), 3);

        let mut tries = 0;
        let missing = retry_busy(|| -> io::Result<()> {
            tries += 1;
            Err(io::Error::from(io::ErrorKind::NotFound))
        });
        assert!(missing.is_err());
        assert_eq!(tries, 1);
    }
}
