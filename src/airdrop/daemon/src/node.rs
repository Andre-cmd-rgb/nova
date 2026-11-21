//! This computer as an AWDL node: what it says on the air, whom it hears,
//! and when it sends to whom.
//!
//! AWDL is a schedule. Every node counts the same windows of 16 TU, four to
//! a slot and sixteen slots to a period of about a second, and says which
//! channel it will be on in each slot. Two nodes can talk in the slots where
//! they are on the same channel. An Apple device hops: its own network's
//! channel, and the three AWDL meets on (6, 44, 149). This card cannot hop
//! and be acknowledged (see src/airdrop/README.md), so it stays on one channel and
//! says so, sixteen times, and the phone comes by.
//!
//! How often it comes by is the phone's decision, and is the speed of a
//! transfer: measured on an iPhone 15 Pro, it sends at 2 MB/s while it is
//! here and not at all while it is not. Seen so far are a plan with this
//! channel in one slot of sixteen (a photo at 114 kB/s) and one with it in
//! five (462 kB/s through a slower prototype of this), which it took up by
//! itself some seconds after it found this node.
//!
//! So what this file is careful about is the other direction. A frame sent
//! while the phone is elsewhere is lost, and a lost acknowledgement or answer
//! costs the phone a window. Each peer's plan and clock are read from its own
//! announcements, a packet for it waits for a slot it is here in, and a
//! packet that matters goes again the next time it is heard, in case the
//! plan was wrong.
//!
//! Nothing here reads a socket or a clock: frames and the time come in,
//! frames go out, so that all of it can be tried against a made-up phone.

use std::collections::{HashMap, VecDeque};

use crate::packet::{self, Ip};
use crate::wire::{self, Kind, Mac, Manner, Speaker, MIF, PSF, SLOTS, SLOT_TU, TU};

const SLOT: u64 = SLOT_TU * TU;
const PERIOD: u64 = SLOTS * SLOT;
/// Announcements: every 110 TU, and the longer one with this node's name every second.
const PSF_EVERY: u64 = 110 * TU;
const MIF_EVERY: u64 = 1_000_000;
/// A peer heard this recently is on this channel now.
const HERE_FOR: u64 = 4_000;
/// After a peer's slot begins its radio is still arriving.
const GUARD: u64 = 3 * TU;
/// What a peer said of its clock is trusted this long; it says it again nine times a second while here.
const POSITION_HOLDS: u64 = 3_000_000;
/// A packet waits for its peer's slot at most a period and a bit; then it is sent on the chance.
const HOLD: u64 = PERIOD + 200_000;
/// A peer silent this long has come back, as far as repeating goes.
const BACK_AFTER: u64 = 20_000;
/// A peer that is being talked with is pinged: an Apple device learns from it where this node's
/// address lives, and its answer shows it still is there.
const PING_EVERY: u64 = 1_000_000;
const ENGAGED_FOR: u64 = 15_000_000;
/// The service is said aloud at most this often when nobody asked, and answered at most that often.
const SERVICE_EVERY: u64 = 1_000_000;
const ANSWER_EVERY: u64 = 200_000;
/// While this computer sends, it asks who receives AirDrop this often, aloud and of each peer in
/// its slot; and aloud again, at most that often, when a peer comes back.
const BROWSE_EVERY: u64 = 1_000_000;
/// A peer heard this recently is asked in its slot.
const ASKED_WHILE: u64 = 3_000_000;
const FORGET_AFTER: u64 = 60_000_000;
const MOST_PEERS: usize = 64;
/// A peer not heard for this long gives up its place when the table is full, whatever it was doing:
/// a phone that is there is heard nine times a second.
const SILENT_FOR: u64 = 2_000_000;
const MOST_WAITING: usize = 2048;
const ECHO: u16 = 0x4e6f;

/// What this node is, for as long as it runs.
#[derive(Debug, Clone)]
pub struct Settings {
    pub address: Mac,
    /// The name it has on the link, without ".local".
    pub host: String,
    /// The AirDrop service's instance: twelve hex digits, made up for each run.
    pub instance: String,
    pub port: u16,
    pub country: [u8; 2],
    pub channel: u8,
    pub manner: Manner,
}

/// Something worth a line in the log.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// A peer was heard for the first time.
    Found(Mac),
    /// A peer said which channels it will be on; `here` is in how many slots of sixteen it is on this one.
    Plan {
        peer: Mac,
        channels: [u8; 16],
        here: usize,
    },
    Lost(Mac),
    /// A peer's mDNS answer named an AirDrop receiver: while this computer sends.
    Receiver {
        peer: Mac,
        receiver: packet::Receiver,
    },
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Counts {
    pub announcements: u64,
    pub to_kernel: u64,
    pub to_air: u64,
    pub held: u64,
    pub sent_on_the_chance: u64,
    pub repeated: u64,
    pub duplicates: u64,
    pub pings: u64,
    pub pings_answered: u64,
    pub service_said: u64,
    pub browsed: u64,
    pub dropped: u64,
    /// The rates of the data frames peers sent this node, and how many came
    /// aggregated: what says how fast a peer can send.
    pub rates: Vec<(wire::Rate, u64)>,
    pub aggregated: u64,
}

impl Counts {
    fn heard_at(&mut self, radio: &wire::Radio) {
        match self.rates.iter_mut().find(|(rate, _)| *rate == radio.rate) {
            Some((_, count)) => *count += 1,
            None => self.rates.push((radio.rate, 1)),
        }
        self.aggregated += u64::from(radio.aggregated);
    }

