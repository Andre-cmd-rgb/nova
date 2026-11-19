//! nova-sd: D-Bus and the journal for Nova's Rust, from libsystemd.
//!
//! Nova's Rust has no crates. What a D-Bus or journal crate would be for
//! comes from the library the system already runs on: sd-bus for D-Bus (a
//! connection to the session or system bus, calls, properties, signals, a
//! name and an object of one's own) and sd-journal for the journal (entries
//! matched by their fields, followed as they come). Both give a descriptor
//! to poll, so that a watcher sleeps until there is something for it.
//!
//! ```no_run
//! use nova_sd::{Bus, Value};
//! let bus = Bus::system()?;
//! let lid = bus.get_property("org.freedesktop.login1", "/org/freedesktop/login1",
//!                            "org.freedesktop.login1.Manager", "LidClosed")?;
//! println!("lid closed: {:?}", lid.as_bool());
//! # Ok::<(), nova_sd::Error>(())
//! ```

mod bus;
mod error;
mod ffi;
mod journal;
pub mod poll;
#[doc(hidden)]
pub mod testing;
mod value;

pub use bus::{
    rule, Bus, Handler, Interface, Message, Slot, ERROR_FAILED, ERROR_INVALID_ARGS,
    ERROR_NAME_HAS_NO_OWNER, ERROR_PROPERTY_READ_ONLY, ERROR_UNKNOWN_INTERFACE,
    ERROR_UNKNOWN_PROPERTY, NAME_ALLOW_REPLACEMENT, NAME_QUEUE, NAME_REPLACE_EXISTING,
};
pub use error::{Error, Result};
pub use journal::{Change, Journal};
pub use value::{split_signature, Value};
