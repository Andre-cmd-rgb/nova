//! AWDL on the air: what a monitor interface hands over and takes.
//!
//! Three kinds of frame matter. Action frames carry a node's announcement of
//! itself (its clock, who it follows, where it will be), as a fixed header and
//! a list of TLVs. Data frames carry IPv6, under an LLC header and four bytes
//! of AWDL's own. Everything else on the channel is somebody else's.
//!
//! The layouts were read off an iPhone's own frames, field by field; what a
//! field is called here is what it was seen to do.

pub type Mac = [u8; 6];

/// A time unit of 802.11, in microseconds. AWDL counts in these: an
/// availability window is 16 of them, a slot of the channel sequence four
/// windows, and the sequence sixteen slots.
pub const TU: u64 = 1024;
pub const SLOT_TU: u64 = 64;
pub const SLOTS: u64 = 16;

/// The BSSID every AWDL frame carries, on every Apple device.
pub const BSSID: Mac = [0x00, 0x25, 0x00, 0xff, 0x94, 0x73];
pub const BROADCAST: Mac = [0xff; 6];
const OUI: [u8; 3] = [0x00, 0x17, 0xf2];
/// What stands before the packet in a data frame: LLC/SNAP with Apple's OUI.
pub const LLC: [u8; 8] = [0xaa, 0xaa, 0x03, 0x00, 0x17, 0xf2, 0x08, 0x00];
pub const ETHERTYPE_IPV6: u16 = 0x86dd;

/// Radiotap before an announcement: no field but the rate, 6 Mbit/s, which
/// every 802.11 radio on 2.4 and 5 GHz understands, for every node in reach.
const RADIOTAP_TX: [u8; 9] = [0, 0, 9, 0, 0x04, 0, 0, 0, 12];
/// Radiotap before a data frame, which goes to one peer, close by: the rate,
/// 24 Mbit/s, a quarter of the time on the air at 6 for a full frame, so that
/// more of them fit in the peer's slot and fewer run past its end; and how
/// often the card sends it again when the peer does not acknowledge it (data
/// retries, field 17), as it would a frame of its own. A frame given with a
/// rate and no retries is sent once (net/mac80211/tx.c): one the peer missed
/// was then TCP's to send again, a second or more later.
const RADIOTAP_DATA: [u8; 10] = [0, 0, 10, 0, 0x04, 0, 0x02, 0, 48, 4];

pub const PSF: u8 = 0; // periodic synchronization frame, every 110 TU
pub const MIF: u8 = 3; // master indication frame, every second or so

// ------------------------------------------------------------ what was heard

/// How a frame arrived, as far as the card says.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Radio {
    pub signal: Option<i8>,
    pub rate: Rate,
    pub aggregated: bool,
}

#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub enum Rate {
    #[default]
    Unknown,
    /// In units of 500 kbit/s.
    Legacy(u8),
    Ht(u8),
    Vht {
        mcs: u8,
        streams: u8,
    },
}

/// (size, alignment) of radiotap's fields 0 to 21, in the order they come.
const RADIOTAP_FIELDS: [(usize, usize); 22] = [
    (8, 8),
    (1, 1),
    (1, 1),
    (4, 2),
    (2, 2),
    (1, 1),
    (1, 1),
    (2, 2),
    (2, 2),
    (2, 2),
    (1, 1),
    (1, 1),
    (1, 1),
    (1, 1),
    (2, 2),
    (2, 2),
    (1, 1),
    (1, 1),
    (8, 4),  // 18 extended channel
    (3, 1),  // 19 HT rate
    (8, 4),  // 20 aggregate
    (12, 2), // 21 VHT rate
];