    /// "; heard at HT MCS 7 (310), 24 Mbit/s (12), 290 aggregated", the most
    /// used rate first; "" when no data frame came.
    pub fn rates_heard(&self) -> String {
        if self.rates.is_empty() {
            return String::new();
        }
        let mut rates = self.rates.clone();
        rates.sort_by_key(|&(_, count)| std::cmp::Reverse(count));
        let list: Vec<String> = rates
            .iter()
            .map(|(rate, count)| format!("{rate} ({count})"))
            .collect();
        format!(
            "; heard at {}, {} aggregated",
            list.join(", "),
            self.aggregated
        )
    }
}

#[derive(Debug, PartialEq)]
enum Presence {
    Here,
    /// Not here; expected in this many microseconds.
    Away(u64),
    /// Its plan is not known, or does not have this channel.
    Unknown,
}

struct Peer {
    last_heard: u64,
    /// (this node's clock, microseconds into the peer's period then).
    position: Option<(u64, u64)>,
    channels: Option<[u8; 16]>,
    /// The last sequence number of each of its streams, to know a repeat.
    numbers: [Option<u16>; 17],
    /// Packets for it, with when they came.
    waiting: VecDeque<(u64, Vec<u8>)>,
    /// Packets that mattered and were sent without it being heard at the time.
    again: Vec<Vec<u8>>,
    engaged_until: u64,
    next_ping: u64,
}

impl Peer {
    fn new() -> Peer {
        Peer {
            last_heard: 0,
            position: None,
            channels: None,
            numbers: [None; 17],
            waiting: VecDeque::new(),
            again: Vec::new(),
            engaged_until: 0,
            next_ping: 0,
        }
    }

    /// Whether the peer is on `channel` in a slot of its plan. A slot it
    /// names no channel for counts if the one before it does: an iPhone stays
    /// through it while it has something to send.
    fn on(channels: &[u8; 16], slot: usize, channel: u8) -> bool {
        channels[slot] == channel || (channels[slot] == 0 && channels[(slot + 15) % 16] == channel)
    }

    fn presence(&self, now: u64, channel: u8) -> Presence {
        if self.last_heard != 0 && now.saturating_sub(self.last_heard) < HERE_FOR {
            return Presence::Here;
        }
        let (Some((at, position)), Some(channels)) = (self.position, self.channels) else {
            return Presence::Unknown;
        };
        if now.saturating_sub(at) > POSITION_HOLDS {
            return Presence::Unknown;
        }
        let theirs = (position + (now - at)) % PERIOD;
        let (slot, into) = ((theirs / SLOT) as usize, theirs % SLOT);
        if Self::on(&channels, slot, channel)
            && (into >= GUARD || Self::on(&channels, (slot + 15) % 16, channel))
        {
            return Presence::Here;
        }
        for ahead in 1..=16usize {
            if Self::on(&channels, (slot + ahead) % 16, channel) {
                // Counted from where its radio has arrived; a slot that only continues the one before needs no guard.
                let guard = if ahead == 1 && Self::on(&channels, slot, channel) {
                    0
                } else {
                    GUARD
                };
                return Presence::Away((ahead as u64 * SLOT).saturating_sub(into) + guard);
            }
        }
        Presence::Unknown
    }
}

pub struct Node {
    speaker: Speaker,
    channel: u8,
    ip: Ip,
    /// The mDNS answer that says the AirDrop service is here.
    service: Vec<u8>,
    number: u16,
    count: u16,
    next_psf: u64,
    next_mif: u64,
    service_said: u64,
    answered: u64,
    /// Asking who receives AirDrop, for a send (set from outside).
    pub browsing: bool,
    next_browse: u64,
    asked: u64,
    serial: u16,
    peers: HashMap<Mac, Peer>,
    air: VecDeque<Vec<u8>>,
    kernel: VecDeque<Vec<u8>>,
    pub events: VecDeque<Event>,
    pub counts: Counts,
}

impl Node {
    pub fn new(settings: &Settings, now: u64) -> Node {
        let ip = packet::link_local(&settings.address);
        Node {
            speaker: Speaker {
                address: settings.address,
                // Above what a phone starts with, so that it takes this node's clock: this node cannot take the phone's.
                counter: 4000,
                metric: 1000,
                host: settings.host.clone(),
                country: settings.country,
                channels: [settings.channel; 16],
                manner: settings.manner,
            },
            channel: settings.channel,
            ip,
            // 137: receives links and several kinds of file at once, and answers /Discover.
            service: packet::service(&settings.instance, &settings.host, settings.port, &ip, 137),
            number: 0,
            count: 0,
            next_psf: now,
            next_mif: now + 300_000,
            service_said: 0,
            answered: 0,
            browsing: false,
            next_browse: 0,
            asked: 0,
            serial: 0,
            peers: HashMap::new(),
            air: VecDeque::new(),
            kernel: VecDeque::new(),
            events: VecDeque::new(),
            counts: Counts::default(),
        }
    }

    /// The next frame for the monitor interface.
    pub fn for_air(&mut self) -> Option<Vec<u8>> {
        self.air.pop_front()
    }

    /// The next Ethernet frame for the kernel's interface.
    pub fn for_kernel(&mut self) -> Option<Vec<u8>> {
        self.kernel.pop_front()
    }

    fn numbered(&mut self) -> (u16, u16) {
        self.number = (self.number + 1) & 0xfff;
        self.count = self.count.wrapping_add(1);
        (self.number, self.count)
    }

    fn send(&mut self, to: &Mac, packet: &[u8]) {
        let (number, count) = self.numbered();
        self.air
            .push_back(wire::data(to, &self.speaker.address, number, count, packet));
        self.counts.to_air += 1;
    }

    fn say_service(&mut self, now: u64) {
        let datagram = packet::udp6(
            &self.ip,
            &packet::MDNS_GROUP,
            packet::MDNS_PORT,
            &self.service,
        );
        self.send(&packet::MDNS_MAC, &datagram);
        self.service_said = now;
        self.counts.service_said += 1;
    }

