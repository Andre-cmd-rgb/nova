//! The journal, read through sd-journal: entries matched by their fields, and
//! followed as they are written, as `journalctl -f` does, in this process.

use std::ffi::{c_void, CString};
use std::os::fd::RawFd;
use std::path::Path;
use std::ptr;
use std::time::Duration;

use crate::error::{check, Error, Result};
use crate::ffi::{self, sd_journal};
use crate::poll::{self, PollFd};

/// What changed in the journal since it was last looked at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Change {
    /// Nothing.
    Nothing,
    /// Entries were written.
    Appended,
    /// Files were added or taken away (a rotation); read on as before.
    Invalidated,
}

/// The journal files this user may read, open for reading.
///
/// Like a bus, it belongs to the thread that opened it.
pub struct Journal {
    raw: *mut sd_journal,
}

impl Drop for Journal {
    fn drop(&mut self) {
        // SAFETY: ours, closed once.
        unsafe { ffi::sd_journal_close(self.raw) };
    }
}

impl Journal {
    /// This computer's journal, every file of it this user may read: the
    /// system's (for wheel, adm and systemd-journal) and the user's own.
    pub fn open_local() -> Result<Journal> {
        let mut raw = ptr::null_mut();
        // SAFETY: a valid out-pointer.
        check(
            unsafe { ffi::sd_journal_open(&mut raw, ffi::SD_JOURNAL_LOCAL_ONLY) },
            "opening the journal",
        )?;
        Ok(Journal { raw })
    }