/// Takes the radiotap header off a packet from a monitor interface, and the
/// checksum where the card left it on.
pub fn heard(packet: &[u8]) -> Option<(Radio, &[u8])> {
    if packet.len() < 8 || packet[0] != 0 {
        return None;
    }
    let length = u16::from_le_bytes([packet[2], packet[3]]) as usize;
    if length < 8 || packet.len() < length {
        return None;
    }
    let present = u32::from_le_bytes([packet[4], packet[5], packet[6], packet[7]]);
    // Further words of "present" bits, for fields this does not read.
    let (mut offset, mut word) = (8, present);
    while word & (1 << 31) != 0 && offset + 4 <= length {
        word = u32::from_le_bytes([
            packet[offset],
            packet[offset + 1],
            packet[offset + 2],
            packet[offset + 3],
        ]);
        offset += 4;
    }
    let (mut radio, mut flags) = (Radio::default(), 0u8);
    for (bit, &(size, align)) in RADIOTAP_FIELDS.iter().enumerate() {
        if present & (1 << bit) == 0 {
            continue;
        }
        offset = offset.div_ceil(align) * align;
        if offset + size > length {
            break;
        }
        let field = &packet[offset..offset + size];
        match bit {
            1 => flags = field[0],
            2 if radio.rate == Rate::Unknown => radio.rate = Rate::Legacy(field[0]),
            5 => radio.signal = Some(field[0] as i8),
            19 => radio.rate = Rate::Ht(field[2]),
            20 => radio.aggregated = true,
            21 => {
                radio.rate = Rate::Vht {
                    mcs: field[4] >> 4,
                    streams: field[4] & 15,
                }
            }
            _ => {}
        }
        offset += size;
    }
    let mut frame = &packet[length..];
    if flags & 0x10 != 0 && frame.len() > 4 {
        frame = &frame[..frame.len() - 4];
    }
    Some((radio, frame))
}

/// An 802.11 frame with the three addresses AWDL's frames have.
#[derive(Debug, Clone, Copy)]
pub struct Frame<'a> {
    pub kind: Kind,
    pub subtype: u8,
    pub retry: bool,
    pub to: Mac,
    pub from: Mac,
    pub bssid: Mac,
    /// The 12-bit sequence number.
    pub number: u16,
    pub bytes: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Management,
    Control,
    Data,
    Other,
}

pub fn frame(bytes: &[u8]) -> Option<Frame<'_>> {
    if bytes.len() < 24 {
        return None;
    }
    let mac = |at: usize| -> Mac { bytes[at..at + 6].try_into().unwrap() };
    Some(Frame {
        kind: match (bytes[0] >> 2) & 3 {
            0 => Kind::Management,
            1 => Kind::Control,
            2 => Kind::Data,
            _ => Kind::Other,
        },
        subtype: bytes[0] >> 4,
        retry: bytes[1] & 0x08 != 0,
        to: mac(4),
        from: mac(10),
        bssid: mac(16),
        number: u16::from_le_bytes([bytes[22], bytes[23]]) >> 4,
        bytes,
    })
}

impl<'a> Frame<'a> {
    /// The frame as an AWDL announcement, if it is one.
    pub fn announcement(&self) -> Option<Announcement<'a>> {
        let b = self.bytes;
        // Action (13) and action-no-ack (14); category 127 is "vendor specific".
        if self.kind != Kind::Management || !matches!(self.subtype, 13 | 14) || b.len() < 40 {
            return None;
        }
        if b[24] != 127 || b[25..28] != OUI || b[28] != 8 {
            return None;
        }
        Some(Announcement {
            sent_at: u32::from_le_bytes([b[32], b[33], b[34], b[35]]),
            meant_at: u32::from_le_bytes([b[36], b[37], b[38], b[39]]),
            tlvs: &b[40..],
        })
    }

    /// The packets a data frame carries to the IP layer, as Ethernet would
    /// have: none if it is not AWDL's, several where the sender packed several
    /// into one frame (an A-MSDU: destination, source, length and an LLC'd
    /// packet, each padded to four bytes).
    pub fn packets(&self) -> Vec<Packet<'a>> {
        let b = self.bytes;
        let mut found = Vec::new();
        // Subtypes with bit 2 set carry nothing; bit 3 says QoS, two bytes more of header.
        if self.kind != Kind::Data || self.subtype & 4 != 0 || self.bssid != BSSID {
            return found;
        }
        let qos = self.subtype & 8 != 0;
        let start = if qos { 26 } else { 24 };
        if b.len() < start {
            return found;
        }
        if qos && b[24] & 0x80 != 0 {
            let mut at = start;
            while at + 14 <= b.len() && found.len() < 16 {
                let size = u16::from_be_bytes([b[at + 12], b[at + 13]]) as usize;
                let Some(body) = b.get(at + 14..at + 14 + size) else {
                    break;
                };
                if let Some((ethertype, payload)) = unwrap(body) {
                    let mac = |at: usize| -> Mac { b[at..at + 6].try_into().unwrap() };
                    found.push(Packet {
                        to: mac(at),
                        from: mac(at + 6),
                        ethertype,
                        payload,
                    });
                }
                at += (14 + size + 3) & !3;
            }
        } else if let Some((ethertype, payload)) = unwrap(&b[start..]) {
            found.push(Packet {
                to: self.to,
                from: self.from,
                ethertype,
                payload,
            });
        }
        found
    }

    /// Which of a sender's streams a data frame belongs to: retransmissions
    /// are told apart per stream.
    pub fn stream(&self) -> u8 {
        if self.kind == Kind::Data && self.subtype & 8 != 0 && self.bytes.len() > 24 {
            self.bytes[24] & 15
        } else {
            16
        }
    }
}

