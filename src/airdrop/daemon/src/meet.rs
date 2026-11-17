//! Where the daemon and the `nova airdrop` command meet: a socket in the
//! user's runtime folder, which is there while the user is logged in and is
//! theirs alone. control.rs has what is said over it. The doorbell's socket
//! is beside it. Each program that includes this uses some of it.
#![allow(dead_code)]

use std::ffi::{c_int, c_void};
use std::io;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
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

// ------------------------------------------------- what both say

/// The daemon's answer to `hold` and `stay` once it has decided to end: whoever asked waits for it
/// to go, and starts it again (control.rs). A `send` is told so with a line of its own.
pub const GOING_OFF: &str = "AirDrop is going off.";

/// A string as JSON has it.
pub fn quoted(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 || c == '\u{2028}' || c == '\u{2029}' => {
                out.push_str(&format!("\\u{:04x}", c as u32))
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A size as people say it.
pub fn size(bytes: u64) -> String {
    match bytes {
        0..=999 => format!("{bytes} bytes"),
        1_000..=999_999 => format!("{:.0} kB", bytes as f64 / 1e3),
        1_000_000..=999_999_999 => format!("{:.1} MB", bytes as f64 / 1e6),
        _ => format!("{:.2} GB", bytes as f64 / 1e9),
    }
}

// ------------------------------------------- files passed over the socket

#[repr(C)]
struct IoVec {
    base: *mut c_void,
    length: usize,
}

#[repr(C)]
struct MsgHdr {
    name: *mut c_void,
    name_length: u32,
    io: *mut IoVec,
    io_length: usize,
    control: *mut c_void,
    control_length: usize,
    flags: c_int,
}

extern "C" {
    fn recvmsg(fd: c_int, message: *mut MsgHdr, flags: c_int) -> isize;
    fn sendmsg(fd: c_int, message: *const MsgHdr, flags: c_int) -> isize;
}

const SOL_SOCKET: c_int = 1;
const SCM_RIGHTS: c_int = 1;
const MSG_CMSG_CLOEXEC: c_int = 0x4000_0000;
/// The most descriptors the kernel passes in one message.
pub const MOST_FILES: usize = 253;

/// Reads what a client said, and the files it passed with it (SCM_RIGHTS): `nova airdrop send`
/// hands over the files it was given open, so that this reads what the user could, wherever it is.
pub fn receive_with_files(fd: RawFd, buffer: &mut [u8]) -> io::Result<(usize, Vec<OwnedFd>)> {
    // A header of 16 bytes, then the descriptors, four bytes each: room for as many as can come.
    let mut control = vec![0u64; (16 + MOST_FILES * 4).div_ceil(8)];
    let mut io = IoVec {
        base: buffer.as_mut_ptr().cast(),
        length: buffer.len(),
    };
    let mut message = MsgHdr {
        name: std::ptr::null_mut(),
        name_length: 0,
        io: &mut io,
        io_length: 1,
        control: control.as_mut_ptr().cast(),
        control_length: control.len() * 8,
        flags: 0,
    };
    // SAFETY: the message describes a buffer and room for its control data, both alive across the call.
    let size = unsafe { recvmsg(fd, &mut message, MSG_CMSG_CLOEXEC) };
    if size < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut files = Vec::new();
    // SAFETY: the kernel wrote message.control_length bytes of control data into `control`, which
    // outlives this view of it.
    let bytes = unsafe {
        std::slice::from_raw_parts(control.as_ptr().cast::<u8>(), message.control_length)
    };
    let mut at = 0;
    while at + 16 <= bytes.len() {
        let length = usize::from_ne_bytes(bytes[at..at + 8].try_into().unwrap());
        let level = c_int::from_ne_bytes(bytes[at + 8..at + 12].try_into().unwrap());
        let kind = c_int::from_ne_bytes(bytes[at + 12..at + 16].try_into().unwrap());
        if length < 16 || at + length > bytes.len() {
            break;
        }
        if level == SOL_SOCKET && kind == SCM_RIGHTS {
            for raw in bytes[at + 16..at + length].as_chunks::<4>().0 {
                // SAFETY: the kernel gave this process these descriptors, and nothing else has them.
                files.push(unsafe { OwnedFd::from_raw_fd(c_int::from_ne_bytes(*raw)) });
            }
        }
        at += length.div_ceil(8) * 8;
    }
    Ok((size as usize, files))
}

/// What `nova airdrop send` does: says its words with the files it was given, open
/// (SCM_RIGHTS). How much of the words went, or -1.
pub fn send_with_files(fd: RawFd, words: &[u8], files: &[RawFd]) -> isize {
    let mut control = vec![0u64; (16 + files.len() * 4).div_ceil(8)];
    let length = 16 + files.len() * 4;
    let bytes: &mut [u8] =
        // SAFETY: a view of the buffer just made, as bytes.
        unsafe { std::slice::from_raw_parts_mut(control.as_mut_ptr().cast(), control.len() * 8) };
    bytes[..8].copy_from_slice(&length.to_ne_bytes());
    bytes[8..12].copy_from_slice(&SOL_SOCKET.to_ne_bytes());
    bytes[12..16].copy_from_slice(&SCM_RIGHTS.to_ne_bytes());
    for (i, file) in files.iter().enumerate() {
        bytes[16 + i * 4..20 + i * 4].copy_from_slice(&file.to_ne_bytes());
    }
    let mut io = IoVec {
        base: words.as_ptr() as *mut c_void,
        length: words.len(),
    };
    let message = MsgHdr {
        name: std::ptr::null_mut(),
        name_length: 0,
        io: &mut io,
        io_length: 1,
        control: control.as_mut_ptr().cast(),
        control_length: if files.is_empty() {
            0
        } else {
            control.len() * 8
        },
        flags: 0,
    };
    // SAFETY: the message describes buffers alive across the call.
    unsafe { sendmsg(fd, &message, 0) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, File};
    use std::io::{Read, Write};
    use std::os::fd::AsRawFd;

    #[test]
    fn files_passed_with_words_arrive_open() {
        let (ours, theirs) = std::os::unix::net::UnixStream::pair().unwrap();
        let path = std::env::temp_dir().join(format!("nova-airdrop-fds-{}", std::process::id()));
        fs::write(&path, b"what the user picked").unwrap();
        let file = File::open(&path).unwrap();
        assert_eq!(
            send_with_files(
                ours.as_raw_fd(),
                b"send\n",
                &[file.as_raw_fd(), file.as_raw_fd()]
            ),
            5
        );
        let mut buffer = [0u8; 64];
        let (size, files) = receive_with_files(theirs.as_raw_fd(), &mut buffer).unwrap();
        assert_eq!((&buffer[..size], files.len()), (&b"send\n"[..], 2));
        let mut got = String::new();
        File::from(files.into_iter().next().unwrap())
            .read_to_string(&mut got)
            .unwrap();
        assert_eq!(got, "what the user picked");
        // Words alone.
        (&ours).write_all(b"status\n").unwrap();
        let (size, files) = receive_with_files(theirs.as_raw_fd(), &mut buffer).unwrap();
        assert_eq!((&buffer[..size], files.len()), (&b"status\n"[..], 0));
        fs::remove_file(&path).unwrap();
    }
}
