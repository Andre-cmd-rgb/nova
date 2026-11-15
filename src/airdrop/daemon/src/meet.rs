//! Where the daemon and the `nova airdrop` command meet: a socket in the
//! user's runtime folder, which is there while the user is logged in and is
//! theirs alone. control.rs has what is said over it. The doorbell's socket
//! is beside it. Each program that includes this uses some of it.
#![allow(dead_code)]

use std::path::PathBuf;

extern "C" {
    fn geteuid() -> u32;
}

/// The user's number, as the system has it.
pub fn user() -> u32 {
    // SAFETY: takes nothing, cannot fail.
    unsafe { geteuid() }
}

/// The user's runtime folder. A daemon started by the system is not told it, and it is where it always is.
pub fn runtime() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(folder) if !folder.is_empty() => PathBuf::from(folder),
        _ => PathBuf::from(format!("/run/user/{}", user())),
    }
}

pub fn socket() -> PathBuf {
    runtime().join("nova/airdrop.sock")
}

/// AirDrop's doorbell's (nova-airdrop-bell): Bluetooth listening for the user's iPhone.
pub fn bell() -> PathBuf {
    runtime().join("nova/airdrop-bell.sock")
}