/// LLC, AWDL's four bytes (`03 04`, a sequence number), two of nothing, the
/// ethertype, the packet.
fn unwrap(body: &[u8]) -> Option<(u16, &[u8])> {
    if body.len() < 16 || body[..8] != LLC {
        return None;
    }
    Some((u16::from_be_bytes([body[14], body[15]]), &body[16..]))
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Packet<'a> {
    pub to: Mac,
    pub from: Mac,
    pub ethertype: u16,
    pub payload: &'a [u8],
}

/// A node's announcement of itself: a PSF or a MIF.
#[derive(Debug, Clone, Copy)]
pub struct Announcement<'a> {
    /// The sender's clock, in microseconds, when the frame left its radio,
    /// and when it was meant to: the frame's counters are true of the second.
    pub sent_at: u32,
    pub meant_at: u32,
    tlvs: &'a [u8],
}

impl<'a> Announcement<'a> {
    pub fn tlvs(&self) -> Tlvs<'a> {
        Tlvs { rest: self.tlvs }
    }

    fn tlv(&self, kind: u8) -> Option<&'a [u8]> {
        self.tlvs()
            .find(|(k, _)| *k == kind)
            .map(|(_, value)| value)
    }

    /// Whom the sender follows, and how it and that master rank.
    pub fn election(&self) -> Option<Election> {
        let v = self.tlv(24).filter(|v| v.len() >= 40)?;
        let word = |at: usize| u32::from_le_bytes([v[at], v[at + 1], v[at + 2], v[at + 3]]);
        Some(Election {
            master: v[0..6].try_into().unwrap(),
            master_counter: word(12),
            master_metric: word(20),
            metric: word(24),
            counter: word(36),
        })
    }

    /// Where the sender is in its sixteen slots, by its own count: in TU from
    /// the start of slot 0, at the moment the frame was meant to leave.
    pub fn position(&self) -> Option<u64> {
        let v = self.tlv(4).filter(|v| v.len() >= 31)?;
        // The counter runs down to the end of the slot; the window number
        // counts windows of 16 TU, four to a slot.
        let down = u16::from_le_bytes([v[1], v[2]]) as u64;
        let window = u16::from_le_bytes([v[29], v[30]]) as u64;
        Some(((window / 4) % SLOTS) * SLOT_TU + (SLOT_TU - down.min(SLOT_TU)) % SLOT_TU)
    }

    /// The channel the sender says it is on in each of its sixteen slots; 0
    /// where it names none.
    pub fn channels(&self) -> Option<[u8; 16]> {
        let v = self.tlv(18).filter(|v| v.len() >= 6)?;
        let count = v[0] as usize + 1;
        // Encoding 3 is (channel, operating class), encoding 1 (flags,
        // channel): two bytes an entry both; 0 is one byte, the channel.
        let (width, at) = match v[1] {
            0 => (1, 0),
            1 => (2, 1),
            3 => (2, 0),
            _ => return None,
        };
        let mut channels = [0u8; 16];
        for (slot, channel) in channels.iter_mut().enumerate().take(count) {
            *channel = *v.get(6 + slot * width + at)?;
        }
        Some(channels)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Election {
    pub master: Mac,
    pub master_counter: u32,
    pub master_metric: u32,
    pub metric: u32,
    pub counter: u32,
}

/// The TLVs of an announcement: a type of one byte, a length of two (little
/// endian), the value.
pub struct Tlvs<'a> {
    rest: &'a [u8],
}