    /// An mDNS question, aloud: to everybody on the channel now.
    fn ask_aloud(&mut self, now: u64, question: &[u8]) {
        let datagram = packet::udp6(&self.ip, &packet::MDNS_GROUP, packet::MDNS_PORT, question);
        self.send(&packet::MDNS_MAC, &datagram);
        self.asked = now;
        self.counts.browsed += 1;
    }

    /// Who receives AirDrop, asked aloud, and of each peer heard lately in a slot of its own, where
    /// it is sure to be listening: the same question, to its address alone.
    fn browse(&mut self, now: u64) {
        let datagram = packet::udp6(
            &self.ip,
            &packet::MDNS_GROUP,
            packet::MDNS_PORT,
            &packet::browse(),
        );
        self.ask_aloud(now, &packet::browse());
        let near: Vec<Mac> = self
            .peers
            .iter()
            .filter(|(_, peer)| {
                peer.last_heard != 0 && now.saturating_sub(peer.last_heard) < ASKED_WHILE
            })
            .map(|(mac, _)| *mac)
            .collect();
        for mac in near {
            let peer = self.peers.get_mut(&mac).unwrap();
            if peer.waiting.len() < MOST_WAITING {
                peer.waiting.push_back((now, datagram.clone()));
            }
            self.release(now, mac);
        }
    }

    /// The peer of this address, made if there is room for one more.
    fn peer(&mut self, now: u64, address: Mac) -> Option<&mut Peer> {
        if !self.peers.contains_key(&address) {
            if self.peers.len() >= MOST_PEERS {
                // The one silent longest that nothing waits for makes room; failing that, the one
                // silent longest of all, if it has been silent a while. Being talked with keeps a
                // peer only for as long as it goes on being heard: addresses cost a stranger
                // nothing to make up, and a table of them must not keep a real phone out.
                let longest = |fits: &dyn Fn(&Peer) -> bool| {
                    self.peers
                        .iter()
                        .filter(|(_, peer)| fits(peer))
                        .min_by_key(|(_, peer)| peer.last_heard)
                        .map(|(mac, _)| *mac)
                };
                let stale = longest(&|peer| peer.waiting.is_empty() && peer.engaged_until < now)
                    .or_else(|| {
                        longest(&|peer| now.saturating_sub(peer.last_heard) > SILENT_FOR)
                    })?;
                self.peers.remove(&stale);
            }
            self.peers.insert(address, Peer::new());
        }
        self.peers.get_mut(&address)
    }

    /// A packet from the monitor interface.
    pub fn heard(&mut self, now: u64, packet: &[u8]) {
        let Some((radio, bytes)) = wire::heard(packet) else {
            return;
        };
        let Some(frame) = wire::frame(bytes) else {
            return;
        };
        // This node's own frames come back as the driver's word on them.
        if frame.from == self.speaker.address
            || frame.bssid != wire::BSSID
            || frame.from[0] & 1 != 0
        {
            return;
        }
        let said = frame.announcement();
        let for_us = frame.to == self.speaker.address || frame.to[0] & 1 != 0;
        if said.is_none() && (frame.kind != Kind::Data || !for_us) {
            return;
        }
        let known = self.peers.contains_key(&frame.from);
        let Some(peer) = self.peer(now, frame.from) else {
            return;
        };
        let back = now.saturating_sub(peer.last_heard) > BACK_AFTER;
        peer.last_heard = now;
        if !known {
            self.events.push_back(Event::Found(frame.from));
        }

        if let Some(said) = said {
            self.counts.announcements += 1;
            let peer = self.peers.get_mut(&frame.from).unwrap();
            if let Some(position) = said.position() {
                // The counters are true of when the frame was meant to leave; it left this much later.
                let late = u64::from(said.sent_at.wrapping_sub(said.meant_at));
                peer.position = Some((
                    now,
                    (position * TU + if late < 200_000 { late } else { 0 }) % PERIOD,
                ));
            }
            if let Some(channels) = said.channels() {
                if peer.channels != Some(channels) {
                    peer.channels = Some(channels);
                    let here = (0..16)
                        .filter(|slot| channels[*slot] == self.channel)
                        .count();
                    self.events.push_back(Event::Plan {
                        peer: frame.from,
                        channels,
                        here,
                    });
                }
            }
            if let Some(election) = said.election() {
                // Stay above it, as it counts.
                self.speaker.metric = self.speaker.metric.max(election.metric.saturating_add(100));
                self.speaker.counter = self
                    .speaker
                    .counter
                    .max(election.counter.saturating_add(100));
            }
        } else {
            self.counts.heard_at(&radio);
            let peer = self.peers.get_mut(&frame.from).unwrap();
            let stream = usize::from(frame.stream());
            if frame.retry && peer.numbers[stream] == Some(frame.number) {
                self.counts.duplicates += 1;
            } else {
                peer.numbers[stream] = Some(frame.number);
                for carried in frame.packets() {
                    if carried.ethertype == wire::ETHERTYPE_IPV6 {
                        self.received(now, &carried);
                    }
                }
            }
        }

        // It is here, now: what it missed goes again, what waits for it goes, and it hears of the service.
        if back {
            let again = std::mem::take(&mut self.peers.get_mut(&frame.from).unwrap().again);
            for packet in &again {
                self.send(&frame.from, packet);
                self.counts.repeated += 1;
            }
            if now.saturating_sub(self.service_said) >= SERVICE_EVERY {
                self.say_service(now);
            }
            if self.browsing && now.saturating_sub(self.asked) >= ANSWER_EVERY {
                self.ask_aloud(now, &packet::browse());
            }
        }
        self.release(now, frame.from);
    }

