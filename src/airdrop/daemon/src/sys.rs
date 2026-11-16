//! The kernel's side: the socket on the monitor interface, the interface
//! AirDrop's IP runs on, and the network namespace both that and the receiver
//! live in.
//!
//! The namespace is the point of this file. AWDL reaches whoever is in radio
//! range, and an interface for it in the system's own namespace would put
//! everything that listens on every interface (a printer queue, a login
//! server, the system's own mDNS with the computer's name) within reach of
//! every phone nearby; and the system reaches back: udev gives a new
//! interface an address of its choosing, NetworkManager takes it up (in one
//! test run of three the kernel then never answered the phone). So the daemon
//! opens the monitor interface's socket, which stays where it was opened, and
//! then leaves for a namespace of its own, where the only interface is awdl0
//! and the only listener is AirDrop's.
//!
//! libc is linked into every Rust program on Linux; what is used of it is
//! declared here, as in Nova's other daemons, and not depended on.

use std::ffi::{c_char, c_int, c_long, c_uint, c_ulong, c_void, CString};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::packet;
use crate::wire::Mac;

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}

#[repr(C)]
struct Timespec {
    seconds: c_long,
    nanoseconds: c_long,
}

extern "C" {
    fn socket(domain: c_int, kind: c_int, protocol: c_int) -> c_int;
    fn bind(fd: c_int, address: *const c_void, length: u32) -> c_int;
    fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const c_void, length: u32)
        -> c_int;
    fn recv(fd: c_int, buffer: *mut c_void, length: usize, flags: c_int) -> isize;
    fn send(fd: c_int, buffer: *const c_void, length: usize, flags: c_int) -> isize;
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
    fn ppoll(
        fds: *mut PollFd,
        count: c_ulong,
        timeout: *const Timespec,
        mask: *const c_void,
    ) -> c_int;
    fn if_nametoindex(name: *const c_char) -> c_uint;
    fn unshare(flags: c_int) -> c_int;
    fn geteuid() -> u32;
    fn getegid() -> u32;
    fn signal(signal: c_int, handler: usize) -> usize;
}

const AF_PACKET: c_int = 17;
const AF_INET6: c_int = 10;
const SOCK_DGRAM: c_int = 2;
const SOCK_RAW: c_int = 3;
const SOCK_NONBLOCK: c_int = 0o4000;
const SOCK_CLOEXEC: c_int = 0o2000000;
const ETH_P_ALL: u16 = 3;
const SOL_SOCKET: c_int = 1;
const SO_SNDBUF: c_int = 7;
const SO_RCVBUF: c_int = 8;
const SO_SNDBUFFORCE: c_int = 32;
const SO_RCVBUFFORCE: c_int = 33;
const IPPROTO_TCP: c_int = 6;
const TCP_QUICKACK: c_int = 12;
const MSG_DONTWAIT: c_int = 0x40;
const POLLIN: i16 = 1;
const O_NONBLOCK: c_int = 0o4000;
const CLONE_NEWUSER: c_int = 0x1000_0000;
const CLONE_NEWNET: c_int = 0x4000_0000;

const TUNSETIFF: c_ulong = 0x4004_54ca;
const IFF_TAP: i16 = 0x0002;
const IFF_NO_PI: i16 = 0x1000;
const SIOCGIFFLAGS: c_ulong = 0x8913;
const SIOCSIFFLAGS: c_ulong = 0x8914;
const SIOCSIFADDR: c_ulong = 0x8916;
const SIOCSIFMTU: c_ulong = 0x8922;
const SIOCSIFHWADDR: c_ulong = 0x8924;
const SIOCGIFHWADDR: c_ulong = 0x8927;
const SIOCGIFINDEX: c_ulong = 0x8933;
const IFF_UP: i16 = 1;
const ARPHRD_ETHER: u16 = 1;

fn failed<T>(what: &str) -> io::Result<T> {
    let error = io::Error::last_os_error();
    Err(io::Error::new(error.kind(), format!("{what}: {error}")))
}

