// ---------------------------------------------------------------- sysfs

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

// stdout into a journald pipe is block-buffered, so a tier change would sit in
// the buffer until something else filled it. Every line here is an event worth
// having a timestamp on, and there are only a handful a day.
macro_rules! say {
    ($($a:tt)*) => {{
        println!($($a)*);
        let _ = std::io::stdout().flush();
    }};
}
pub(crate) use say;

pub(crate) fn read_trim(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

pub(crate) fn read_u64(path: impl AsRef<Path>) -> Option<u64> {
    read_trim(path)?.parse().ok()
}

// Writes are best-effort and noisy exactly once. A sysfs file that has gone
// read-only, or a register firmware has taken back, would otherwise produce a
// line a second forever, and a log nobody reads is the same as no log.
pub(crate) struct Writer {
    complained: std::collections::HashSet<PathBuf>,
}

impl Writer {
    pub(crate) fn new() -> Self {
        Writer {
            complained: std::collections::HashSet::new(),
        }
    }

    pub(crate) fn write(&mut self, path: impl AsRef<Path>, value: &str) -> bool {
        let path = path.as_ref();
        match fs::OpenOptions::new().write(true).open(path) {
            Ok(mut f) => match f.write_all(value.as_bytes()) {
                Ok(()) => {
                    self.complained.remove(path);
                    true
                }
                Err(e) => {
                    self.complain(path, &format!("write failed: {e}"));
                    false
                }
            },
            Err(e) => {
                self.complain(path, &format!("open failed: {e}"));
                false
            }
        }
    }

    fn complain(&mut self, path: &Path, what: &str) {
        if self.complained.insert(path.to_path_buf()) {
            eprintln!("{}: {what}", path.display());
        }
    }
}