    /// An IPv6 packet a peer sent to this node, or to everybody.
    fn received(&mut self, now: u64, carried: &wire::Packet) {
        let Some(view) = packet::view(carried.payload) else {
            return;
        };
        // For this node's address, or for a group of them: nothing else is the kernel's to see.
        if view.target != self.ip && view.target[0] != 0xff {
            return;
        }
        if let Some(message) = view.mdns() {
            // Answered from here; the kernel has nobody listening for it.
            if packet::asks_for_airdrop(message) {
                // It is looking for receivers: one to stay in touch with, from now.
                if let Some(peer) = self.peers.get_mut(&carried.from) {
                    peer.engaged_until = now + ENGAGED_FOR;
                }
                if now.saturating_sub(self.answered) >= ANSWER_EVERY {
                    self.answered = now;
                    self.say_service(now);
                }
            } else if self.browsing {
                // An answer, while this computer looks for receivers: what it names, and where
                // what it only lists is, asked next.
                let (found, listed) = packet::receivers(message);
                for receiver in found {
                    self.events.push_back(Event::Receiver {
                        peer: carried.from,
                        receiver,
                    });
                }
                if let Some(instance) = listed.first() {
                    if now.saturating_sub(self.asked) >= ANSWER_EVERY {
                        self.ask_aloud(now, &packet::resolve(instance));
                    }
                }
            }
            return;
        }
        if view
            .echo_reply()
            .is_some_and(|(identifier, _)| identifier == ECHO)
        {
            self.counts.pings_answered += 1;
            return;
        }
        let mut ethernet = Vec::with_capacity(14 + carried.payload.len());
        ethernet.extend_from_slice(&carried.to);
        ethernet.extend_from_slice(&carried.from);
        ethernet.extend_from_slice(&wire::ETHERTYPE_IPV6.to_be_bytes());
        ethernet.extend_from_slice(carried.payload);
        self.kernel.push_back(ethernet);
        self.counts.to_kernel += 1;
    }

    /// An Ethernet frame the kernel sent on its interface.
    pub fn kernel_sent(&mut self, now: u64, ethernet: &[u8]) {
        if ethernet.len() < 54 || ethernet[12..14] != wire::ETHERTYPE_IPV6.to_be_bytes() {
            return;
        }
        let to: Mac = ethernet[0..6].try_into().unwrap();
        let packet = &ethernet[14..];
        let Some(view) = packet::view(packet) else {
            return;
        };
        // What AWDL has no use for: the kernel asking whether its address is free (from no address), for
        // routers, and telling of the groups it listens to (which comes under a hop-by-hop header, 0).
        if view.source == [0u8; 16]
            || view.protocol == 0
            || matches!(
                view.icmp(),
                Some(packet::ROUTER_SOLICITATION | packet::LISTENER_REPORT)
            )
        {
            return;
        }
        // Who has an address is answered here: it is written in the address.
        if view.icmp() == Some(packet::NEIGHBOUR_SOLICITATION) {
            if let Some((owner, answer)) = packet::neighbour_advertisement(&view) {
                let mut back = Vec::with_capacity(14 + answer.len());
                back.extend_from_slice(&self.speaker.address);
                back.extend_from_slice(&owner);
                back.extend_from_slice(&wire::ETHERTYPE_IPV6.to_be_bytes());
                back.extend_from_slice(&answer);
                self.kernel.push_back(back);
            }
            return;
        }
        // To everybody: the kernel's own announcements. The service is announced from here.
        if to[0] & 1 != 0 {
            return;
        }
        let Some(peer) = self.peer(now, to) else {
            self.counts.dropped += 1;
            return;
        };
        if peer.waiting.len() >= MOST_WAITING {
            peer.waiting.pop_front();
            self.counts.dropped += 1;
        }
        let peer = self.peers.get_mut(&to).unwrap();
        peer.waiting.push_back((now, packet.to_vec()));
        peer.engaged_until = now + ENGAGED_FOR;
        self.release(now, to);
    }

    /// Sends what waits for a peer, if it is here or there is no knowing; else what has waited too long.
    fn release(&mut self, now: u64, address: Mac) -> Option<u64> {
        let channel = self.channel;
        let peer = self.peers.get_mut(&address)?;
        if peer.waiting.is_empty() {
            return None;
        }
        let presence = peer.presence(now, channel);
        let certain = now.saturating_sub(peer.last_heard) < HERE_FOR && peer.last_heard != 0;
        let mut going = Vec::new();
        let mut next = None;
        while let Some((since, _)) = peer.waiting.front() {
            let overdue = now.saturating_sub(*since) >= HOLD;
            match presence {
                Presence::Away(until) if !overdue => {
                    next = Some(now + until.min(HOLD - (now - since)));
                    break;
                }
                _ => {
                    let (_, packet) = peer.waiting.pop_front().unwrap();
                    if matches!(presence, Presence::Away(_)) {
                        self.counts.sent_on_the_chance += 1;
                    }
                    // What it would be costly to lose is kept, to go again when the peer is next heard.
                    if !certain
                        && packet::view(&packet)
                            .and_then(|view| view.tcp())
                            .is_some_and(|segment| segment.matters())
                        && peer.again.len() < 32
                    {
                        peer.again.push(packet.clone());
                    }
                    going.push(packet);
                }
            }
        }
        if next.is_some() {
            self.counts.held += 1;
        }
        for packet in &going {
            self.send(&address, packet);
        }
        next
    }