impl<'a> Iterator for Tlvs<'a> {
    type Item = (u8, &'a [u8]);
    fn next(&mut self) -> Option<Self::Item> {
        if self.rest.len() < 3 {
            return None;
        }
        let size = u16::from_le_bytes([self.rest[1], self.rest[2]]) as usize;
        let value = self.rest.get(3..3 + size)?;
        let kind = self.rest[0];
        self.rest = &self.rest[3 + size..];
        Some((kind, value))
    }
}

// -------------------------------------------------------------- what is sent

/// What this computer announces of itself.
#[derive(Debug, Clone)]
pub struct Speaker {
    pub address: Mac,
    /// How this node ranks in the choice of whose clock to follow: the higher
    /// counter wins, then the higher metric.
    pub counter: u32,
    pub metric: u32,
    /// Its name on the link, without ".local".
    pub host: String,
    /// The country whose radio rules it keeps, two letters.
    pub country: [u8; 2],
    /// The channel it is on in each of its sixteen slots, 0 where it names
    /// none. This computer names one channel sixteen times: its card stays
    /// where it is.
    pub channels: [u8; 16],
    /// What it says of its abilities and its presence; see `Manner`.
    pub manner: Manner,
}

/// The parts of the announcement that decide when a peer sends to this node,
/// kept apart because they are what is tuned: an iPhone sends in the slots its
/// own reading of these allows.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Manner {
    /// The data path state's flags.
    pub flags: u16,
    /// The channels it can meet on, a bit each: 6, 44, 149.
    pub channel_map: u16,
    /// How often it is in a window: 4 is what an iPhone says of itself.
    pub presence: u8,
    /// For how many more windows it stays after a frame to it alone.
    pub unicast_extension: u8,
}

impl Default for Manner {
    fn default() -> Self {
        // An iPhone's own, as heard.
        Manner {
            flags: 0x9f23,
            channel_map: 0x0007,
            presence: 4,
            unicast_extension: 3,
        }
    }
}

fn tlv(out: &mut Vec<u8>, kind: u8, value: &[u8]) {
    out.push(kind);
    out.extend_from_slice(&(value.len() as u16).to_le_bytes());
    out.extend_from_slice(value);
}

/// What an iPhone says of its radio and its version, said of this one too:
/// its service parameters (6), HT abilities (7), VHT abilities in an 802.11
/// element (17), version (21) and two it gives no name to (19, 33), as heard.
const AS_HEARD: [(u8, &[u8]); 6] = [
    (19, &[0x01, 0x00, 0x06, 0x10, 0x00]),
    (6, &[0x00, 0x00, 0x00, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x00]),
    (7, &[0x00, 0x00, 0x6f, 0x00, 0x1f, 0xff, 0xff, 0x00, 0x00]),
    (
        17,
        &[
            0xbf, 0x0c, 0x36, 0x00, 0x80, 0x03, 0xfa, 0xff, 0x00, 0x00, 0xfa, 0xff, 0x00, 0x00,
        ],
    ),
    (21, &[0xa2, 0x02]),
    (
        33,
        &[0x00, 0x00, 0x00, 0x00, 0x3c, 0x80, 0x01, 0x11, 0x86, 0x40],
    ),
];

fn as_heard(out: &mut Vec<u8>, kind: u8) {
    if let Some((_, value)) = AS_HEARD.iter().find(|(k, _)| *k == kind) {
        tlv(out, kind, value);
    }
}

