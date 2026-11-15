//! nova-airdrop-bell: AirDrop's doorbell. An iPhone announces itself over
//! Bluetooth while its share sheet shows AirDrop, and stops when the sheet
//! closes. This gives the Bluetooth controller a pattern of the user's own
//! iPhone to listen for, which the controller compares by itself: the
//! computer is told only when it matches, and not woken otherwise. Whoever
//! asks (the shell) is told when that iPhone starts announcing and when it
//! stops, and switches AirDrop on and off by that.
//!
//!   nova-airdrop-bell [--phones <file>] [--control <socket>]
//!
//! It knows an iPhone once it has learned it (`learn` on its socket): for a
//! minute it listens for any iPhone's announcement, and keeps the first one
//! that is close to the computer in --phones (by default nova/airdrop/phones
//! under the user's state folder). What is kept are the four two-byte fields
//! of the announcement that are the same from one share sheet to the next
//! (the iPhone shuffles their order and changes the rest each time). Nothing
//! of any other phone is kept, or logged.
//!
//! Whoever connects to the socket says one line:
//!
//!   watch    how it is, as a line of JSON, now and at each change
//!   status   the same in plain words, once
//!   learn    listen for a minute for an iPhone to know
//!   forget   know no iPhone any more
//!
//! and all but `watch` are answered with a line. The JSON has `state`
//! (`listening`, or `deaf` and `why`, a sentence for the user), `phones` (how
//! many it knows), `near` (one of them is announcing now) and `learning`
//! (when the minute ends, in Unix seconds; 0 while it is not learning).
//!
//! The kernel lets a socket on its Bluetooth management talk to the
//! controller if the process had CAP_NET_ADMIN when it bound the socket. The
//! unit gives it that one capability, and it is given up as soon as the
//! socket is bound.
//!
//! What it logs goes to standard error: that it started, learned, and why it
//! cannot listen, when it cannot.

#[path = "../meet.rs"]
mod meet;

use std::collections::{HashMap, VecDeque};
use std::ffi::{c_int, c_ulong, c_void};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}

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

#[repr(C)]
struct SockaddrHci {
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
    fn capset(header: *mut CapHeader, data: *const CapData) -> c_int;
    fn signal(signal: c_int, handler: usize) -> usize;
}

const AF_BLUETOOTH: c_int = 31;
const SOCK_RAW: c_int = 3;
const SOCK_NONBLOCK: c_int = 0o4000;
const SOCK_CLOEXEC: c_int = 0o2000000;
const BTPROTO_HCI: c_int = 1;
const HCI_DEV_NONE: u16 = 0xffff;
const HCI_CHANNEL_CONTROL: u16 = 3;
const POLLIN: i16 = 1;
const CAPABILITY_VERSION_3: u32 = 0x2008_0522;

// The kernel's management commands and events this uses (include/net/bluetooth/mgmt.h).
const READ_INDEX_LIST: u16 = 0x0003;
const READ_INFO: u16 = 0x0004;
const READ_MONITOR_FEATURES: u16 = 0x0051;
const REMOVE_MONITOR: u16 = 0x0053;
const ADD_PATTERNS_MONITOR_RSSI: u16 = 0x0056;
const EV_COMPLETE: u16 = 0x0001;
const EV_STATUS: u16 = 0x0002;
const EV_INDEX_ADDED: u16 = 0x0004;
const EV_INDEX_REMOVED: u16 = 0x0005;
const EV_NEW_SETTINGS: u16 = 0x0006;
const EV_DEVICE_FOUND: u16 = 0x0012;
const EV_MONITOR_REMOVED: u16 = 0x002c;
const EV_MONITOR_FOUND: u16 = 0x002f;
const EV_MONITOR_LOST: u16 = 0x0030;
const POWERED: u32 = 1;
/// The controller compares the patterns itself (Microsoft's extension, which Intel's and others' have).
const OFFLOADED: u32 = 1;

/// Found at once when louder than -85 dBm; gone after 3 s quieter than -95 dBm or unheard; while
/// found, the computer is told once a second (in tenths). Measured on an AX210: gone 2.2 s after
/// the share sheet closed.
const THRESHOLDS: [u8; 7] = [(-85i8) as u8, 0, 0, (-95i8) as u8, 3, 0, 10];
/// How close an iPhone must be to be learned: beside the computer, not across the room.
const LEARN_LOUDER_THAN: i8 = -65;
const LEARN_FOR: Duration = Duration::from_secs(60);
/// An iPhone that is near is heard once a second; one unheard for this long is gone, whatever the
/// kernel did or did not say.
const STALE: Duration = Duration::from_secs(6);
/// For this long after the controller went off or away, its "gone" is not taken at its word: an
/// Intel AX210 resets its Bluetooth now and then (hardware error 0x0c, once on the P1 while AirDrop
/// was busy on channel 6) and is back in a tenth of a second, the iPhone heard again at once.
/// Gone it may still be: unheard for STALE, it is.
const RESET_GRACE: Duration = Duration::from_secs(5);
const MOST_CLIENTS: usize = 16;
const CLIENT_SAYS_WITHIN: Duration = Duration::from_secs(5);