    /// What is due: announcements, packets whose peer has arrived, pings. Says when to be called next.
    pub fn tick(&mut self, now: u64) -> u64 {
        if now >= self.next_psf {
            let (number, _) = self.numbered();
            self.air.push_back(self.speaker.announce(PSF, now, number));
            // On its own beat, however late this call is; a long sleep is not caught up frame by frame.
            self.next_psf = if now - self.next_psf > PSF_EVERY {
                now + PSF_EVERY
            } else {
                self.next_psf + PSF_EVERY
            };
        }
        if now >= self.next_mif {
            let (number, _) = self.numbered();
            self.air.push_back(self.speaker.announce(MIF, now, number));
            self.next_mif = if now - self.next_mif > MIF_EVERY {
                now + MIF_EVERY
            } else {
                self.next_mif + MIF_EVERY
            };
        }
        if self.browsing && now >= self.next_browse {
            self.browse(now);
            self.next_browse = now + BROWSE_EVERY;
        }
        let mut next = self.next_psf.min(self.next_mif);
        if self.browsing {
            next = next.min(self.next_browse);
        }

        let addresses: Vec<Mac> = self.peers.keys().copied().collect();
        for address in addresses {
            if let Some(due) = self.release(now, address) {
                next = next.min(due);
            }
            let channel = self.channel;
            let peer = self.peers.get_mut(&address).unwrap();
            if peer.last_heard != 0
                && now.saturating_sub(peer.last_heard) > FORGET_AFTER
                && peer.waiting.is_empty()
            {
                self.peers.remove(&address);
                self.events.push_back(Event::Lost(address));
                continue;
            }
            if peer.engaged_until > now {
                if now >= peer.next_ping {
                    match peer.presence(now, channel) {
                        Presence::Away(until) => next = next.min(now + until),
                        _ => {
                            peer.next_ping = now + PING_EVERY;
                            self.serial = self.serial.wrapping_add(1);
                            let ping = packet::echo_request(
                                &self.ip,
                                &packet::link_local(&address),
                                ECHO,
                                self.serial,
                            );
                            self.send(&address, &ping);
                            self.counts.pings += 1;
                        }
                    }
                } else {
                    next = next.min(peer.next_ping);
                }
            }
        }
        next.max(now + 200)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_rates_heard_are_said_most_used_first() {
        let mut counts = Counts::default();
        assert_eq!(counts.rates_heard(), "");
        let at = |rate, aggregated| wire::Radio {
            signal: None,
            rate,
            aggregated,
        };
        counts.heard_at(&at(wire::Rate::Legacy(48), false));
        for _ in 0..3 {
            counts.heard_at(&at(wire::Rate::Ht(7), true));
        }
        assert_eq!(
            counts.rates_heard(),
            "; heard at HT MCS 7 (3), 24 Mbit/s (1), 3 aggregated"
        );
    }
    use crate::wire::Packet;

    const US: Mac = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55];
    const PHONE: Mac = [0xb2, 0x5f, 0x5d, 0x01, 0x02, 0x03];
    const BUSY: [u8; 16] = [44, 44, 149, 44, 44, 44, 0, 0, 6, 6, 44, 6, 6, 6, 0, 0];
    const SPARSE: [u8; 16] = [60, 0, 149, 0, 0, 0, 0, 0, 6, 0, 44, 0, 0, 0, 0, 0];

    fn node() -> Node {
        Node::new(
            &Settings {
                address: US,
                host: "nova-abcdef".into(),
                instance: "0123456789ab".into(),
                port: 8771,
                country: *b"IT",
                channel: 6,
                manner: Manner::default(),
            },
            0,
        )
    }

    /// A frame as the monitor interface hands it over.
    fn monitored(sent: &[u8]) -> Vec<u8> {
        let mut packet = vec![0, 0, 9, 0, 0x20, 0, 0, 0, 0xe4];
        packet.extend_from_slice(wire::sent_frame(sent));
        packet
    }

    /// A phone whose clock is `ahead` microseconds ahead of this node's.
    struct Phone {
        speaker: Speaker,
        ahead: u64,
        number: u16,
    }

    impl Phone {
        fn new(channels: [u8; 16], ahead: u64) -> Phone {
            Phone {
                speaker: Speaker {
                    address: PHONE,
                    counter: 240,
                    metric: 530,
                    host: "phone".into(),
                    country: *b"IT",
                    channels,
                    manner: Manner::default(),
                },
                ahead,
                number: 0,
            }
        }

        fn announces(&mut self, now: u64) -> Vec<u8> {
            self.number += 1;
            monitored(&self.speaker.announce(PSF, now + self.ahead, self.number))
        }

        fn sends(&mut self, to: &Mac, packet: &[u8]) -> Vec<u8> {
            self.number += 1;
            monitored(&wire::data(to, &PHONE, self.number, self.number, packet))
        }

        /// The time, on this node's clock, at which the phone is `into` microseconds into its slot `slot`, at or after `now`.
        fn at(&self, now: u64, slot: u64, into: u64) -> u64 {
            let wanted = slot * SLOT + into;
            let theirs = (now + self.ahead) % PERIOD;
            now + (wanted + PERIOD - theirs) % PERIOD
        }
    }

    fn tcp(from: &Mac, to: &Mac, flags: u8, data: &[u8]) -> Vec<u8> {
        let mut segment = vec![0u8; 20];
        segment[12] = 0x50;
        segment[13] = flags;
        segment.extend_from_slice(data);
        let (source, target) = (packet::link_local(from), packet::link_local(to));
        let mut out = vec![0x60, 0, 0, 0];
        out.extend_from_slice(&(segment.len() as u16).to_be_bytes());
        out.extend_from_slice(&[packet::TCP, 64]);
        out.extend_from_slice(&source);
        out.extend_from_slice(&target);
        out.extend_from_slice(&segment);
        out
    }

    fn ethernet(to: &Mac, from: &Mac, packet: &[u8]) -> Vec<u8> {
        [&to[..], &from[..], &[0x86, 0xdd], packet].concat()
    }

