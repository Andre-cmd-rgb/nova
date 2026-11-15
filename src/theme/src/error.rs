use std::fmt;
use std::io;

/// A message for the user, and the exit status that goes with it.
#[derive(Debug)]
pub struct Error {
    pub message: String,
    pub usage: bool,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(message: impl Into<String>) -> Error {
        Error {
            message: message.into(),
            usage: false,
        }
    }

    pub fn usage(message: impl Into<String>) -> Error {
        Error {
            message: message.into(),
            usage: true,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Error {
        Error::new(e.to_string())
    }
}

pub trait Context<T> {
    /// Prefixes an I/O error with what was being accessed.
    fn context(self, what: impl fmt::Display) -> Result<T>;
}

impl<T> Context<T> for io::Result<T> {
    fn context(self, what: impl fmt::Display) -> Result<T> {
        self.map_err(|e| Error::new(format!("{what}: {e}")))
    }
}

macro_rules! bail {
    ($($arg:tt)*) => { return Err($crate::error::Error::new(format!($($arg)*))) };
}
pub(crate) use bail;
