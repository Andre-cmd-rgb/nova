//! The IPv6 packets the node writes and reads itself.
//!
//! The kernel does IP for AirDrop: TCP, and the addresses on awdl0. A few
//! packets never reach it or never come from it. AWDL has no neighbour
//! discovery, so the kernel's questions about who has an address are answered
//! here, from the address itself. The service is announced over mDNS from
//! here, timed to when a phone listens. And a ping finds out when it does.

use crate::wire::Mac;

pub type Ip = [u8; 16];

pub const ICMPV6: u8 = 58;
pub const UDP: u8 = 17;
pub const TCP: u8 = 6;
pub const ECHO_REQUEST: u8 = 128;
pub const ECHO_REPLY: u8 = 129;
pub const ROUTER_SOLICITATION: u8 = 133;
pub const NEIGHBOUR_SOLICITATION: u8 = 135;
pub const NEIGHBOUR_ADVERTISEMENT: u8 = 136;
pub const LISTENER_REPORT: u8 = 143;
pub const MDNS_PORT: u16 = 5353;
/// ff02::fb, where mDNS is spoken, and the Ethernet address that goes with it.
pub const MDNS_GROUP: Ip = [0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xfb];
pub const MDNS_MAC: Mac = [0x33, 0x33, 0, 0, 0, 0xfb];

/// The link-local address that belongs to a hardware address: fe80::, and the
/// address with ff:fe in its middle and one bit turned.
pub fn link_local(mac: &Mac) -> Ip {
    [
        0xfe,
        0x80,
        0,
        0,
        0,
        0,
        0,
        0,
        mac[0] ^ 2,
        mac[1],
        mac[2],
        0xff,
        0xfe,
        mac[3],
        mac[4],
        mac[5],
    ]
}

/// The hardware address a link-local address was made from, if it was made
/// that way: on AWDL every address is.
pub fn mac_of(ip: &Ip) -> Option<Mac> {
    if ip[..8] != [0xfe, 0x80, 0, 0, 0, 0, 0, 0] || ip[11] != 0xff || ip[12] != 0xfe {
        return None;
    }
    Some([ip[8] ^ 2, ip[9], ip[10], ip[13], ip[14], ip[15]])
}

/// The Internet checksum over some pieces, as if they were one.
fn checksum(pieces: &[&[u8]]) -> u16 {
    let mut sum = 0u32;
    let mut odd: Option<u8> = None;
    for piece in pieces {
        for &byte in *piece {
            match odd.take() {
                Some(high) => sum += u32::from(u16::from_be_bytes([high, byte])),
                None => odd = Some(byte),
            }
        }
    }
    if let Some(high) = odd {
        sum += u32::from(high) << 8;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

fn pseudo_header(source: &Ip, target: &Ip, length: usize, next: u8) -> [u8; 40] {
    let mut pseudo = [0u8; 40];
    pseudo[..16].copy_from_slice(source);
    pseudo[16..32].copy_from_slice(target);
    pseudo[32..36].copy_from_slice(&(length as u32).to_be_bytes());
    pseudo[39] = next;
    pseudo
}

fn ipv6(source: &Ip, target: &Ip, next: u8, payload: &[u8]) -> Vec<u8> {
    let mut packet = Vec::with_capacity(40 + payload.len());
    packet.extend_from_slice(&[0x60, 0, 0, 0]);
    packet.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    packet.extend_from_slice(&[next, 255]);
    packet.extend_from_slice(source);
    packet.extend_from_slice(target);
    packet.extend_from_slice(payload);
    packet
}

pub fn icmp6(source: &Ip, target: &Ip, kind: u8, body: &[u8]) -> Vec<u8> {
    let mut message = vec![kind, 0, 0, 0];
    message.extend_from_slice(body);
    let sum = checksum(&[
        &pseudo_header(source, target, message.len(), ICMPV6),
        &message,
    ]);
    message[2..4].copy_from_slice(&sum.to_be_bytes());
    ipv6(source, target, ICMPV6, &message)
}

pub fn udp6(source: &Ip, target: &Ip, port: u16, payload: &[u8]) -> Vec<u8> {
    let length = 8 + payload.len();
    let mut datagram = Vec::with_capacity(length);
    datagram.extend_from_slice(&port.to_be_bytes());
    datagram.extend_from_slice(&port.to_be_bytes());
    datagram.extend_from_slice(&(length as u16).to_be_bytes());
    datagram.extend_from_slice(&[0, 0]);
    datagram.extend_from_slice(payload);
    let sum = match checksum(&[&pseudo_header(source, target, length, UDP), &datagram]) {
        0 => 0xffff, // nought would say "no checksum", which IPv6 does not allow
        sum => sum,
    };
    datagram[6..8].copy_from_slice(&sum.to_be_bytes());
    ipv6(source, target, UDP, &datagram)
}

/// A ping: the identifier and the number come back in the answer.
pub fn echo_request(source: &Ip, target: &Ip, identifier: u16, number: u16) -> Vec<u8> {
    let mut body = Vec::with_capacity(8);
    body.extend_from_slice(&identifier.to_be_bytes());
    body.extend_from_slice(&number.to_be_bytes());
    body.extend_from_slice(b"nova");
    icmp6(source, target, ECHO_REQUEST, &body)
}

/// An IPv6 packet, as far as this needs to look into one. Packets with
/// extension headers show the first of them as their protocol: the only ones
/// seen here are the kernel's listener reports, which are not passed on.
#[derive(Debug, Clone, Copy)]
pub struct View<'a> {
    pub source: Ip,
    pub target: Ip,
    pub protocol: u8,
    pub body: &'a [u8],
}

pub fn view(packet: &[u8]) -> Option<View<'_>> {
    if packet.len() < 40 || packet[0] >> 4 != 6 {
        return None;
    }
    Some(View {
        source: packet[8..24].try_into().unwrap(),
        target: packet[24..40].try_into().unwrap(),
        protocol: packet[6],
        body: &packet[40..],
    })
}