    /// What the node put on the air, each frame as (to, what it carries).
    fn aired(node: &mut Node) -> Vec<(Mac, Vec<u8>)> {
        let mut out = Vec::new();
        while let Some(sent) = node.for_air() {
            let frame = wire::frame(wire::sent_frame(&sent)).unwrap();
            let carried: Vec<Packet> = frame.packets();
            out.push((
                frame.to,
                carried
                    .first()
                    .map(|p| p.payload.to_vec())
                    .unwrap_or_default(),
            ));
        }
        out
    }

    #[test]
    fn it_announces_itself_on_the_beat() {
        let mut node = node();
        let (mut now, mut psf, mut mif) = (0, Vec::new(), 0);
        while now < 3_000_000 {
            let next = node.tick(now);
            while let Some(sent) = node.for_air() {
                let frame = wire::frame(wire::sent_frame(&sent)).unwrap();
                let said = frame.announcement().unwrap();
                assert_eq!(
                    said.position(),
                    Some((now / TU) % 1024),
                    "the frame says where this node's clock is"
                );
                if frame.bytes[30] == PSF {
                    psf.push(now);
                } else {
                    mif += 1;
                }
            }
            assert!(next > now);
            now = next;
        }
        assert_eq!((psf.len(), mif), (27, 3));
        assert!(psf.windows(2).all(|pair| pair[1] - pair[0] == PSF_EVERY));
    }

    #[test]
    fn a_phone_is_found_and_its_plan_read() {
        let mut node = node();
        let mut phone = Phone::new(SPARSE, 333_000);
        node.heard(1000, &phone.announces(1000));
        assert_eq!(node.events.pop_front(), Some(Event::Found(PHONE)));
        assert_eq!(
            node.events.pop_front(),
            Some(Event::Plan {
                peer: PHONE,
                channels: SPARSE,
                here: 1
            })
        );
        // The same plan again says nothing; another one does.
        node.heard(200_000, &phone.announces(200_000));
        assert!(node.events.is_empty());
        phone.speaker.channels = BUSY;
        node.heard(400_000, &phone.announces(400_000));
        assert_eq!(
            node.events.pop_front(),
            Some(Event::Plan {
                peer: PHONE,
                channels: BUSY,
                here: 5
            })
        );
        // It ranks itself above the phone, whatever the phone says of itself.
        phone.speaker.metric = 5000;
        phone.speaker.counter = 9000;
        node.heard(600_000, &phone.announces(600_000));
        node.tick(600_000);
        let sent = node.for_air().unwrap();
        let election = wire::frame(wire::sent_frame(&sent))
            .unwrap()
            .announcement()
            .unwrap()
            .election()
            .unwrap();
        assert_eq!(
            (election.master, election.metric, election.counter),
            (US, 5100, 9100)
        );
    }

    #[test]
    fn what_the_phone_sends_reaches_the_kernel_once() {
        let mut node = node();
        let mut phone = Phone::new(BUSY, 0);
        let segment = tcp(&PHONE, &US, 0x18, b"hello");
        let frame = phone.sends(&US, &segment);
        node.heard(1000, &frame);
        assert_eq!(node.for_kernel(), Some(ethernet(&US, &PHONE, &segment)));
        // The same frame again, marked as a repeat (the phone did not hear the acknowledgement).
        let mut repeat = frame.clone();
        repeat[9 + 1] |= 0x08;
        node.heard(2000, &repeat);
        assert_eq!((node.for_kernel(), node.counts.duplicates), (None, 1));
        // A frame for another node; one of another network.
        node.heard(3000, &phone.sends(&[2, 9, 9, 9, 9, 9], &segment));
        let mut foreign = phone.sends(&US, &segment);
        foreign[9 + 16] ^= 1;
        node.heard(4000, &foreign);
        assert_eq!(node.for_kernel(), None);
    }

    #[test]
    fn a_packet_waits_for_the_phone_and_goes_when_it_is_here() {
        let mut node = node();
        let mut phone = Phone::new(BUSY, 123_456);
        // The phone is heard in its slot 8, a little in.
        let start = phone.at(10_000_000, 8, 10_000);
        node.heard(start, &phone.announces(start));
        node.tick(start);
        aired(&mut node);
        let ack = tcp(&US, &PHONE, 0x10, b"");

        // While it is heard, at once.
        node.kernel_sent(start + 1000, &ethernet(&PHONE, &US, &ack));
        assert_eq!(aired(&mut node), vec![(PHONE, ack.clone())]);

        // In its slot 10 it is on channel 44: the packet waits, and goes when slot 11 (channel 6) has begun.
        let away = phone.at(start, 10, 20_000);
        node.kernel_sent(away, &ethernet(&PHONE, &US, &ack));
        assert!(
            aired(&mut node).iter().all(|(to, _)| *to != PHONE),
            "nothing to the phone while it is away"
        );
        let due = node.tick(away);
        let arrives = phone.at(away, 11, 0);
        assert!(
            due >= arrives + GUARD && due <= arrives + GUARD + 1000,
            "due {due}, slot 11 at {arrives}"
        );
        node.tick(due);
        assert!(aired(&mut node).contains(&(PHONE, ack.clone())));
        assert_eq!(node.counts.held, 2);

        // In a slot it names no channel for, after one on this channel (14 after 13): it may still be here.
        let lingering = phone.at(due, 14, 5_000);
        node.kernel_sent(lingering, &ethernet(&PHONE, &US, &ack));
        assert!(aired(&mut node).contains(&(PHONE, ack.clone())));
    }