// ----------------------------------------------------------------- the iPhone

/// The fields of an iPhone's AirDrop announcement that stay the same from one share sheet to the
/// next, in the order it sent them; None for anything else. The announcement is Apple's message
/// 0x05, 18 bytes, in its manufacturer data; the fields are its bytes 9 to 16.
fn announcement(eir: &[u8]) -> Option<[u16; 4]> {
    let mut at = 0;
    while at < eir.len() && eir[at] != 0 {
        let size = usize::from(eir[at]);
        let part = eir.get(at + 1..at + 1 + size)?;
        if let [0xff, 0x4c, 0x00, messages @ ..] = part {
            let mut rest = messages;
            while let [kind, length, more @ ..] = rest {
                let Some(message) = more.get(..usize::from(*length)) else {
                    break;
                };
                if *kind == 0x05 && message.len() == 18 {
                    let field = |i: usize| u16::from_be_bytes([message[i], message[i + 1]]);
                    return Some([field(9), field(11), field(13), field(15)]);
                }
                rest = &more[message.len()..];
            }
        }
        at += 1 + size;
    }
    None
}

/// An iPhone this knows: its fields, sorted, none twice, no zeros.
#[derive(Clone, Debug, PartialEq)]
struct Phone(Vec<u16>);

impl Phone {
    fn of(fields: &[u16]) -> Option<Phone> {
        let mut fields: Vec<u16> = fields.iter().copied().filter(|f| *f != 0).collect();
        fields.sort_unstable();
        fields.dedup();
        (!fields.is_empty()).then_some(Phone(fields))
    }

    /// Whether an announcement is this iPhone's: two fields in common, or all it has if fewer.
    /// An iPhone whose owner adds an address keeps being known.
    fn is(&self, fields: &[u16]) -> bool {
        let Some(heard) = Phone::of(fields) else {
            return false;
        };
        let common = heard.0.iter().filter(|f| self.0.contains(f)).count();
        common > 0 && common >= self.0.len().min(heard.0.len()).min(2)
    }

    /// The patterns the controller listens for, any one of which is a match. The first field is
    /// always one of the phone's four, so with four that is all it takes; with fewer, a zero can
    /// be first, and each is looked for in every place.
    fn patterns(&self) -> Vec<[u8; 34]> {
        let places: &[u8] = if self.0.len() == 4 {
            &[13]
        } else {
            &[13, 15, 17, 19]
        };
        let mut patterns = Vec::new();
        for field in &self.0 {
            for place in places {
                patterns.push(pattern(*place, &field.to_be_bytes()));
            }
        }
        patterns
    }

    fn line(&self) -> String {
        self.0
            .iter()
            .map(|field| format!("{field:04x}"))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// A pattern as the kernel takes it: in manufacturer data (0xff), from `offset` (after its type).
fn pattern(offset: u8, value: &[u8]) -> [u8; 34] {
    let mut out = [0u8; 34];
    out[0] = 0xff;
    out[1] = offset;
    out[2] = value.len() as u8;
    out[3..3 + value.len()].copy_from_slice(value);
    out
}

/// Any iPhone's AirDrop announcement: Apple's number and the message's kind. For learning only.
fn any_iphone() -> [u8; 34] {
    pattern(0, &[0x4c, 0x00, 0x05])
}

fn read_phones(path: &Path) -> Vec<Phone> {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let mut phones: Vec<Phone> = Vec::new();
    for line in text.lines() {
        let fields: Option<Vec<u16>> = line
            .split_whitespace()
            .map(|word| u16::from_str_radix(word, 16).ok())
            .collect();
        if let Some(phone) = fields.as_deref().and_then(Phone::of) {
            if !phones.contains(&phone) {
                phones.push(phone);
            }
        }
    }
    phones
}

/// Written whole or not at all, readable by the user alone.
fn write_phones(path: &Path, phones: &[Phone]) -> io::Result<()> {
    if let Some(folder) = path.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(folder)?;
    }
    let new = path.with_extension("new");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&new)?;
    for phone in phones {
        writeln!(file, "{}", phone.line())?;
    }
    file.sync_all()?;
    std::fs::rename(&new, path)
}

// ------------------------------------------------------------------ the kernel

/// The kernel's Bluetooth management, for every controller at once.
struct Mgmt {
    fd: OwnedFd,
    /// Events that came while an answer was waited for.
    early: VecDeque<Vec<u8>>,
}

