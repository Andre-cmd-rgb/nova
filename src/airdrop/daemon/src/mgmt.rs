//! The kernel's Bluetooth management socket, the one `bluetoothd` uses:
//! commands to a controller and their answers, and the events in between.
//! AirDrop's doorbell listens with it (nova-airdrop-bell) and the daemon's
//! announcer announces this computer with it while it sends (announcer.rs,
//! wake.rs); each uses some of it.
//!
//! The kernel lets such a socket do more than read if the process had
//! CAP_NET_ADMIN when it bound it, and decides that once, at binding: both
//! give the capability up right after.
#![allow(dead_code)]

use std::collections::VecDeque;
use std::ffi::{c_int, c_ulong, c_void};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::time::{Duration, Instant};

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}

#[repr(C)]
pub struct SockaddrHci {
    family: u16,
    device: u16,
    channel: u16,
}

extern "C" {
    fn socket(domain: c_int, kind: c_int, protocol: c_int) -> c_int;
    fn bind(fd: c_int, address: *const c_void, length: u32) -> c_int;
    fn recv(fd: c_int, buffer: *mut c_void, length: usize, flags: c_int) -> isize;
    fn send(fd: c_int, buffer: *const c_void, length: usize, flags: c_int) -> isize;
    fn poll(fds: *mut PollFd, count: c_ulong, timeout: c_int) -> c_int;
}

const AF_BLUETOOTH: c_int = 31;
const SOCK_RAW: c_int = 3;
const SOCK_NONBLOCK: c_int = 0o4000;
const SOCK_CLOEXEC: c_int = 0o2000000;
const BTPROTO_HCI: c_int = 1;
const HCI_CHANNEL_CONTROL: u16 = 3;
const POLLIN: i16 = 1;

/// No controller in particular: for the commands about all of them.
pub const HCI_DEV_NONE: u16 = 0xffff;

// The commands and events every user of this needs (include/net/bluetooth/mgmt.h).
pub const READ_INDEX_LIST: u16 = 0x0003;
pub const READ_INFO: u16 = 0x0004;
pub const EV_COMPLETE: u16 = 0x0001;
pub const EV_STATUS: u16 = 0x0002;
/// The controller's "powered" setting, in READ_INFO's settings and in New Settings.
pub const POWERED: u32 = 1;
/// Its "low energy" one: Bluetooth Low Energy, which AirDrop's announcement and the doorbell's
/// listening both are, off where the user switched it off (Settings → Bluetooth).
pub const LE: u32 = 1 << 9;

/// The kernel's Bluetooth management, for every controller at once.
pub struct Mgmt {
    pub fd: OwnedFd,
    /// Events that came while an answer was waited for.
    pub early: VecDeque<Vec<u8>>,
}

impl Mgmt {
    pub fn open() -> io::Result<Mgmt> {
        // SAFETY: no pointers.
        let fd = unsafe {
            socket(
                AF_BLUETOOTH,
                SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC,
                BTPROTO_HCI,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: just made, and nobody else's.
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let address = SockaddrHci {
            family: AF_BLUETOOTH as u16,
            device: HCI_DEV_NONE,
            channel: HCI_CHANNEL_CONTROL,
        };
        // SAFETY: the address lives across the call and its size is its own.
        let bound = unsafe {
            bind(
                fd.as_raw_fd(),
                (&address as *const SockaddrHci).cast(),
                std::mem::size_of::<SockaddrHci>() as u32,
            )
        };
        if bound != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Mgmt {
            fd,
            early: VecDeque::new(),
        })
    }

    /// The next event, if one is there.
    pub fn read(&mut self) -> Option<Vec<u8>> {
        if let Some(event) = self.early.pop_front() {
            return Some(event);
        }
        let mut buffer = [0u8; 1024];
        // SAFETY: the buffer is as long as said.
        let size = unsafe { recv(self.fd.as_raw_fd(), buffer.as_mut_ptr().cast(), 1024, 0) };
        (size >= 6).then(|| buffer[..size as usize].to_vec())
    }

    /// A command's status and answer; 0xff when none came.
    pub fn ask(&mut self, opcode: u16, index: u16, params: &[u8]) -> (u8, Vec<u8>) {
        let mut packet = Vec::with_capacity(6 + params.len());
        packet.extend_from_slice(&opcode.to_le_bytes());
        packet.extend_from_slice(&index.to_le_bytes());
        packet.extend_from_slice(&(params.len() as u16).to_le_bytes());
        packet.extend_from_slice(params);
        // SAFETY: the packet is as long as said.
        let sent = unsafe { send(self.fd.as_raw_fd(), packet.as_ptr().cast(), packet.len(), 0) };
        if sent != packet.len() as isize {
            return (0xff, Vec::new());
        }
        let until = Instant::now() + Duration::from_secs(3);
        while let Some(left) = until.checked_duration_since(Instant::now()) {
            wait(&[self.fd.as_raw_fd()], left);
            let mut buffer = [0u8; 1024];
            // SAFETY: as in read.
            let size = unsafe { recv(self.fd.as_raw_fd(), buffer.as_mut_ptr().cast(), 1024, 0) };
            if size < 6 {
                continue;
            }
            let event = &buffer[..size as usize];
            let kind = u16::from_le_bytes([event[0], event[1]]);
            if matches!(kind, EV_COMPLETE | EV_STATUS)
                && event.len() >= 9
                && u16::from_le_bytes([event[6], event[7]]) == opcode
            {
                return (event[8], event[9..].to_vec());
            }
            self.early.push_back(event.to_vec());
        }
        (0xff, Vec::new())
    }

    /// The first controller there is, and its settings (none, when it would not say).
    pub fn controller(&mut self) -> Option<(u16, u32)> {
        let (status, answer) = self.ask(READ_INDEX_LIST, HCI_DEV_NONE, &[]);
        if status != 0 || answer.len() < 4 || u16::from_le_bytes([answer[0], answer[1]]) == 0 {
            return None;
        }
        let index = u16::from_le_bytes([answer[2], answer[3]]);
        let (status, answer) = self.ask(READ_INFO, index, &[]);
        Some((index, settings(status, &answer)))
    }
}

/// The current settings in an answer to READ_INFO: none, when it is no answer.
pub fn settings(status: u8, answer: &[u8]) -> u32 {
    match answer.get(13..17) {
        Some(bytes) if status == 0 => u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
        _ => 0,
    }
}

/// Waits until one of the descriptors has something to read, or the time is up.
pub fn wait(fds: &[RawFd], at_most: Duration) {
    let mut polled: Vec<PollFd> = fds
        .iter()
        .map(|fd| PollFd {
            fd: *fd,
            events: POLLIN,
            revents: 0,
        })
        .collect();
    let timeout = at_most.as_millis().min(60_000) as c_int;
    // SAFETY: as many descriptors as counted.
    unsafe { poll(polled.as_mut_ptr(), polled.len() as c_ulong, timeout) };
}

pub fn status_words(status: u8) -> &'static str {
    match status {
        0x01 => "unknown command",
        0x03 => "failed",
        0x07 => "no resources",
        0x0a => "busy",
        0x0b => "rejected",
        0x0c => "not supported",
        0x0d => "invalid parameters",
        0x0f => "not powered",
        0x11 => "invalid index",
        0x12 => "blocked by the radio switch",
        0x14 => "permission denied",
        0xff => "no answer",
        _ => "refused",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_socket_address_is_laid_out_as_the_kernel_reads_it() {
        assert_eq!(std::mem::size_of::<SockaddrHci>(), 6);
        assert_eq!(status_words(0x0f), "not powered");
    }
}