    #[test]
    fn what_matters_goes_again_when_the_phone_is_back() {
        let mut node = node();
        let mut phone = Phone::new(SPARSE, 0);
        let start = phone.at(5_000_000, 8, 10_000);
        node.heard(start, &phone.announces(start));
        node.tick(start);
        aired(&mut node);
        // An answer made while the phone is in its slot 9: by its plan it may still be here, and it is not heard.
        let answer = tcp(&US, &PHONE, 0x18, b"HTTP/1.1 200 OK");
        let bare = tcp(&US, &PHONE, 0x10, b"");
        let later = phone.at(start, 9, 30_000);
        node.kernel_sent(later, &ethernet(&PHONE, &US, &answer));
        node.kernel_sent(later, &ethernet(&PHONE, &US, &bare));
        assert_eq!(
            aired(&mut node),
            vec![(PHONE, answer.clone()), (PHONE, bare.clone())]
        );
        // It comes back a period later: the answer goes again, the bare acknowledgement does not.
        let back = phone.at(later, 8, 4_000);
        node.heard(back, &phone.announces(back));
        let sent = aired(&mut node);
        assert!(sent.contains(&(PHONE, answer.clone())) && !sent.contains(&(PHONE, bare)));
        assert_eq!(node.counts.repeated, 1);
        // Once: the next time it is heard, nothing more.
        node.heard(back + 100_000, &phone.announces(back + 100_000));
        assert!(!aired(&mut node).contains(&(PHONE, answer)));
    }

    #[test]
    fn a_peer_never_heard_is_sent_to_on_the_chance() {
        let mut node = node();
        let syn_ack = tcp(&US, &PHONE, 0x12, b"");
        node.kernel_sent(1000, &ethernet(&PHONE, &US, &syn_ack));
        assert_eq!(aired(&mut node), vec![(PHONE, syn_ack)]);
        // One whose plan has no slot on this channel: no worse.
        let mut phone = Phone::new([44; 16], 0);
        node.heard(2_000_000, &phone.announces(2_000_000));
        aired(&mut node);
        let ack = tcp(&US, &PHONE, 0x10, b"");
        node.kernel_sent(2_500_000, &ethernet(&PHONE, &US, &ack));
        assert!(aired(&mut node).contains(&(PHONE, ack)));
    }

