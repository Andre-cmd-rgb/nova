//! What went wrong: an errno from libsystemd, or a D-Bus error a peer sent.

use std::ffi::CStr;
use std::fmt;

use crate::ffi::sd_bus_error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// libsystemd failed with this errno, doing what the text says.
    Os { errno: i32, doing: &'static str },
    /// A D-Bus error: its name (org.freedesktop.DBus.Error.UnknownMethod) and message.
    Bus { name: String, message: String },
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    /// A D-Bus error to answer a call with.
    pub fn bus(name: &str, message: impl Into<String>) -> Error {
        Error::Bus {
            name: name.into(),
            message: message.into(),
        }
    }

    /// The error a call was answered with, as the bus names it; none for an errno.
    pub fn name(&self) -> Option<&str> {
        match self {
            Error::Bus { name, .. } => Some(name),
            Error::Os { .. } => None,
        }
    }

    /// The errno, for one libsystemd returned.
    pub fn errno(&self) -> Option<i32> {
        match self {
            Error::Os { errno, .. } => Some(*errno),
            Error::Bus { .. } => None,
        }
    }

    /// Whether the connection is gone, so that only a new one will do.
    pub fn is_disconnect(&self) -> bool {
        // EPIPE, ECONNRESET, ENOTCONN, ESHUTDOWN: what sd-bus returns once
        // the other end has closed. A call says the same through an error
        // name, since sd_bus_call sets one for nearly every failure.
        matches!(self.errno(), Some(32 | 104 | 107 | 108))
            || matches!(
                self.name(),
                Some(
                    "org.freedesktop.DBus.Error.Disconnected"
                        | "System.Error.EPIPE"
                        | "System.Error.ECONNRESET"
                        | "System.Error.ENOTCONN"
                        | "System.Error.ESHUTDOWN"
                )
            )
    }

    /// From an sd_bus_error that was set, which it frees.
    pub(crate) fn from_bus_error(
        error: &mut sd_bus_error,
        errno: i32,
        doing: &'static str,
    ) -> Error {
        let text = |p: *const std::ffi::c_char| {
            if p.is_null() {
                String::new()
            } else {
                // SAFETY: sd-bus keeps a set error's strings NUL-terminated until it is freed.
                unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
            }
        };
        let found = if error.name.is_null() {
            Error::Os { errno, doing }
        } else {
            Error::Bus {
                name: text(error.name),
                message: text(error.message),
            }
        };
        // SAFETY: the error is sd-bus's, and freed once, here.
        unsafe { crate::ffi::sd_bus_error_free(error) };
        found
    }
}

/// A libsystemd return value: a negative one is an errno.
pub(crate) fn check(r: i32, doing: &'static str) -> Result<i32> {
    if r < 0 {
        Err(Error::Os { errno: -r, doing })
    } else {
        Ok(r)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Error::Os { errno, doing } => {
                write!(f, "{doing}: {}", std::io::Error::from_raw_os_error(*errno))
            }
            Error::Bus { name, message } if message.is_empty() => write!(f, "{name}"),
            Error::Bus { name, message } => write!(f, "{message} ({name})"),
        }
    }
}

impl std::error::Error for Error {}