impl View<'_> {
    /// An ICMPv6 message's type.
    pub fn icmp(&self) -> Option<u8> {
        (self.protocol == ICMPV6)
            .then(|| self.body.first().copied())
            .flatten()
    }

    /// (identifier, number) of an answer to a ping.
    pub fn echo_reply(&self) -> Option<(u16, u16)> {
        let b = self.body;
        (self.icmp() == Some(ECHO_REPLY) && b.len() >= 8).then(|| {
            (
                u16::from_be_bytes([b[4], b[5]]),
                u16::from_be_bytes([b[6], b[7]]),
            )
        })
    }

    /// The address a neighbour solicitation asks about.
    pub fn solicited(&self) -> Option<Ip> {
        (self.icmp() == Some(NEIGHBOUR_SOLICITATION) && self.body.len() >= 24)
            .then(|| self.body[8..24].try_into().unwrap())
    }

    /// An mDNS message: what a UDP datagram to or from port 5353 carries.
    pub fn mdns(&self) -> Option<&[u8]> {
        let b = self.body;
        if self.protocol != UDP || b.len() < 8 {
            return None;
        }
        let port = |at: usize| u16::from_be_bytes([b[at], b[at + 1]]);
        (port(0) == MDNS_PORT || port(2) == MDNS_PORT).then(|| &b[8..])
    }

    /// A TCP segment's flags and how much it carries.
    pub fn tcp(&self) -> Option<Segment> {
        let b = self.body;
        if self.protocol != TCP || b.len() < 20 {
            return None;
        }
        let header = usize::from(b[12] >> 4) * 4;
        Some(Segment {
            flags: b[13],
            carried: b.len().saturating_sub(header),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Segment {
    pub flags: u8,
    pub carried: usize,
}

impl Segment {
    /// Whether losing it stalls the connection until a timer: it opens or
    /// closes it, or carries something. A bare acknowledgement is replaced by
    /// the next one.
    pub fn matters(&self) -> bool {
        self.carried > 0 || self.flags & 0x07 != 0
    }
}

/// The answer to "who has this address?", for the kernel: the address says
/// who, on AWDL. `asked` is the solicitation; None if it is not one that wants
/// an answer (the kernel checking that its own address is free asks from ::).
pub fn neighbour_advertisement(asked: &View) -> Option<(Mac, Vec<u8>)> {
    let target = asked.solicited()?;
    let owner = mac_of(&target)?;
    if asked.source == [0u8; 16] {
        return None;
    }
    // Solicited, and to be believed over what was known; then the address,
    // then option 2: the hardware address it is at.
    let mut body = vec![0x60, 0, 0, 0];
    body.extend_from_slice(&target);
    body.extend_from_slice(&[2, 1]);
    body.extend_from_slice(&owner);
    Some((
        owner,
        icmp6(&target, &asked.source, NEIGHBOUR_ADVERTISEMENT, &body),
    ))
}

// ---------------------------------------------------------------------- mDNS

const AIRDROP: &str = "_airdrop._tcp.local";

fn name(out: &mut Vec<u8>, dotted: &str) {
    for label in dotted.split('.') {
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
}

fn record(out: &mut Vec<u8>, owner: &str, kind: u16, class: u16, data: &[u8]) {
    name(out, owner);
    out.extend_from_slice(&kind.to_be_bytes());
    out.extend_from_slice(&class.to_be_bytes());
    out.extend_from_slice(&120u32.to_be_bytes());
    out.extend_from_slice(&(data.len() as u16).to_be_bytes());
    out.extend_from_slice(data);
}

/// The mDNS answer that says an AirDrop receiver is here: the service's
/// instance, the host and port it is at, its flags, and the host's address.
/// `host` is without ".local".
pub fn service(instance: &str, host: &str, port: u16, address: &Ip, flags: u32) -> Vec<u8> {
    let full = format!("{instance}.{AIRDROP}");
    let host = format!("{host}.local");
    // An answer, with authority; four records, none of the other kinds.
    let mut message = vec![0, 0, 0x84, 0, 0, 0, 0, 4, 0, 0, 0, 0];
    let mut pointer = Vec::new();
    name(&mut pointer, &full);
    record(&mut message, AIRDROP, 12, 1, &pointer);
    // 0x8001: of the Internet class, and replacing what was cached.
    let mut target = vec![0, 0, 0, 0];
    target.extend_from_slice(&port.to_be_bytes());
    name(&mut target, &host);
    record(&mut message, &full, 33, 0x8001, &target);
    let text = format!("flags={flags}");
    let mut texts = vec![text.len() as u8];
    texts.extend_from_slice(text.as_bytes());
    record(&mut message, &full, 16, 0x8001, &texts);
    record(&mut message, &host, 28, 0x8001, address);
    message
}

/// Whether an mDNS message is a question about AirDrop receivers.
pub fn asks_for_airdrop(message: &[u8]) -> bool {
    message.len() >= 12
        && message[2] & 0x80 == 0
        && message[12..].windows(9).any(|at| at == b"\x08_airdrop")
}

#[cfg(test)]
mod tests {
    use super::*;

    const US: Mac = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55];
    const THEM: Mac = [0xb2, 0x5f, 0x5d, 0x01, 0x02, 0x03];

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn an_address_and_its_hardware_address_go_both_ways() {
        let ip = link_local(&US);
        assert_eq!(hex(&ip), "fe80000000000000001122fffe334455");
        assert_eq!(mac_of(&ip), Some(US));
        assert_eq!(mac_of(&MDNS_GROUP), None);
        let mut other = ip;
        other[11] = 0;
        assert_eq!(mac_of(&other), None);
    }

    #[test]
    fn a_ping_is_what_the_prototype_sent() {
        // From the Python that an iPhone answered: same addresses, identifier and number.
        let ping = echo_request(&link_local(&US), &link_local(&THEM), 0x4e52, 0x1234);
        assert_eq!(
            hex(&ping),
            "60000000000c3aff\
             fe80000000000000001122fffe334455\
             fe80000000000000b05f5dfffe010203\
             8000c9624e5212346e6f7661"
        );
        let seen = view(&ping).unwrap();
        assert_eq!(
            (seen.icmp(), seen.echo_reply(), seen.tcp()),
            (Some(ECHO_REQUEST), None, None)
        );
    }

    #[test]
    fn the_service_is_announced_as_the_prototype_did() {
        let message = service("0123456789ab", "nova-012345", 8771, &link_local(&US), 137);
        assert_eq!(
            hex(&message),
            concat!(
                "000084000000000400000000",
                "085f61697264726f70045f746370056c6f63616c00000c00010000007800220c303132333435363738396162085f61697264726f70045f746370056c6f63616c00",
                "0c303132333435363738396162085f61697264726f70045f746370056c6f63616c00002180010000007800190000000022430b6e6f76612d303132333435056c6f63616c00",
                "0c303132333435363738396162085f61697264726f70045f746370056c6f63616c000010800100000078000a09666c6167733d313337",
                "0b6e6f76612d303132333435056c6f63616c00001c8001000000780010fe80000000000000001122fffe334455",
            )
        );
        let datagram = udp6(&link_local(&US), &MDNS_GROUP, MDNS_PORT, &message);
        let seen = view(&datagram).unwrap();
        assert_eq!(seen.mdns(), Some(&message[..]));
        assert!(!asks_for_airdrop(&message), "an answer is not a question");
    }

    #[test]
    fn a_question_about_airdrop_is_known() {
        let mut question = vec![0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
        name(&mut question, AIRDROP);
        question.extend_from_slice(&[0, 12, 0, 1]);
        assert!(asks_for_airdrop(&question));
        let mut other = vec![0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
        name(&mut other, "_ipp._tcp.local");
        other.extend_from_slice(&[0, 12, 0, 1]);
        assert!(!asks_for_airdrop(&other));
        assert!(!asks_for_airdrop(&[0; 5]));
    }

    #[test]
    fn the_kernel_is_told_who_has_an_address() {
        let (ours, theirs) = (link_local(&US), link_local(&THEM));
        let mut body = vec![0, 0, 0, 0];
        body.extend_from_slice(&theirs);
        body.extend_from_slice(&[1, 1]);
        body.extend_from_slice(&US);
        let asked = icmp6(&ours, &theirs, NEIGHBOUR_SOLICITATION, &body);
        let (owner, answer) = neighbour_advertisement(&view(&asked).unwrap()).unwrap();
        assert_eq!(owner, THEM);
        let seen = view(&answer).unwrap();
        assert_eq!(
            (seen.source, seen.target, seen.icmp()),
            (theirs, ours, Some(NEIGHBOUR_ADVERTISEMENT))
        );
        assert_eq!(&seen.body[4..8], &[0x60, 0, 0, 0]);
        assert_eq!(&seen.body[8..24], &theirs);
        assert_eq!(&seen.body[24..], &[2, 1, 0xb2, 0x5f, 0x5d, 1, 2, 3]);
        // The checksum holds: summed with itself in place, a packet comes to nought.
        assert_eq!(
            checksum(&[
                &pseudo_header(&seen.source, &seen.target, seen.body.len(), ICMPV6),
                seen.body
            ]),
            0
        );
        // Asked from no address (is mine free?), or about an address not made from a hardware one: no answer.
        let probing = icmp6(&[0; 16], &theirs, NEIGHBOUR_SOLICITATION, &body);
        assert!(neighbour_advertisement(&view(&probing).unwrap()).is_none());
        let mut global = body.clone();
        global[4] = 0x20;
        let odd = icmp6(&ours, &theirs, NEIGHBOUR_SOLICITATION, &global);
        assert!(neighbour_advertisement(&view(&odd).unwrap()).is_none());
    }

    #[test]
    fn a_tcp_segment_says_whether_it_matters() {
        let mut segment = vec![0u8; 20];
        segment[12] = 0x50;
        segment[13] = 0x10;
        let bare = ipv6(&link_local(&US), &link_local(&THEM), TCP, &segment);
        assert_eq!(
            view(&bare).unwrap().tcp(),
            Some(Segment {
                flags: 0x10,
                carried: 0
            })
        );
        assert!(!view(&bare).unwrap().tcp().unwrap().matters());
        segment[13] = 0x12;
        assert!(
            view(&ipv6(&link_local(&US), &link_local(&THEM), TCP, &segment))
                .unwrap()
                .tcp()
                .unwrap()
                .matters()
        );
        segment[13] = 0x10;
        segment.extend_from_slice(b"data");
        assert!(
            view(&ipv6(&link_local(&US), &link_local(&THEM), TCP, &segment))
                .unwrap()
                .tcp()
                .unwrap()
                .matters()
        );
        assert!(view(&[0x60; 30]).is_none());
    }
}