impl Speaker {
    /// A PSF or a MIF, ready for the monitor interface. `now` is this node's
    /// clock in microseconds, `number` the frame's 802.11 sequence number.
    pub fn announce(&self, subtype: u8, now: u64, number: u16) -> Vec<u8> {
        let tu = now / TU;
        let down = (SLOT_TU - tu % SLOT_TU) as u16;
        let window = ((tu / 16) & 0xffff) as u16;
        let slot = ((tu / SLOT_TU) % SLOTS) as usize;

        // Synchronization: where this node's clock stands, and its channels
        // in the old encoding (a byte of flags and the channel, per slot).
        let mut sync = Vec::with_capacity(73);
        sync.push(self.channels[slot]); // the channel of the window it is in
        sync.extend_from_slice(&down.to_le_bytes());
        sync.push(if subtype == PSF {
            self.channels[slot]
        } else {
            0
        }); // the master's channel
        sync.push(0); // guard time
        for word in [16u16, 110, 0x1800, 16, 16, 0] {
            // window and announcement periods, flags, extension and common lengths, remaining
            sync.extend_from_slice(&word.to_le_bytes());
        }
        sync.extend_from_slice(&[3, 3, self.manner.unicast_extension, 3]); // extension counts
        sync.extend_from_slice(&self.address); // the master: this node
        sync.extend_from_slice(&[self.manner.presence, 0]);
        sync.extend_from_slice(&window.to_le_bytes());
        sync.extend_from_slice(&[0, 0]); // distance from an access point's beacon
        sync.extend_from_slice(&[15, 1, 0, 3, 0xff, 0xff]);
        for channel in self.channels {
            // A byte that says how wide and where the channel is, as an iPhone
            // writes it for 20 MHz at 2.4 GHz.
            sync.extend_from_slice(&[if channel == 0 { 0 } else { 0x2b }, channel]);
        }
        sync.extend_from_slice(&[0, 0]);

        // Election, old and new: this node follows itself.
        let mut election = vec![0u8; 5];
        election.extend_from_slice(&self.address);
        election.extend_from_slice(&self.metric.to_le_bytes());
        election.extend_from_slice(&self.metric.to_le_bytes());
        election.extend_from_slice(&[0, 0]);
        let mut election2 = Vec::with_capacity(40);
        election2.extend_from_slice(&self.address);
        election2.extend_from_slice(&self.address);
        for word in [
            self.counter,
            0,
            self.metric,
            self.metric,
            0,
            0,
            self.counter,
        ] {
            election2.extend_from_slice(&word.to_le_bytes());
        }

        // The channels again, as (channel, operating class): 81 is 2.4 GHz at
        // 20 MHz, 128 what an iPhone gives its 5 GHz channels.
        let mut sequence = vec![15, 3, 0, 3, 0xff, 0xff];
        for channel in self.channels {
            let class = match channel {
                0 => 0,
                1..=14 => 0x51,
                _ => 0x80,
            };
            sequence.extend_from_slice(&[channel, class]);
        }
        sequence.extend_from_slice(&[0, 0, 0]);

        // The data path's state: what this node can do, in which country, on
        // which channels, with no network behind it, and its address.
        let mut path = Vec::with_capacity(47);
        path.extend_from_slice(&self.manner.flags.to_le_bytes());
        path.extend_from_slice(&[self.country[0], self.country[1], 0]);
        path.extend_from_slice(&self.manner.channel_map.to_le_bytes());
        path.extend_from_slice(&[0; 8]); // the network's BSSID and channel: none
        path.extend_from_slice(&self.address);
        path.extend_from_slice(&[4, 0, 0, 0, 0, 0]); // options for frames to it alone: four bytes, none set
        path.extend_from_slice(&[0; 4]);
        path.extend_from_slice(&self.counter.to_le_bytes());
        path.extend_from_slice(&[0; 12]);

        let mut body = Vec::with_capacity(320);
        tlv(&mut body, 4, &sync);
        tlv(&mut body, 5, &election);
        tlv(&mut body, 18, &sequence);
        if subtype == PSF {
            as_heard(&mut body, 19);
            as_heard(&mut body, 6);
            tlv(&mut body, 24, &election2);
            tlv(&mut body, 12, &path);
            as_heard(&mut body, 7);
            as_heard(&mut body, 17);
            as_heard(&mut body, 21);
            as_heard(&mut body, 33);
        } else {
            tlv(&mut body, 24, &election2);
            tlv(&mut body, 12, &path);
            as_heard(&mut body, 7);
            as_heard(&mut body, 17);
            as_heard(&mut body, 33);
            // The name, as DNS writes one: a label, and a pointer for ".local".
            let mut name = vec![3, self.host.len() as u8];
            name.extend_from_slice(self.host.as_bytes());
            name.extend_from_slice(&[0xc0, 0x0c]);
            tlv(&mut body, 16, &name);
            as_heard(&mut body, 21);
            as_heard(&mut body, 6);
        }

        let mut out = Vec::with_capacity(9 + 40 + body.len());
        out.extend_from_slice(&RADIOTAP_TX);
        header(&mut out, [0xd0, 0x00], &BROADCAST, &self.address, number);
        out.push(127);
        out.extend_from_slice(&OUI);
        out.extend_from_slice(&[8, 0x10, subtype, 0]);
        let stamp = (now as u32).to_le_bytes();
        out.extend_from_slice(&stamp);
        out.extend_from_slice(&stamp);
        out.extend_from_slice(&body);
        out
    }
}