    /// These journal files, and no others: a file journald starts in their
    /// place (a rotation) is not followed into; `process` says
    /// `Invalidated` as one goes, for the caller to open the new one.
    pub fn open_files(files: &[&Path]) -> Result<Journal> {
        let paths = files
            .iter()
            .map(|f| CString::new(f.as_os_str().as_encoded_bytes()))
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|_| Error::Os {
                errno: 22,
                doing: "a journal file",
            })?;
        let mut pointers: Vec<*const std::ffi::c_char> = paths.iter().map(|p| p.as_ptr()).collect();
        pointers.push(ptr::null());
        let mut raw = ptr::null_mut();
        // SAFETY: a valid out-pointer and a NULL-terminated array of NUL-terminated paths.
        check(
            unsafe { ffi::sd_journal_open_files(&mut raw, pointers.as_ptr(), 0) },
            "opening the journal",
        )?;
        Ok(Journal { raw })
    }

    /// The journal files in <directory>: for tests.
    pub fn open_directory(directory: &Path) -> Result<Journal> {
        let path =
            CString::new(directory.as_os_str().as_encoded_bytes()).map_err(|_| Error::Os {
                errno: 22,
                doing: "a journal directory",
            })?;
        let mut raw = ptr::null_mut();
        // SAFETY: a valid out-pointer and a NUL-terminated path.
        check(
            unsafe { ffi::sd_journal_open_directory(&mut raw, path.as_ptr(), 0) },
            "opening the journal",
        )?;
        Ok(Journal { raw })
    }

    /// Only entries with <field>=<value>. Matches of different fields must all
    /// hold; matches of one field are alternatives.
    pub fn add_match(&mut self, field: &str, value: &str) -> Result<()> {
        let pair = format!("{field}={value}");
        // SAFETY: a live journal, and the bytes and their length.
        check(
            unsafe {
                ffi::sd_journal_add_match(self.raw, pair.as_ptr() as *const c_void, pair.len())
            },
            "matching journal entries",
        )?;
        Ok(())
    }

    /// The matches before this, or those after it.
    pub fn add_disjunction(&mut self) -> Result<()> {
        // SAFETY: a live journal.
        check(
            unsafe { ffi::sd_journal_add_disjunction(self.raw) },
            "matching journal entries",
        )?;
        Ok(())
    }

    /// The matches before this, and those after it.
    pub fn add_conjunction(&mut self) -> Result<()> {
        // SAFETY: a live journal.
        check(
            unsafe { ffi::sd_journal_add_conjunction(self.raw) },
            "matching journal entries",
        )?;
        Ok(())
    }

    pub fn flush_matches(&mut self) {
        // SAFETY: a live journal.
        unsafe { ffi::sd_journal_flush_matches(self.raw) };
    }

    pub fn seek_head(&mut self) -> Result<()> {
        // SAFETY: a live journal.
        check(
            unsafe { ffi::sd_journal_seek_head(self.raw) },
            "reading the journal",
        )?;
        Ok(())
    }

    pub fn seek_tail(&mut self) -> Result<()> {
        // SAFETY: a live journal.
        check(
            unsafe { ffi::sd_journal_seek_tail(self.raw) },
            "reading the journal",
        )?;
        Ok(())
    }

    /// Past every entry there is now, so that `next` finds only those written
    /// from now on (`journalctl -f -n 0`).
    pub fn seek_end(&mut self) -> Result<()> {
        self.seek_tail()?;
        // The tail is after the last entry; stepping back onto it makes the
        // next step forward the first new one.
        self.previous_entry()?;
        Ok(())
    }

    /// Moves to the next entry that matches: false when there is none (yet).
    pub fn next_entry(&mut self) -> Result<bool> {
        // SAFETY: a live journal.
        Ok(check(
            unsafe { ffi::sd_journal_next(self.raw) },
            "reading the journal",
        )? > 0)
    }

    pub fn previous_entry(&mut self) -> Result<bool> {
        // SAFETY: a live journal.
        Ok(check(
            unsafe { ffi::sd_journal_previous(self.raw) },
            "reading the journal",
        )? > 0)
    }

    /// The entry's <field>, as text; none when it has none.
    pub fn field(&mut self, field: &str) -> Result<Option<String>> {
        let name = CString::new(field).map_err(|_| Error::Os {
            errno: 22,
            doing: "a journal field",
        })?;
        let mut data = ptr::null();
        let mut length = 0;
        // SAFETY: a live journal, a NUL-terminated name and valid out-pointers.
        let r =
            unsafe { ffi::sd_journal_get_data(self.raw, name.as_ptr(), &mut data, &mut length) };
        if r == -2 || r == -74 {
            // ENOENT: no such field; EBADMSG: an entry written halfway.
            return Ok(None);
        }
        check(r, "reading a journal field")?;
        // SAFETY: sd-journal's bytes, "FIELD=value", valid until the next read.
        let bytes = unsafe { std::slice::from_raw_parts(data as *const u8, length) };
        let value = bytes.get(field.len() + 1..).unwrap_or_default();
        Ok(Some(String::from_utf8_lossy(value).into_owned()))
    }

    /// When the entry was written, in microseconds since 1970.
    pub fn realtime_usec(&mut self) -> Result<u64> {
        let mut usec = 0;
        // SAFETY: a live journal and a valid pointer.
        check(
            unsafe { ffi::sd_journal_get_realtime_usec(self.raw, &mut usec) },
            "reading the journal",
        )?;
        Ok(usec)
    }

    /// The descriptor that becomes readable as the journal changes (inotify), for poll().
    pub fn fd(&mut self) -> Result<RawFd> {
        // SAFETY: a live journal.
        check(
            unsafe { ffi::sd_journal_get_fd(self.raw) },
            "watching the journal",
        )
    }

    /// The descriptor and what to poll it for.
    pub fn poll_fd(&mut self) -> Result<PollFd> {
        let fd = self.fd()?;
        // SAFETY: a live journal.
        let events = check(
            unsafe { ffi::sd_journal_get_events(self.raw) },
            "watching the journal",
        )?;
        Ok(PollFd::new(fd, events as i16))
    }

    /// How long poll() may wait before the journal must be looked at anyway
    /// (only where its files cannot be watched); none for as long as it likes.
    pub fn timeout(&mut self) -> Option<Duration> {
        let mut usec = u64::MAX;
        // SAFETY: a live journal and a valid pointer.
        if unsafe { ffi::sd_journal_get_timeout(self.raw, &mut usec) } < 0 {
            return None;
        }
        poll::until(usec)
    }

    /// Takes in what the descriptor said.
    pub fn process(&mut self) -> Result<Change> {
        // SAFETY: a live journal.
        Ok(change(check(
            unsafe { ffi::sd_journal_process(self.raw) },
            "watching the journal",
        )?))
    }

    /// Waits for the journal to change, at most <timeout> (none: forever).
    pub fn wait(&mut self, timeout: Option<Duration>) -> Result<Change> {
        let usec = timeout.map_or(u64::MAX, |t| t.as_micros() as u64);
        // SAFETY: a live journal.
        Ok(change(check(
            unsafe { ffi::sd_journal_wait(self.raw, usec) },
            "watching the journal",
        )?))
    }
}

fn change(r: i32) -> Change {
    match r {
        1 => Change::Appended,
        2 => Change::Invalidated,
        _ => Change::Nothing,
    }
}