fn option(fd: RawFd, level: c_int, name: c_int, value: c_int) -> bool {
    // SAFETY: the value is an int and its size is given as an int's.
    unsafe { setsockopt(fd, level, name, (&value as *const c_int).cast(), 4) == 0 }
}

// ----------------------------------------------------------------- signals

static STOPPING: AtomicBool = AtomicBool::new(false);

// Async-signal-safe: it sets a flag. The loop looks at it.
extern "C" fn on_signal(_: c_int) {
    STOPPING.store(true, Ordering::SeqCst);
}

/// SIGTERM and SIGINT end the loop instead of the process, so that it ends tidily.
pub fn stop_on_signals() {
    // SAFETY: the handler only stores to an atomic.
    unsafe {
        signal(15, on_signal as *const () as usize);
        signal(2, on_signal as *const () as usize);
    }
}

pub fn stopping() -> bool {
    STOPPING.load(Ordering::SeqCst)
}

/// The same end as a signal's, asked for from inside.
pub fn stop() {
    STOPPING.store(true, Ordering::SeqCst);
}

// ------------------------------------------------------------------ systemd

/// systemd's ear for this service, when systemd started it and waits to be
/// told that it is up (Type=notify). Connected before the daemon leaves for
/// its own namespace, where the socket's name may mean nothing.
pub struct Notify(Option<std::os::unix::net::UnixDatagram>);

impl Notify {
    pub fn connect() -> Notify {
        use std::os::linux::net::SocketAddrExt;
        use std::os::unix::net::{SocketAddr, UnixDatagram};
        let connected = || {
            let name = std::env::var_os("NOTIFY_SOCKET")?;
            let name = std::os::unix::ffi::OsStrExt::as_bytes(name.as_os_str());
            let address = match name {
                [b'@', rest @ ..] => SocketAddr::from_abstract_name(rest).ok()?,
                _ => {
                    SocketAddr::from_pathname(std::ffi::OsStr::new(std::str::from_utf8(name).ok()?))
                        .ok()?
                }
            };
            let socket = UnixDatagram::unbound().ok()?;
            socket.connect_addr(&address).ok()?;
            Some(socket)
        };
        Notify(connected())
    }

    /// Up, and in a few words how.
    pub fn ready(&self, status: &str) {
        if let Some(socket) = &self.0 {
            let _ = socket.send(format!("READY=1\nSTATUS={status}\n").as_bytes());
        }
    }

    /// Still going round: a daemon that stops saying so is ended by systemd (WatchdogSec), and the
    /// Wi-Fi it holds is given back.
    pub fn alive(&self) {
        if let Some(socket) = &self.0 {
            let _ = socket.send(b"WATCHDOG=1\n");
        }
    }
}

// ------------------------------------------------------------ capabilities