/// A frame that is sent, without its radiotap.
#[cfg(test)]
pub fn sent_frame(sent: &[u8]) -> &[u8] {
    &sent[usize::from(u16::from_le_bytes([sent[2], sent[3]]))..]
}

fn header(out: &mut Vec<u8>, control: [u8; 2], to: &Mac, from: &Mac, number: u16) {
    out.extend_from_slice(&control);
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(to);
    out.extend_from_slice(from);
    out.extend_from_slice(&BSSID);
    out.extend_from_slice(&((number & 0xfff) << 4).to_le_bytes());
}

/// An IPv6 packet as an AWDL data frame (QoS, as an iPhone sends its own),
/// ready for the monitor interface. `number` is the 802.11 sequence number,
/// `count` AWDL's own.
pub fn data(to: &Mac, from: &Mac, number: u16, count: u16, packet: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(RADIOTAP_DATA.len() + 26 + 16 + packet.len());
    out.extend_from_slice(&RADIOTAP_DATA);
    header(&mut out, [0x88, 0x00], to, from, number);
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(&LLC);
    out.extend_from_slice(&[0x03, 0x04]);
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(&ETHERTYPE_IPV6.to_be_bytes());
    out.extend_from_slice(packet);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const US: Mac = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55];
    const THEM: Mac = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee];

    fn speaker() -> Speaker {
        Speaker {
            address: US,
            counter: 4000,
            metric: 1000,
            host: "nova-abcdef".into(),
            country: *b"IT",
            channels: [6; 16],
            manner: Manner::default(),
        }
    }

    /// A frame as a monitor interface gives it: radiotap with the flags (the
    /// checksum is left on), the rate and the signal, then four bytes more.
    fn monitored(wifi: &[u8]) -> Vec<u8> {
        let mut packet = vec![0, 0, 11, 0, 0x26, 0, 0, 0, 0x10, 12, 0xe4];
        packet.extend_from_slice(wifi);
        packet.extend_from_slice(&[1, 2, 3, 4]);
        packet
    }

    #[test]
    fn an_announcement_reads_back_as_it_was_written() {
        // 300 slots and 20 TU in: slot 300 % 16 = 12, window 1201.
        let now = (300 * 64 + 20) * TU + 17;
        for subtype in [PSF, MIF] {
            let sent = speaker().announce(subtype, now, 77);
            let packet = monitored(sent_frame(&sent));
            let (radio, wifi) = heard(&packet).unwrap();
            assert_eq!(
                radio,
                Radio {
                    signal: Some(-28),
                    rate: Rate::Legacy(12),
                    aggregated: false
                }
            );
            assert_eq!(wifi, sent_frame(&sent));
            let frame = frame(wifi).unwrap();
            assert_eq!(
                (
                    frame.kind,
                    frame.subtype,
                    frame.to,
                    frame.from,
                    frame.bssid,
                    frame.number
                ),
                (Kind::Management, 13, BROADCAST, US, BSSID, 77)
            );
            let said = frame.announcement().unwrap();
            assert_eq!((frame.bytes[30], said.sent_at), (subtype, now as u32));
            assert_eq!(said.position(), Some(12 * 64 + 20));
            assert_eq!(said.channels(), Some([6; 16]));
            assert_eq!(
                said.election(),
                Some(Election {
                    master: US,
                    master_counter: 4000,
                    master_metric: 1000,
                    metric: 1000,
                    counter: 4000
                })
            );
        }
    }

    #[test]
    fn the_announcements_are_what_an_iphone_answered() {
        // The PSF and MIF of the prototype that an iPhone 15 Pro followed and
        // sent a photo to, for this address, clock and name: byte for byte.
        let now = 123_456_789;
        let hex = |bytes: &[u8]| bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert_eq!(
            hex(&speaker().announce(PSF, now, 1)),
            include_str!("../tests/psf.hex").trim()
        );
        assert_eq!(
            hex(&speaker().announce(MIF, now, 2)),
            include_str!("../tests/mif.hex").trim()
        );
    }

    #[test]
    fn a_plan_of_several_channels_reads_back() {
        let plan = [44, 44, 149, 44, 44, 44, 0, 0, 6, 6, 44, 6, 6, 6, 0, 0];
        let phone = Speaker {
            address: THEM,
            channels: plan,
            ..speaker()
        };
        let sent = phone.announce(PSF, (8 * 64 + 5) * TU, 1);
        let said = frame(sent_frame(&sent)).unwrap().announcement().unwrap();
        assert_eq!(said.channels(), Some(plan));
        assert_eq!(said.position(), Some(8 * 64 + 5));
    }

    #[test]
    fn a_data_frame_gives_its_packet_back() {
        let packet = [0x60u8; 60];
        let sent = data(&THEM, &US, 5, 9, &packet);
        let frame = frame(sent_frame(&sent)).unwrap();
        assert_eq!(
            (frame.kind, frame.subtype, frame.stream()),
            (Kind::Data, 8, 0)
        );
        assert_eq!(
            frame.packets(),
            vec![Packet {
                to: THEM,
                from: US,
                ethertype: 0x86dd,
                payload: &packet
            }]
        );
        assert!(frame.announcement().is_none());
    }

    #[test]
    fn several_packets_in_one_frame_are_all_found() {
        let (first, second) = ([0x61u8; 61], [0x62u8; 1201]);
        let sub = |packet: &[u8], pad: bool| {
            let mut body = Vec::new();
            body.extend_from_slice(&LLC);
            body.extend_from_slice(&[3, 4, 1, 0, 0, 0, 0x86, 0xdd]);
            body.extend_from_slice(packet);
            let mut out = Vec::new();
            out.extend_from_slice(&US);
            out.extend_from_slice(&THEM);
            out.extend_from_slice(&(body.len() as u16).to_be_bytes());
            out.extend_from_slice(&body);
            while pad && out.len() % 4 != 0 {
                out.push(0);
            }
            out
        };
        let mut wifi = Vec::new();
        header(&mut wifi, [0x88, 0x00], &US, &THEM, 3);
        wifi.extend_from_slice(&[0x80, 0]);
        wifi.extend_from_slice(&sub(&first, true));
        wifi.extend_from_slice(&sub(&second, false));
        let whole = frame(&wifi).unwrap().packets();
        assert_eq!(whole.len(), 2);
        assert_eq!(
            (whole[0].to, whole[0].from, whole[0].payload),
            (US, THEM, &first[..])
        );
        assert_eq!(whole[1].payload, &second[..]);
        // Cut short in the second: the first is still whole.
        assert_eq!(frame(&wifi[..wifi.len() - 500]).unwrap().packets().len(), 1);
    }

    #[test]
    fn what_is_not_awdl_is_left_alone() {
        let mut wifi = Vec::new();
        header(&mut wifi, [0x88, 0x00], &US, &THEM, 3);
        wifi.extend_from_slice(&[0, 0, 0xaa, 0xaa, 0x03, 0, 0, 0, 0x08, 0x00]);
        wifi.extend_from_slice(&[0x45; 40]);
        assert!(frame(&wifi).unwrap().packets().is_empty());
        // An empty data frame (subtype 12), a frame of another network, a short one.
        let mut null = Vec::new();
        header(&mut null, [0xc8, 0x00], &US, &THEM, 3);
        null.extend_from_slice(&[0, 0]);
        assert!(frame(&null).unwrap().packets().is_empty());
        let mut other = sent_frame(&data(&US, &THEM, 1, 1, &[0x60; 48])).to_vec();
        other[16] ^= 1;
        assert!(frame(&other).unwrap().packets().is_empty());
        assert!(frame(&wifi[..20]).is_none());
        assert!(heard(&[0, 0, 200, 0, 0, 0, 0, 0, 1, 2]).is_none());
    }

    #[test]
    fn tlvs_cut_short_end_the_list() {
        let said = Announcement {
            sent_at: 0,
            meant_at: 0,
            tlvs: &[4, 2, 0, 9, 9, 5, 9, 0, 1],
        };
        assert_eq!(said.tlvs().collect::<Vec<_>>(), vec![(4, &[9u8, 9][..])]);
        assert_eq!(
            (said.position(), said.channels(), said.election()),
            (None, None, None)
        );
    }
}