    #[test]
    fn the_service_is_said_when_asked_and_when_a_phone_appears() {
        let mut node = node();
        let mut phone = Phone::new(SPARSE, 0);
        let service = |sent: &[(Mac, Vec<u8>)]| {
            sent.iter()
                .filter(|(to, carried)| {
                    *to == packet::MDNS_MAC && packet::view(carried).unwrap().mdns().is_some()
                })
                .count()
        };
        // Appears: said once, unasked.
        node.heard(2_000_000, &phone.announces(2_000_000));
        assert_eq!(service(&aired(&mut node)), 1);
        // Asks, twice in a tenth of a second: answered once.
        let mut question = vec![0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
        question.extend_from_slice(b"\x08_airdrop\x04_tcp\x05local\x00\x00\x0c\x00\x01");
        let asked = packet::udp6(
            &packet::link_local(&PHONE),
            &packet::MDNS_GROUP,
            packet::MDNS_PORT,
            &question,
        );
        node.heard(2_300_000, &phone.sends(&packet::MDNS_MAC, &asked));
        node.heard(2_350_000, &phone.sends(&packet::MDNS_MAC, &asked));
        assert_eq!(service(&aired(&mut node)), 1);
        assert_eq!(
            node.for_kernel(),
            None,
            "the kernel is not asked about mDNS"
        );
        // What is said names this node's address and port.
        let said = packet::service(
            "0123456789ab",
            "nova-abcdef",
            8771,
            &packet::link_local(&US),
            137,
        );
        node.heard(4_000_000, &phone.sends(&packet::MDNS_MAC, &asked));
        let sent = aired(&mut node);
        assert!(sent
            .iter()
            .any(|(_, carried)| packet::view(carried).unwrap().mdns() == Some(&said[..])));
    }

    #[test]
    fn while_it_sends_it_asks_who_receives_and_hears_the_answers() {
        let mut node = node();
        let mut phone = Phone::new([6; 16], 0);
        let questions = |sent: &[(Mac, Vec<u8>)]| {
            sent.iter()
                .filter(|(_, carried)| {
                    packet::view(carried)
                        .and_then(|view| view.mdns().map(|m| m.to_vec()))
                        .is_some_and(|m| m == packet::browse())
                })
                .map(|(to, _)| *to)
                .collect::<Vec<Mac>>()
        };
        node.heard(1_000_000, &phone.announces(1_000_000));
        node.tick(1_000_000);
        assert!(
            questions(&aired(&mut node)).is_empty(),
            "nothing asked while it only receives"
        );

        node.browsing = true;
        node.tick(1_100_000);
        assert_eq!(
            questions(&aired(&mut node)),
            vec![packet::MDNS_MAC, PHONE],
            "aloud, and of the phone heard lately"
        );
        node.tick(1_500_000);
        assert!(questions(&aired(&mut node)).is_empty(), "once a second");
        // The phone back after a while away: asked aloud at once.
        node.heard(1_700_000, &phone.announces(1_700_000));
        assert_eq!(questions(&aired(&mut node)), vec![packet::MDNS_MAC]);

        // Its answer names its receiver.
        let answer = packet::service(
            "abcdef012345",
            "Zoes-Phone",
            8770,
            &packet::link_local(&PHONE),
            1019,
        );
        let datagram = packet::udp6(
            &packet::link_local(&PHONE),
            &packet::MDNS_GROUP,
            packet::MDNS_PORT,
            &answer,
        );
        node.events.clear();
        node.heard(1_750_000, &phone.sends(&packet::MDNS_MAC, &datagram));
        assert_eq!(
            node.events.pop_front(),
            Some(Event::Receiver {
                peer: PHONE,
                receiver: packet::Receiver {
                    instance: "abcdef012345".into(),
                    host: "Zoes-Phone.local".into(),
                    port: 8770
                }
            })
        );
        assert_eq!(node.for_kernel(), None, "the kernel is not told of mDNS");
        // Not looked for, not heard.
        node.browsing = false;
        node.heard(1_800_000, &phone.sends(&packet::MDNS_MAC, &datagram));
        assert!(node.events.is_empty());
    }

    #[test]
    fn the_kernel_is_answered_about_neighbours_and_its_chatter_stays_here() {
        let mut node = node();
        let (ours, theirs) = (packet::link_local(&US), packet::link_local(&PHONE));
        let mut body = vec![0, 0, 0, 0];
        body.extend_from_slice(&theirs);
        let solicitation = packet::icmp6(&ours, &theirs, packet::NEIGHBOUR_SOLICITATION, &body);
        node.kernel_sent(
            1000,
            &ethernet(&[0x33, 0x33, 0xff, 1, 2, 3], &US, &solicitation),
        );
        let answer = node.for_kernel().unwrap();
        assert_eq!((&answer[0..6], &answer[6..12]), (&US[..], &PHONE[..]));
        assert_eq!(
            packet::view(&answer[14..]).unwrap().icmp(),
            Some(packet::NEIGHBOUR_ADVERTISEMENT)
        );
        // Router solicitations, listener reports, checks from no address, anything to everybody, IPv4.
        let router = packet::icmp6(
            &ours,
            &packet::MDNS_GROUP,
            packet::ROUTER_SOLICITATION,
            &[0; 4],
        );
        node.kernel_sent(2000, &ethernet(&[0x33, 0x33, 0, 0, 0, 2], &US, &router));
        let probing = packet::icmp6(&[0; 16], &theirs, packet::NEIGHBOUR_SOLICITATION, &body);
        node.kernel_sent(2000, &ethernet(&[0x33, 0x33, 0xff, 1, 2, 3], &US, &probing));
        let everybody = packet::udp6(
            &ours,
            &packet::MDNS_GROUP,
            packet::MDNS_PORT,
            b"the kernel's own mDNS",
        );
        node.kernel_sent(2000, &ethernet(&packet::MDNS_MAC, &US, &everybody));
        node.kernel_sent(
            2000,
            &[&PHONE[..], &US[..], &[0x08, 0x00], &[0x45; 40]].concat(),
        );
        assert!(aired(&mut node).is_empty() && node.for_kernel().is_none());
    }

    #[test]
    fn a_peer_being_talked_with_is_pinged_and_a_silent_one_forgotten() {
        let mut node = node();
        let mut phone = Phone::new([6; 16], 0);
        node.heard(1_000_000, &phone.announces(1_000_000));
        node.tick(1_000_000);
        aired(&mut node);
        assert_eq!(
            node.counts.pings, 0,
            "nothing is sent to a peer nobody talks with"
        );
        node.kernel_sent(
            1_100_000,
            &ethernet(&PHONE, &US, &tcp(&US, &PHONE, 0x10, b"")),
        );
        let mut now = 1_100_000;
        while now < 4_200_000 {
            node.heard(now, &phone.announces(now));
            now = node.tick(now).min(now + 100_000);
        }
        assert_eq!(node.counts.pings, 4);
        let pings: Vec<_> = aired(&mut node)
            .into_iter()
            .filter(|(to, carried)| {
                *to == PHONE && packet::view(carried).unwrap().icmp() == Some(packet::ECHO_REQUEST)
            })
            .collect();
        assert_eq!(pings.len(), 4);
        // Its answer is counted and kept from the kernel.
        let mut reply = pings[0].1.clone();
        reply[40] = packet::ECHO_REPLY;
        let (ours, theirs) = (packet::link_local(&US), packet::link_local(&PHONE));
        reply[8..24].copy_from_slice(&theirs);
        reply[24..40].copy_from_slice(&ours);
        node.heard(now, &phone.sends(&US, &reply));
        assert_eq!((node.counts.pings_answered, node.for_kernel()), (1, None));
        // A minute of silence, and it is gone.
        node.events.clear();
        node.tick(now + FORGET_AFTER + 20_000_000);
        assert_eq!(node.events.pop_front(), Some(Event::Lost(PHONE)));
    }

    #[test]
    fn a_table_full_of_made_up_peers_does_not_keep_a_phone_out_for_long() {
        let mut node = node();
        let mut now = 10_000_000;
        // As many addresses as the table holds, each heard once and each made worth keeping: the
        // kernel has something to say to it.
        for n in 0..MOST_PEERS as u8 {
            let made_up: Mac = [0x02, 0xee, 0, 0, 0, n];
            let mut speaker = Phone::new(BUSY, 0).speaker;
            speaker.address = made_up;
            node.heard(now, &monitored(&speaker.announce(PSF, now, 1)));
            node.kernel_sent(
                now,
                &ethernet(&made_up, &US, &tcp(&US, &made_up, 0x18, b"x")),
            );
        }
        assert_eq!(node.peers.len(), MOST_PEERS);
        node.events.clear();
        // A phone that turns up at once finds no room: every place is taken by a peer just heard.
        let mut phone = Phone::new(BUSY, 0);
        now += 500_000;
        node.heard(now, &phone.announces(now));
        assert!(!node.peers.contains_key(&PHONE));
        // The made-up ones say nothing more, and two seconds of that is all their places are held for.
        now += SILENT_FOR + 100_000;
        node.heard(now, &phone.announces(now));
        assert!(node.peers.contains_key(&PHONE));
        assert_eq!(node.peers.len(), MOST_PEERS);
        assert!(node
            .events
            .iter()
            .any(|event| matches!(event, Event::Found(peer) if *peer == PHONE)));
    }
}