#[repr(C)]
struct CapHeader {
    version: u32,
    pid: c_int,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CapData {
    effective: u32,
    permitted: u32,
    inheritable: u32,
}

extern "C" {
    fn capset(header: *mut CapHeader, data: *const CapData) -> c_int;
}

const CAPABILITY_VERSION_3: u32 = 0x2008_0522;

/// Gives up every capability, for good, and with them the ambient ones a program it runs would
/// be given: the sockets already bound keep what they were let do. A user namespace it makes
/// later is its own, with what it takes to set up a network in it.
pub fn give_up_capabilities() -> io::Result<()> {
    let mut header = CapHeader {
        version: CAPABILITY_VERSION_3,
        pid: 0,
    };
    let none = [CapData {
        effective: 0,
        permitted: 0,
        inheritable: 0,
    }; 2];
    // SAFETY: the header and the two data the third version takes live across the call.
    if unsafe { capset(&mut header, none.as_ptr()) } != 0 {
        return failed("giving up its capabilities");
    }
    Ok(())
}

// --------------------------------------------------------------- namespace

/// Leaves for a network namespace of this process's own. As root that is all
/// it takes; as a user it takes a user namespace too, in which the user is
/// who they were (so that files are theirs) and may set up the network.
/// Before any thread is started: the kernel refuses otherwise.
pub fn own_namespace() -> io::Result<()> {
    // SAFETY: no pointers; changes this process's namespaces, which is the intent.
    unsafe {
        let (user, group) = (geteuid(), getegid());
        if user == 0 {
            if unshare(CLONE_NEWNET) != 0 {
                return failed("a network namespace of its own");
            }
            return Ok(());
        }
        if unshare(CLONE_NEWUSER | CLONE_NEWNET) != 0 {
            return failed("a user and network namespace of its own");
        }
        fs::write("/proc/self/setgroups", "deny")?;
        fs::write("/proc/self/uid_map", format!("{user} {user} 1"))?;
        fs::write("/proc/self/gid_map", format!("{group} {group} 1"))?;
    }
    Ok(())
}

// --------------------------------------------------------------------- air

/// Where frames are sent and heard: the monitor interface, or in tests a
/// socket something else is at the other end of.
pub struct Air {
    fd: OwnedFd,
}

impl Air {
    pub fn monitor(interface: &str) -> io::Result<Air> {
        let name = CString::new(interface)
            .map_err(|_| io::Error::other("an interface name with a NUL in it"))?;
        // SAFETY: the name is NUL-terminated; the address structure is as long as it is said to be, and the socket is owned from the moment it exists.
        unsafe {
            let index = if_nametoindex(name.as_ptr());
            if index == 0 {
                return failed(&format!("no interface {interface}"));
            }
            let fd = socket(
                AF_PACKET,
                SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC,
                c_int::from(ETH_P_ALL.to_be()),
            );
            if fd < 0 {
                return failed("a socket on the monitor interface (it takes CAP_NET_RAW)");
            }
            let air = Air {
                fd: OwnedFd::from_raw_fd(fd),
            };
            // sockaddr_ll: family, protocol, interface, and nothing of the rest.
            let mut address = [0u8; 20];
            address[0..2].copy_from_slice(&(AF_PACKET as u16).to_ne_bytes());
            address[2..4].copy_from_slice(&ETH_P_ALL.to_be_bytes());
            address[4..8].copy_from_slice(&(index as i32).to_ne_bytes());
            if bind(fd, address.as_ptr().cast(), 20) != 0 {
                return failed(&format!("binding to {interface}"));
            }
            // Room for what the driver holds back while the channel is busy: a full buffer drops frames.
            if !option(fd, SOL_SOCKET, SO_SNDBUFFORCE, 8 << 20) {
                option(fd, SOL_SOCKET, SO_SNDBUF, 8 << 20);
            }
            option(fd, SOL_SOCKET, SO_RCVBUFFORCE, 8 << 20);
            Ok(air)
        }
    }

    /// A socket this process was started with.
    pub fn inherited(fd: RawFd) -> Air {
        // SAFETY: the caller hands over a descriptor nothing else in this process uses.
        Air {
            fd: unsafe { OwnedFd::from_raw_fd(fd) },
        }
    }