impl Mgmt {
    fn open() -> io::Result<Mgmt> {
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
    fn read(&mut self) -> Option<Vec<u8>> {
        if let Some(event) = self.early.pop_front() {
            return Some(event);
        }
        let mut buffer = [0u8; 1024];
        // SAFETY: the buffer is as long as said.
        let size = unsafe { recv(self.fd.as_raw_fd(), buffer.as_mut_ptr().cast(), 1024, 0) };
        (size >= 6).then(|| buffer[..size as usize].to_vec())
    }

    /// A command's status and answer; 0xff when none came.
    fn ask(&mut self, opcode: u16, index: u16, params: &[u8]) -> (u8, Vec<u8>) {
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
}

/// Gives up every capability, for good. The management socket keeps what it was let do.
fn give_up_capabilities() -> io::Result<()> {
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
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn wait(fds: &[RawFd], at_most: Duration) {
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

static STOPPING: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_: c_int) {
    STOPPING.store(true, Ordering::SeqCst);
}

fn status_words(status: u8) -> &'static str {
    match status {
        0x01 => "unknown command",
        0x03 => "failed",
        0x07 => "no resources",
        0x0c => "not supported",
        0x0d => "invalid parameters",
        0x0f => "not powered",
        0x11 => "invalid index",
        0x14 => "permission denied",
        0xff => "no answer",
        _ => "refused",
    }
}

fn log(line: &str) {
    let _ = writeln!(io::stderr(), "{line}");
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}

// ------------------------------------------------------------------- the bell

struct Bell {
    mgmt: Mgmt,
    phones_path: PathBuf,
    /// Where the monitors this put in place are noted, so that a bell that died is tidied after.
    monitors_path: PathBuf,
    phones: Vec<Phone>,
    index: Option<u16>,
    powered: bool,
    /// Why it cannot listen, while it cannot.
    why: Option<String>,
    monitors: Vec<u16>,
    /// The one for any iPhone, while learning.
    any: Option<u16>,
    learning: Option<(Instant, u64)>,
    /// The addresses a known iPhone is announcing from, and when each was last heard.
    near: HashMap<[u8; 6], Instant>,
    /// When the controller last went off or away.
    reset: Option<Instant>,
}

impl Bell {
    /// The monitors a bell put in place and did not take away (one that died).
    fn noted(&self) -> Vec<u16> {
        std::fs::read_to_string(&self.monitors_path)
            .unwrap_or_default()
            .split_whitespace()
            .filter_map(|word| word.parse().ok())
            .collect()
    }

    fn note(&self) {
        let words: Vec<String> = self.monitors.iter().map(u16::to_string).collect();
        let _ = std::fs::write(&self.monitors_path, words.join(" "));
    }

    fn remove(&mut self, handle: u16) {
        if let Some(index) = self.index {
            self.mgmt.ask(REMOVE_MONITOR, index, &handle.to_le_bytes());
            // Its own taking away is no news to this.
            self.mgmt.early.retain(|event| {
                !(u16::from_le_bytes([event[0], event[1]]) == EV_MONITOR_REMOVED
                    && event.get(6..8) == Some(&handle.to_le_bytes()[..]))
            });
        }
        self.monitors.retain(|mine| *mine != handle);
        if self.any == Some(handle) {
            self.any = None;
        }
    }

    fn add(&mut self, index: u16, patterns: &[[u8; 34]]) -> Result<u16, String> {
        let mut params = THRESHOLDS.to_vec();
        params.push(patterns.len() as u8);
        for pattern in patterns {
            params.extend_from_slice(pattern);
        }
        match self.mgmt.ask(ADD_PATTERNS_MONITOR_RSSI, index, &params) {
            (0, answer) if answer.len() >= 2 => {
                let handle = u16::from_le_bytes([answer[0], answer[1]]);
                self.monitors.push(handle);
                Ok(handle)
            }
            (status, _) => Err(format!(
                "Bluetooth would not listen for it ({}).",
                status_words(status)
            )),
        }
    }

    /// Everything from the start: which controller, whether it is on and can listen by itself, and
    /// the monitors put in place anew. For a start, a controller that came or went, one switched on,
    /// and a monitor of this one's taken away by somebody else. An iPhone that was near stays near
    /// through it, if it can still be heard: the shell would switch AirDrop off and on again.
    fn setup(&mut self) {
        self.why = None;
        let (status, answer) = self.mgmt.ask(READ_INDEX_LIST, HCI_DEV_NONE, &[]);
        let controllers = match answer.get(..2) {
            Some(count) if status == 0 && answer.len() >= 4 => {
                u16::from_le_bytes([count[0], count[1]])
            }
            _ => 0,
        };
        self.index = (controllers > 0).then(|| u16::from_le_bytes([answer[2], answer[3]]));
        let Some(index) = self.index else {
            self.deaf("This computer has no Bluetooth.");
            return;
        };
        let (status, answer) = self.mgmt.ask(READ_INFO, index, &[]);
        self.powered = status == 0
            && answer.len() >= 17
            && u32::from_le_bytes([answer[13], answer[14], answer[15], answer[16]]) & POWERED != 0;
        if !self.powered {
            self.deaf("Bluetooth is off.");
            return;
        }
        let (status, answer) = self.mgmt.ask(READ_MONITOR_FEATURES, index, &[]);
        if status != 0 || answer.len() < 13 {
            self.deaf(&format!(
                "Bluetooth would not say whether it can listen ({}).",
                status_words(status)
            ));
            return;
        }
        let supported = u32::from_le_bytes([answer[0], answer[1], answer[2], answer[3]]);
        if supported & OFFLOADED == 0 {
            // Without it the kernel would compare every advertisement nearby itself, awake.
            self.deaf("This computer's Bluetooth cannot listen for an iPhone by itself, and listening otherwise would keep the computer awake.");
            return;
        }
        let present = in_place(&answer);
        let mut stale = self.noted();
        stale.extend(self.monitors.iter().copied());
        for handle in stale {
            if present.contains(&handle) {
                self.remove(handle);
            }
        }
        self.monitors.clear();
        self.any = None;
        for phone in self.phones.clone() {
            if let Err(why) = self.add(index, &phone.patterns()) {
                self.why = Some(why);
            }
        }
        if self.learning.is_some() {
            match self.add(index, &[any_iphone()]) {
                Ok(handle) => self.any = Some(handle),
                Err(why) => self.why = Some(why),
            }
        }
        self.note();
        if let Some(why) = &self.why {
            log(&format!("cannot listen: {why}"));
        }
    }

    /// It cannot listen, for that reason. What was near stays near until unheard for STALE: a
    /// controller that is off for a moment is no closed share sheet.
    fn deaf(&mut self, why: &str) {
        self.why = Some(why.into());
    }

    fn resetting(&self) -> bool {
        self.reset.is_some_and(|at| at.elapsed() < RESET_GRACE)
    }

    /// Whether every monitor of this one's is in place: a monitor taken away under a number
    /// the kernel has since given to one of this one's new monitors is no loss.
    fn intact(&mut self) -> bool {
        let Some(index) = self.index else {
            return false;
        };
        let (status, answer) = self.mgmt.ask(READ_MONITOR_FEATURES, index, &[]);
        let present = if status == 0 {
            in_place(&answer)
        } else {
            Vec::new()
        };
        self.monitors.iter().all(|mine| present.contains(mine))
    }

    fn learn(&mut self) {
        self.learning = Some((Instant::now() + LEARN_FOR, unix_now() + LEARN_FOR.as_secs()));
        if self.any.is_none() && self.why.is_none() {
            if let Some(index) = self.index {
                match self.add(index, &[any_iphone()]) {
                    Ok(handle) => self.any = Some(handle),
                    Err(why) => self.why = Some(why),
                }
                self.note();
            }
        }
    }

    fn stop_learning(&mut self) {
        self.learning = None;
        if let Some(handle) = self.any {
            self.remove(handle);
            self.note();
        }
    }

    fn forget(&mut self) {
        self.phones.clear();
        if let Err(error) = write_phones(&self.phones_path, &self.phones) {
            log(&format!("{}: {error}", self.phones_path.display()));
        }
        self.setup();
    }

    /// What one event of the kernel's means here.
    fn heard(&mut self, event: &[u8]) {
        let kind = u16::from_le_bytes([event[0], event[1]]);
        let index = u16::from_le_bytes([event[2], event[3]]);
        let body = &event[6..];
        match kind {
            // Its controller gone: so are its monitors, and their numbers may be anybody's next.
            EV_INDEX_REMOVED if Some(index) == self.index => {
                self.reset = Some(Instant::now());
                self.monitors.clear();
                self.any = None;
                self.note();
                self.setup();
            }
            // Another controller: the one it listens with is not changed for it.
            EV_INDEX_ADDED if self.index.is_none() || self.why.is_some() => self.setup(),
            EV_NEW_SETTINGS if Some(index) == self.index && body.len() >= 4 => {
                let powered =
                    u32::from_le_bytes([body[0], body[1], body[2], body[3]]) & POWERED != 0;
                if powered != self.powered {
                    if !powered {
                        self.reset = Some(Instant::now());
                    }
                    self.setup();
                }
            }
            EV_MONITOR_REMOVED if body.len() >= 2 => {
                let handle = u16::from_le_bytes([body[0], body[1]]);
                if Some(index) == self.index && self.monitors.contains(&handle) && !self.intact() {
                    self.setup();
                }
            }
            EV_MONITOR_FOUND if body.len() >= 16 => {
                let size = usize::from(u16::from_le_bytes([body[14], body[15]]));
                if let Some(eir) = body.get(16..16 + size) {
                    self.advertised(
                        body[2..8].try_into().unwrap_or_default(),
                        body[9] as i8,
                        eir,
                    );
                }
            }
            // While something searches for devices (Settings' Bluetooth page, bluetoothctl), the
            // kernel tells what a monitor matches as any device found: the iPhone is still near.
            EV_DEVICE_FOUND if Some(index) == self.index && body.len() >= 14 => {
                let size = usize::from(u16::from_le_bytes([body[12], body[13]]));
                if let Some(eir) = body.get(14..14 + size) {
                    self.advertised(body[..6].try_into().unwrap_or_default(), body[7] as i8, eir);
                }
            }
            EV_MONITOR_LOST if body.len() >= 8 && !self.resetting() => {
                let address: [u8; 6] = body[2..8].try_into().unwrap_or_default();
                self.near.remove(&address);
            }
            _ => {}
        }
    }

    /// An advertisement heard from an address, as loud as that: an iPhone this knows is near; while
    /// learning, an iPhone close by is learned.
    fn advertised(&mut self, address: [u8; 6], loudness: i8, eir: &[u8]) {
        let Some(fields) = announcement(eir) else {
            return;
        };
        if self.phones.iter().any(|phone| phone.is(&fields)) {
            self.near.insert(address, Instant::now());
        } else if self.learning.is_some() && loudness > LEARN_LOUDER_THAN {
            if let Some(phone) = Phone::of(&fields) {
                self.phones.push(phone);
                match write_phones(&self.phones_path, &self.phones) {
                    Ok(()) => log("an iPhone was learned"),
                    Err(error) => log(&format!("{}: {error}", self.phones_path.display())),
                }
                self.learning = None;
                self.setup();
                self.near.insert(address, Instant::now());
            }
        }
    }

    /// Once a second: the minute of learning, and iPhones unheard for too long.
    fn tick(&mut self) {
        if self
            .learning
            .is_some_and(|(until, _)| Instant::now() >= until)
        {
            self.stop_learning();
        }
        self.near.retain(|_, heard| heard.elapsed() < STALE);
    }

    fn json(&self) -> String {
        let learning = self.learning.map_or(0, |(_, unix)| unix);
        let (state, why) = match &self.why {
            Some(why) => ("deaf", format!(r#""why":{},"#, quoted(why))),
            None => ("listening", String::new()),
        };
        format!(
            r#"{{"state":"{state}",{why}"phones":{},"near":{},"learning":{learning}}}"#,
            self.phones.len(),
            !self.near.is_empty()
        )
    }

    fn words(&self) -> String {
        if let Some(why) = &self.why {
            return format!("AirDrop's doorbell cannot listen: {why}");
        }
        if self.learning.is_some() {
            return "Learning: on the iPhone, Share, then AirDrop, beside this computer.".into();
        }
        match (self.phones.len(), self.near.is_empty()) {
            (0, _) => "AirDrop's doorbell knows no iPhone yet: nova airdrop bell learn.".into(),
            (_, false) => "Your iPhone is showing AirDrop.".into(),
            (1, true) => "AirDrop's doorbell is listening for your iPhone.".into(),
            (n, true) => format!("AirDrop's doorbell is listening for {n} iPhones."),
        }
    }
}

/// The monitors in place, from the answer to READ_MONITOR_FEATURES.
fn in_place(answer: &[u8]) -> Vec<u16> {
    let Some(count) = answer.get(11..13) else {
        return Vec::new();
    };
    let count = usize::from(u16::from_le_bytes([count[0], count[1]]));
    answer[13..]
        .as_chunks::<2>()
        .0
        .iter()
        .take(count)
        .map(|pair| u16::from_le_bytes(*pair))
        .collect()
}

fn quoted(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// ---------------------------------------------------------------- the socket

struct Client {
    stream: UnixStream,
    said: Vec<u8>,
    since: Instant,
    watching: bool,
}

/// Answers what a client said, if it has said a whole line: false when it is done with.
fn answer(bell: &mut Bell, client: &mut Client) -> bool {
    let mut buffer = [0u8; 256];
    loop {
        match client.stream.read(&mut buffer) {
            Ok(0) => return false,
            Ok(size) => client.said.extend_from_slice(&buffer[..size]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
            Err(_) => return false,
        }
        if client.said.len() > 256 {
            return false;
        }
    }
    let Some(end) = client.said.iter().position(|b| *b == b'\n') else {
        return client.watching || client.since.elapsed() < CLIENT_SAYS_WITHIN;
    };
    let line = String::from_utf8_lossy(&client.said[..end])
        .trim()
        .to_owned();
    client.said.drain(..=end);
    if client.watching {
        // A watcher has nothing more to say.
        return true;
    }
    let reply = match line.as_str() {
        "watch" => {
            client.watching = true;
            bell.json()
        }
        "status" => bell.words(),
        "learn" => {
            bell.learn();
            "ok".into()
        }
        "forget" => {
            bell.forget();
            "ok".into()
        }
        _ => "not understood: watch, status, learn or forget".into(),
    };
    writeln!(client.stream, "{reply}").is_ok() && client.watching
}

fn run() -> Result<(), String> {
    let mut words = std::env::args().skip(1);
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    let mut phones_path = match std::env::var_os("XDG_STATE_HOME") {
        Some(folder) if !folder.is_empty() => PathBuf::from(folder),
        _ => home.join(".local/state"),
    }
    .join("nova/airdrop/phones");
    let mut control = meet::bell();
    while let Some(word) = words.next() {
        let mut value = || words.next().ok_or(format!("{word} takes a value"));
        match word.as_str() {
            "--phones" => phones_path = value()?.into(),
            "--control" => control = value()?.into(),
            _ => {
                return Err(
                    "usage: nova-airdrop-bell [--phones <file>] [--control <socket>]".into(),
                )
            }
        }
    }

    // The socket first, while the capability is there; then nothing of it is left.
    let mgmt = Mgmt::open().map_err(|error| {
        format!("Bluetooth's management socket: {error} (it takes CAP_NET_ADMIN to open)")
    })?;
    give_up_capabilities().map_err(|error| format!("giving up capabilities: {error}"))?;
    // SAFETY: the handler only stores to an atomic.
    unsafe {
        signal(15, on_signal as *const () as usize);
        signal(2, on_signal as *const () as usize);
    }

    let folder = control.parent().ok_or("--control takes a path")?.to_owned();
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&folder)
        .map_err(|error| format!("{}: {error}", folder.display()))?;
    if UnixStream::connect(&control).is_ok() {
        return Err("AirDrop's doorbell is already running for this user".into());
    }
    let _ = std::fs::remove_file(&control);
    let listener =
        UnixListener::bind(&control).map_err(|error| format!("{}: {error}", control.display()))?;
    let _ = std::fs::set_permissions(&control, std::fs::Permissions::from_mode(0o600));
    listener
        .set_nonblocking(true)
        .map_err(|error| error.to_string())?;

    let mut bell = Bell {
        mgmt,
        phones: read_phones(&phones_path),
        phones_path,
        monitors_path: folder.join("airdrop-bell.monitors"),
        index: None,
        powered: false,
        why: None,
        monitors: Vec::new(),
        any: None,
        learning: None,
        near: HashMap::new(),
        reset: None,
    };
    bell.setup();
    log(&format!(
        "listening for {} iPhone(s); {}",
        bell.phones.len(),
        bell.why
            .as_deref()
            .unwrap_or("the controller compares by itself")
    ));

    let mut clients: Vec<Client> = Vec::new();
    let mut told = bell.json();
    let mut ticked = Instant::now();
    while !STOPPING.load(Ordering::SeqCst) {
        let mut fds = vec![bell.mgmt.fd.as_raw_fd(), listener.as_raw_fd()];
        fds.extend(clients.iter().map(|client| client.stream.as_raw_fd()));
        let pending = !bell.mgmt.early.is_empty();
        wait(
            &fds,
            if pending {
                Duration::ZERO
            } else {
                Duration::from_secs(1)
            },
        );
        while let Some(event) = bell.mgmt.read() {
            bell.heard(&event);
        }
        while let Ok((stream, _)) = listener.accept() {
            if clients.len() < MOST_CLIENTS && stream.set_nonblocking(true).is_ok() {
                clients.push(Client {
                    stream,
                    said: Vec::new(),
                    since: Instant::now(),
                    watching: false,
                });
            }
        }
        // A new watcher is told how things are in its answer; the others only of changes.
        let mut kept = Vec::with_capacity(clients.len());
        for mut client in clients.drain(..) {
            if answer(&mut bell, &mut client) {
                kept.push(client);
            }
        }
        clients = kept;
        if ticked.elapsed() >= Duration::from_secs(1) {
            ticked = Instant::now();
            bell.tick();
        }
        let now = bell.json();
        if now != told {
            clients
                .retain_mut(|client| !client.watching || writeln!(client.stream, "{now}").is_ok());
            told = now;
        }
    }
    for handle in bell.monitors.clone() {
        bell.remove(handle);
    }
    let _ = std::fs::remove_file(&bell.monitors_path);
    let _ = std::fs::remove_file(&control);
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(why) => {
            log(&format!("nova-airdrop-bell: {why}"));
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An announcement as an iPhone makes it, with made-up fields: flags, then Apple's data with
    /// message 0x05 and its 18 bytes.
    fn advertised(fields: [u16; 4]) -> Vec<u8> {
        let mut message = vec![0x40, 0x12, 0x34, 0x56, 0, 0, 0, 0, 0x03];
        for field in fields {
            message.extend_from_slice(&field.to_be_bytes());
        }
        message.push(0);
        let mut eir = vec![0x02, 0x01, 0x1a, 3 + 2 + 18, 0xff, 0x4c, 0x00, 0x05, 18];
        eir.extend_from_slice(&message);
        eir
    }

    #[test]
    fn an_announcement_gives_its_four_fields_and_anything_else_none() {
        let eir = advertised([0x1111, 0x2222, 0x3333, 0x4444]);
        assert_eq!(announcement(&eir), Some([0x1111, 0x2222, 0x3333, 0x4444]));
        // Where the controller's pattern looks: the first field, 13 bytes into the data.
        assert_eq!(&eir[5 + 13..5 + 15], &[0x11, 0x11]);
        // Another of Apple's messages first, then the announcement.
        let mut two = vec![
            0x02,
            0x01,
            0x1a,
            3 + 4 + 2 + 18,
            0xff,
            0x4c,
            0x00,
            0x10,
            2,
            0xaa,
            0xbb,
        ];
        two.extend_from_slice(&eir[7..]);
        assert_eq!(announcement(&two), Some([0x1111, 0x2222, 0x3333, 0x4444]));
        let mut cut = eir.clone();
        cut.truncate(eir.len() - 3);
        assert_eq!(announcement(&cut), None);
        let mut other_company = eir.clone();
        other_company[5] = 0x06;
        assert_eq!(announcement(&other_company), None);
        let mut other_message = eir;
        other_message[7] = 0x10;
        assert_eq!(announcement(&other_message), None);
        assert_eq!(announcement(&[]), None);
        assert_eq!(announcement(&[0x05, 0xff]), None);
    }

    #[test]
    fn a_phone_is_known_in_any_order_and_with_an_address_more() {
        let phone = Phone::of(&[0x4444, 0x1111, 0x3333, 0x2222]).unwrap();
        assert_eq!(phone.line(), "1111 2222 3333 4444");
        assert!(phone.is(&[0x3333, 0x1111, 0x4444, 0x2222]));
        assert!(phone.is(&[0x3333, 0x1111, 0x9999, 0x8888]));
        assert!(!phone.is(&[0x3333, 0x7777, 0x9999, 0x8888]));
        assert!(!phone.is(&[0, 0, 0, 0]));
        let few = Phone::of(&[0, 0x1111, 0, 0]).unwrap();
        assert!(few.is(&[0x1111, 0, 0, 0]));
        assert_eq!(Phone::of(&[0, 0, 0, 0]), None);
    }

    #[test]
    fn the_patterns_find_the_phone_whichever_field_it_puts_first() {
        let phone = Phone::of(&[0x1111, 0x2222, 0x3333, 0x4444]).unwrap();
        let patterns = phone.patterns();
        assert_eq!(patterns.len(), 4);
        assert_eq!(&patterns[0][..5], &[0xff, 13, 2, 0x11, 0x11]);
        assert!(patterns[0][5..].iter().all(|b| *b == 0));
        // Each order the phone may send them in matches one of them where the controller looks.
        for first in [0x1111u16, 0x2222, 0x3333, 0x4444] {
            let eir = advertised([first, 0, 0, 0]);
            let data = &eir[5..];
            assert!(patterns
                .iter()
                .any(|p| data[usize::from(p[1])..][..2] == p[3..5]));
        }
        let few = Phone::of(&[0x1111, 0x2222, 0, 0]).unwrap();
        assert_eq!(few.patterns().len(), 8);
        assert_eq!(&any_iphone()[..6], &[0xff, 0, 3, 0x4c, 0x00, 0x05]);
    }

    #[test]
    fn phones_are_kept_in_a_file_of_the_users_alone() {
        let folder = std::env::temp_dir().join(format!("nova-bell-{}", std::process::id()));
        let path = folder.join("state/phones");
        let phones = vec![
            Phone::of(&[0x1111, 0x2222, 0x3333, 0x4444]).unwrap(),
            Phone::of(&[0xaaaa, 0, 0, 0]).unwrap(),
        ];
        write_phones(&path, &phones).unwrap();
        assert_eq!(read_phones(&path), phones);
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        std::fs::write(
            &path,
            "1111 2222 3333 4444\nnot a phone\n4444 3333 2222 1111\n\n",
        )
        .unwrap();
        assert_eq!(read_phones(&path), phones[..1]);
        assert_eq!(read_phones(&folder.join("none")), vec![]);
        std::fs::remove_dir_all(&folder).unwrap();
    }

    /// A doorbell that knows one iPhone, on controller 0, with a socket that goes nowhere: what it
    /// makes of the kernel's events, without the kernel.
    fn bell() -> Bell {
        let (end, _) = std::os::unix::net::UnixDatagram::pair().unwrap();
        Bell {
            mgmt: Mgmt {
                fd: OwnedFd::from(end),
                early: VecDeque::new(),
            },
            phones_path: PathBuf::from("/nonexistent/phones"),
            monitors_path: PathBuf::from("/nonexistent/monitors"),
            phones: vec![Phone::of(&[0x1111, 0x2222, 0x3333, 0x4444]).unwrap()],
            index: Some(0),
            powered: true,
            why: None,
            monitors: vec![1],
            any: None,
            learning: None,
            near: HashMap::new(),
            reset: None,
        }
    }

    fn event(kind: u16, body: &[u8]) -> Vec<u8> {
        let mut out = kind.to_le_bytes().to_vec();
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&(body.len() as u16).to_le_bytes());
        out.extend_from_slice(body);
        out
    }

    /// Monitor found: handle, address and its kind, loudness, flags, the advertisement.
    fn found(address: u8, fields: [u16; 4]) -> Vec<u8> {
        let eir = advertised(fields);
        let mut body = vec![1, 0, address, 0, 0, 0, 0, 0, 1, (-50i8) as u8, 0, 0, 0, 0];
        body.extend_from_slice(&(eir.len() as u16).to_le_bytes());
        body.extend_from_slice(&eir);
        event(EV_MONITOR_FOUND, &body)
    }

    #[test]
    fn the_iphone_is_near_from_found_to_lost_and_while_something_searches() {
        let mut bell = bell();
        bell.heard(&found(7, [0x3333, 0x1111, 0x4444, 0x2222]));
        assert!(bell.json().contains(r#""near":true"#));
        bell.heard(&event(EV_MONITOR_LOST, &[1, 0, 7, 0, 0, 0, 0, 0, 1]));
        assert!(bell.json().contains(r#""near":false"#));
        // Somebody else's iPhone, not learning: nothing.
        bell.heard(&found(8, [0x5555, 0x6666, 0x7777, 0x8888]));
        assert!(bell.near.is_empty());
        assert_eq!(bell.phones.len(), 1);
        // A search on: the same advertisement as any device found.
        let eir = advertised([0x2222, 0x4444, 0x1111, 0x3333]);
        let mut body = vec![9, 0, 0, 0, 0, 0, 1, (-60i8) as u8, 0, 0, 0, 0];
        body.extend_from_slice(&(eir.len() as u16).to_le_bytes());
        body.extend_from_slice(&eir);
        bell.heard(&event(EV_DEVICE_FOUND, &body));
        assert_eq!(bell.near.keys().next(), Some(&[9, 0, 0, 0, 0, 0]));
        // Unheard for long enough, it is gone whatever the kernel said.
        bell.near.insert([9, 0, 0, 0, 0, 0], Instant::now() - STALE);
        bell.tick();
        assert!(bell.near.is_empty());
        assert_eq!(
            bell.json(),
            r#"{"state":"listening","phones":1,"near":false,"learning":0}"#
        );
        bell.why = Some("Bluetooth is off.".into());
        assert_eq!(
            bell.json(),
            r#"{"state":"deaf","why":"Bluetooth is off.","phones":1,"near":false,"learning":0}"#
        );
    }

    #[test]
    fn a_controller_that_resets_for_a_moment_is_no_closed_share_sheet() {
        let mut bell = bell();
        bell.heard(&found(7, [0x1111, 0x2222, 0x3333, 0x4444]));
        // Powered off (the kernel resetting it): it cannot listen, but what was near stays near.
        bell.heard(&event(EV_NEW_SETTINGS, &[0, 0, 0, 0]));
        assert!(bell.why.is_some());
        assert!(bell.json().contains(r#""near":true"#));
        // The kernel's "gone" for it, in the moment after, is not taken at its word.
        bell.heard(&event(EV_MONITOR_LOST, &[1, 0, 7, 0, 0, 0, 0, 0, 1]));
        assert!(bell.json().contains(r#""near":true"#));
        // Unheard for long enough, it is gone all the same.
        bell.near.insert([7, 0, 0, 0, 0, 0], Instant::now() - STALE);
        bell.tick();
        assert!(bell.json().contains(r#""near":false"#));
        // Long after the reset, "gone" is gone at once again.
        bell.reset = Some(Instant::now() - RESET_GRACE);
        bell.heard(&found(7, [0x1111, 0x2222, 0x3333, 0x4444]));
        bell.heard(&event(EV_MONITOR_LOST, &[1, 0, 7, 0, 0, 0, 0, 0, 1]));
        assert!(bell.near.is_empty());
    }

    #[test]
    fn thresholds_are_laid_out_as_the_kernel_reads_them() {
        // high threshold (s8), its timeout (le16), low threshold (s8), its timeout (le16), sampling (u8)
        assert_eq!(THRESHOLDS, [0xab, 0, 0, 0xa1, 3, 0, 10]);
        assert_eq!(std::mem::size_of::<SockaddrHci>(), 6);
    }
}