    /// The next frame heard, if there is one.
    pub fn heard(&self, buffer: &mut [u8]) -> Option<usize> {
        // SAFETY: the buffer is as long as it is said to be.
        let got = unsafe {
            recv(
                self.fd.as_raw_fd(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                MSG_DONTWAIT,
            )
        };
        (got > 0).then_some(got as usize)
    }

    /// Hands a frame to the driver; false if it would not take it.
    pub fn send(&self, frame: &[u8]) -> bool {
        // SAFETY: the buffer is as long as it is said to be.
        unsafe {
            send(
                self.fd.as_raw_fd(),
                frame.as_ptr().cast(),
                frame.len(),
                MSG_DONTWAIT,
            ) == frame.len() as isize
        }
    }
}

impl AsRawFd for Air {
    fn as_raw_fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }
}

// --------------------------------------------------------------- interface

/// An interface request as the kernel's ioctls take it: sixteen bytes of name, then what is asked.
fn request(name: &str) -> io::Result<[u8; 40]> {
    let mut request = [0u8; 40];
    if name.len() > 15 || name.contains('\0') {
        return Err(io::Error::other("an interface name too long"));
    }
    request[..name.len()].copy_from_slice(name.as_bytes());
    Ok(request)
}

/// A socket to ask the kernel about interfaces with.
fn asking() -> io::Result<OwnedFd> {
    // SAFETY: no pointers; the socket is owned from the moment it exists.
    unsafe {
        let fd = socket(AF_INET6, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if fd < 0 {
            return failed("IPv6 (is it turned off on this system?)");
        }
        Ok(OwnedFd::from_raw_fd(fd))
    }
}

/// An interface's hardware address.
pub fn hardware_address(name: &str) -> io::Result<Mac> {
    let mut asked = request(name)?;
    let socket = asking()?;
    // SAFETY: the request is the forty bytes the kernel reads and writes.
    if unsafe { ioctl(socket.as_raw_fd(), SIOCGIFHWADDR, asked.as_mut_ptr()) } != 0 {
        return failed(&format!("the address of {name}"));
    }
    Ok(asked[18..24].try_into().unwrap())
}

/// The interface the kernel's IP for AirDrop runs on: a TAP, with this
/// node's AWDL address as its hardware address and the link-local address
/// made from it, and nothing the kernel would configure by itself.
pub struct Tap {
    file: File,
    name: String,
}

impl Tap {
    pub fn open(name: &str, address: &Mac, mtu: u32) -> io::Result<Tap> {
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(O_NONBLOCK)
            .open("/dev/net/tun")?;
        let mut asked = request(name)?;
        asked[16..18].copy_from_slice(&(IFF_TAP | IFF_NO_PI).to_ne_bytes());
        // SAFETY: each request is the forty bytes (twenty-four, for the address) the kernel reads.
        unsafe {
            if ioctl(file.as_raw_fd(), TUNSETIFF, asked.as_mut_ptr()) != 0 {
                return failed(&format!("making {name}"));
            }
            let socket = asking()?;
            let fd = socket.as_raw_fd();

            let mut asked = request(name)?;
            asked[16..18].copy_from_slice(&ARPHRD_ETHER.to_ne_bytes());
            asked[18..24].copy_from_slice(address);
            if ioctl(fd, SIOCSIFHWADDR, asked.as_mut_ptr()) != 0 {
                return failed(&format!("giving {name} its address"));
            }
            let mut asked = request(name)?;
            asked[16..20].copy_from_slice(&(mtu as i32).to_ne_bytes());
            if ioctl(fd, SIOCSIFMTU, asked.as_mut_ptr()) != 0 {
                return failed(&format!("the packet size of {name}"));
            }

            // No address of the kernel's own making (this one is given below), no check that it is free (AWDL
            // has no way to answer one), no looking for routers.
            for (key, value) in [
                ("addr_gen_mode", "1"),
                ("accept_dad", "0"),
                ("dad_transmits", "0"),
                ("accept_ra", "0"),
                ("router_solicitations", "0"),
                ("autoconf", "0"),
            ] {
                fs::write(format!("/proc/sys/net/ipv6/conf/{name}/{key}"), value).map_err(
                    |error| {
                        io::Error::new(error.kind(), format!("setting {key} of {name}: {error}"))
                    },
                )?;
            }

            let mut asked = request(name)?;
            if ioctl(fd, SIOCGIFINDEX, asked.as_mut_ptr()) != 0 {
                return failed(&format!("the number of {name}"));
            }
            // in6_ifreq: the address, the prefix length, the interface.
            let mut wanted = [0u8; 24];
            wanted[..16].copy_from_slice(&packet::link_local(address));
            wanted[16..20].copy_from_slice(&64u32.to_ne_bytes());
            wanted[20..24].copy_from_slice(&asked[16..20]);
            if ioctl(fd, SIOCSIFADDR, wanted.as_mut_ptr()) != 0
                && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists
            {
                return failed(&format!("the IPv6 address of {name}"));
            }

            let mut asked = request(name)?;
            if ioctl(fd, SIOCGIFFLAGS, asked.as_mut_ptr()) != 0 {
                return failed(&format!("the state of {name}"));
            }
            let flags = i16::from_ne_bytes([asked[16], asked[17]]) | IFF_UP;
            asked[16..18].copy_from_slice(&flags.to_ne_bytes());
            if ioctl(fd, SIOCSIFFLAGS, asked.as_mut_ptr()) != 0 {
                return failed(&format!("bringing {name} up"));
            }
        }
        Ok(Tap {
            file,
            name: name.to_owned(),
        })
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// The next frame the kernel sent, if there is one.
    pub fn sent(&self, buffer: &mut [u8]) -> Option<usize> {
        (&self.file).read(buffer).ok().filter(|size| *size > 0)
    }

    /// Hands a frame to the kernel; false if it would not take it.
    pub fn receive(&self, frame: &[u8]) -> bool {
        (&self.file).write(frame).is_ok()
    }
}

impl AsRawFd for Tap {
    fn as_raw_fd(&self) -> RawFd {
        self.file.as_raw_fd()
    }
}

// --------------------------------------------------------------- waiting

/// Waits until one of two descriptors has something to read, a signal
/// arrives, or the time is up. To the microsecond: the announcements go out
/// on a beat that phones set their clocks by.
pub fn wait(first: RawFd, second: RawFd, microseconds: u64) {
    let mut fds = [
        PollFd {
            fd: first,
            events: POLLIN,
            revents: 0,
        },
        PollFd {
            fd: second,
            events: POLLIN,
            revents: 0,
        },
    ];
    let timeout = Timespec {
        seconds: (microseconds / 1_000_000) as c_long,
        nanoseconds: (microseconds % 1_000_000 * 1000) as c_long,
    };
    // SAFETY: two descriptors as counted, a timeout that lives across the call, no signal mask.
    unsafe { ppoll(fds.as_mut_ptr(), 2, &timeout, std::ptr::null()) };
}

// --------------------------------------------------------------- sockets

/// The number of an interface in this namespace (a link-local address's scope); 0 if none.
pub fn interface_index(name: &str) -> u32 {
    CString::new(name).map_or(0, |name| {
        // SAFETY: a NUL-terminated name, alive across the call.
        unsafe { if_nametoindex(name.as_ptr()) }
    })
}

/// Room for a whole burst of a sender: it sends for a tenth of a second at a
/// time, megabytes a second, and what does not fit waits a second for the next.
pub fn roomy(socket: &impl AsRawFd) {
    if !option(socket.as_raw_fd(), SOL_SOCKET, SO_RCVBUFFORCE, 8 << 20) {
        option(socket.as_raw_fd(), SOL_SOCKET, SO_RCVBUF, 8 << 20);
    }
}

/// Acknowledge at once what arrives, each segment: the sender's burst is
/// short, and it sends on as it is acknowledged. The kernel forgets this
/// after a while; it is said again as the upload is read.
pub fn acknowledge_at_once(socket: RawFd) {
    option(socket, IPPROTO_TCP, TCP_QUICKACK, 1);
}

#[cfg(test)]
pub mod tests {
    use super::*;

    #[test]
    fn interface_requests_are_laid_out_as_the_kernel_reads_them() {
        let asked = request("awdl0").unwrap();
        assert_eq!(&asked[..6], b"awdl0\0");
        assert!(request("a-name-that-is-too-long").is_err());
        // The loopback interface is always there, and has no hardware address to speak of.
        assert_eq!(hardware_address("lo").unwrap(), [0; 6]);
        assert!(hardware_address("nova-none0").is_err());
        assert!(Air::monitor("nova-none0").is_err());
    }
}
