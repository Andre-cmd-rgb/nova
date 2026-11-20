//! ANCS, as Apple's specification has it: the service and its three
//! characteristics, the Notification Source's events, the Control Point's
//! commands and the Data Source's answers; and the texts made of what the
//! iPhone sends.

pub const ANCS_SERVICE: &str = "7905f431-b5ce-4e99-a40f-4b1e122d00d0";
pub const NOTIFICATION_SOURCE: &str = "9fbf120d-6301-42d9-8c58-25e699a21dbd";
pub const CONTROL_POINT: &str = "69d1d8f3-45e1-49a8-9821-9bbdfdaad9d9";
pub const DATA_SOURCE: &str = "22eac6e9-24d6-4bb5-be44-b36ace7c7bfb";

// EventID
#[cfg(test)]
pub const ADDED: u8 = 0;
pub const MODIFIED: u8 = 1;
pub const REMOVED: u8 = 2;
// EventFlags
pub const SILENT: u8 = 1;
#[cfg(test)]
pub const IMPORTANT: u8 = 2;
pub const PRE_EXISTING: u8 = 4;
#[cfg(test)]
pub const POSITIVE_ACTION: u8 = 8;
pub const NEGATIVE_ACTION: u8 = 16;
// CategoryID
pub const INCOMING_CALL: u8 = 1;
pub const MISSED_CALL: u8 = 2;
pub const VOICEMAIL: u8 = 3;
pub const SOCIAL: u8 = 4;
pub const SCHEDULE: u8 = 5;
pub const EMAIL: u8 = 6;
pub const NEWS: u8 = 7;
pub const HEALTH_AND_FITNESS: u8 = 8;
pub const BUSINESS_AND_FINANCE: u8 = 9;
pub const LOCATION: u8 = 10;
pub const ENTERTAINMENT: u8 = 11;
// CommandID
const GET_NOTIFICATION_ATTRIBUTES: u8 = 0;
const GET_APP_ATTRIBUTES: u8 = 1;
const PERFORM_NOTIFICATION_ACTION: u8 = 2;
// NotificationAttributeID
pub const APP_IDENTIFIER: u8 = 0;
pub const TITLE: u8 = 1;
pub const SUBTITLE: u8 = 2;
pub const MESSAGE: u8 = 3;
pub const DATE: u8 = 5;
// AppAttributeID
pub const DISPLAY_NAME: u8 = 0;
// ActionID
#[cfg(test)]
pub const POSITIVE: u8 = 0;
pub const NEGATIVE: u8 = 1;

/// The most of each text asked for, in bytes: a toast shows two lines of
/// title and three of message, and every byte asked for crosses the radio.
/// The iPhone keeps to them; one that did not would be cut here all the same.
pub fn limit(attribute: u8) -> Option<usize> {
    match attribute {
        TITLE | SUBTITLE => Some(128),
        MESSAGE => Some(320),
        _ => None,
    }
}
/// A name, an app's or a device's, is cut at this many bytes.
pub const NAME_LIMIT: usize = 64;
/// An answer is a few hundred bytes; one longer than this is not one asked for.
pub const ANSWER_MOST: usize = 8192;

/// A glyph for each category, as the iPhone's apps have no icon here.
pub fn glyph(category: u8) -> &'static str {
    match category {
        MISSED_CALL => "\u{F03FA}",
        VOICEMAIL => "\u{F057D}",
        SOCIAL => "\u{F0369}",
        SCHEDULE => "\u{F00ED}",
        EMAIL => "\u{F01EE}",
        NEWS => "\u{F0395}",
        HEALTH_AND_FITNESS => "\u{F05F6}",
        BUSINESS_AND_FINANCE => "\u{F0114}",
        LOCATION => "\u{F034E}",
        ENTERTAINMENT => "\u{F0ECF}",
        _ => PHONE_GLYPH,
    }
}
pub const PHONE_GLYPH: &str = "\u{F011C}";
pub const BLUETOOTH_GLYPH: &str = "\u{F00AF}";

/// A Notification Source event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Event {
    pub kind: u8,
    pub flags: u8,
    pub category: u8,
    pub count: u8,
    pub uid: u32,
}

/// An event, from its eight bytes, or None.
pub fn parse_event(data: &[u8]) -> Option<Event> {
    let bytes: [u8; 8] = data.try_into().ok()?;
    let event = Event {
        kind: bytes[0],
        flags: bytes[1],
        category: bytes[2],
        count: bytes[3],
        uid: u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
    };
    (event.kind <= REMOVED).then_some(event)
}

/// Get Notification Attributes for <uid>: each attribute's ID, and the
/// texts' a length the answer may not pass.
pub fn notification_attributes_command(uid: u32, attributes: &[u8]) -> Vec<u8> {
    let mut command = vec![GET_NOTIFICATION_ATTRIBUTES];
    command.extend_from_slice(&uid.to_le_bytes());
    for &attribute in attributes {
        command.push(attribute);
        if let Some(most) = limit(attribute) {
            command.extend_from_slice(&(most as u16).to_le_bytes());
        }
    }
    command
}

/// Get App Attributes for the app identifier <app>: its name.
pub fn app_attributes_command(app: &[u8]) -> Vec<u8> {
    let mut command = vec![GET_APP_ATTRIBUTES];
    command.extend_from_slice(app);
    command.push(0);
    command.push(DISPLAY_NAME);
    command
}

/// Perform Notification Action: <action> on notification <uid>.
pub fn action_command(uid: u32, action: u8) -> Vec<u8> {
    let mut command = vec![PERFORM_NOTIFICATION_ACTION];
    command.extend_from_slice(&uid.to_le_bytes());
    command.push(action);
    command
}

/// The attributes of an answer, by their ID, in the order asked.
pub type Found = Vec<(u8, Vec<u8>)>;

pub fn attribute(found: &Found, id: u8) -> &[u8] {
    found
        .iter()
        .find(|(a, _)| *a == id)
        .map(|(_, v)| v.as_slice())
        .unwrap_or(&[])
}

/// A Data Source answer put back together from its fragments: an answer
/// has no length of its own, and is whole once every attribute asked for
/// is in. Its start is how it begins: the command's ID and the
/// notification's UID, or the app's identifier. Bytes before the start,
/// left of an answer that was given up on, are passed over.
#[derive(Debug, Clone)]
pub struct Answer {
    start: Vec<u8>,
    wanted: Vec<u8>,
    buffer: Vec<u8>,
}

impl Answer {
    pub fn new(start: &[u8], wanted: &[u8]) -> Answer {
        let mut unique = wanted.to_vec();
        unique.sort_unstable();
        unique.dedup();
        Answer {
            start: start.to_vec(),
            wanted: unique,
            buffer: Vec::new(),
        }
    }

    /// The attributes once all are in; None until then. An error for an
    /// answer that cannot be the one asked for.
    pub fn feed(&mut self, fragment: &[u8]) -> Result<Option<Found>, String> {
        self.buffer.extend_from_slice(fragment);
        let Some(at) = find(&self.buffer, &self.start) else {
            // What could be the start's first bytes is kept for the next one.
            let keep = self.start.len().saturating_sub(1);
            let from = self.buffer.len().saturating_sub(keep);
            self.buffer.drain(..from);
            return Ok(None);
        };
        self.buffer.drain(..at);
        if self.buffer.len() > ANSWER_MOST {
            return Err(format!("an answer of more than {ANSWER_MOST} bytes"));
        }
        let mut found: Found = Vec::new();
        let mut position = self.start.len();
        while found.len() < self.wanted.len() {
            if position + 3 > self.buffer.len() {
                return Ok(None);
            }
            let attribute = self.buffer[position];
            let size =
                u16::from_le_bytes([self.buffer[position + 1], self.buffer[position + 2]]) as usize;
            if !self.wanted.contains(&attribute) || found.iter().any(|(a, _)| *a == attribute) {
                return Err(format!("attribute {attribute} was not asked for"));
            }
            if position + 3 + size > self.buffer.len() {
                return Ok(None);
            }
            found.push((
                attribute,
                self.buffer[position + 3..position + 3 + size].to_vec(),
            ));
            position += 3 + size;
        }
        Ok(Some(found))
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// Unicode's format characters (Cf), as of Unicode 16.
const FORMAT: &[(u32, u32)] = &[
    (0xAD, 0xAD),
    (0x600, 0x605),
    (0x61C, 0x61C),
    (0x6DD, 0x6DD),
    (0x70F, 0x70F),
    (0x890, 0x891),
    (0x8E2, 0x8E2),
    (0x180E, 0x180E),
    (0x200B, 0x200F),
    (0x202A, 0x202E),
    (0x2060, 0x2064),
    (0x2066, 0x206F),
    (0xFEFF, 0xFEFF),
    (0xFFF9, 0xFFFB),
    (0x110BD, 0x110BD),
    (0x110CD, 0x110CD),
    (0x13430, 0x1343F),
    (0x1BCA0, 0x1BCA3),
    (0x1D173, 0x1D17A),
    (0xE0001, 0xE0001),
    (0xE0020, 0xE007F),
];

fn is_format(c: char) -> bool {
    let code = c as u32;
    FORMAT
        .iter()
        .any(|&(low, high)| low <= code && code <= high)
}

/// A character of a text as shown: a control character a space, a format
/// character nothing. Format characters are taken out of what the iPhone
/// sends: the bidirectional ones can make a text read other than it is
/// (U+202E turns what follows around). The two joiners stay, which emoji and
/// some scripts need, and which move nothing.
fn character(c: char, out: &mut String) {
    if c.is_control() && c != '\n' {
        out.push(' ');
    } else if !is_format(c) || c == '\u{200C}' || c == '\u{200D}' {
        out.push(c);
    }
}

/// An attribute as text: UTF-8, its control characters spaces, its format
/// characters gone, its lines without runs of space and none of them empty.
/// At <limit> bytes, where the iPhone cuts it short (and here, past them),
/// half a character is dropped and it ends in an ellipsis.
pub fn text(raw: &[u8], limit: Option<usize>) -> String {
    let cut = matches!(limit, Some(most) if raw.len() >= most);
    let raw = match limit {
        Some(most) if cut => &raw[..most],
        _ => raw,
    };
    let mut value = String::from_utf8_lossy(raw).into_owned();
    if cut {
        let kept = value.trim_end_matches('\u{FFFD}').len();
        value.truncate(kept);
    }
    let mut mapped = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '\u{2028}' | '\u{2029}' => mapped.push('\n'),
            c => character(c, &mut mapped),
        }
    }
    let lines: Vec<String> = mapped
        .split('\n')
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|line| !line.is_empty())
        .collect();
    let mut value = lines.join("\n");
    if cut && !value.is_empty() {
        value.push('…');
    }
    value
}

/// A name, an app's or a device's, as one line of text.
pub fn name_text(raw: &[u8]) -> String {
    // Cut only past the limit: no one cut it short at exactly that length.
    let limit = (raw.len() > NAME_LIMIT).then_some(NAME_LIMIT);
    text(raw, limit).split('\n').collect::<Vec<_>>().join(" ")
}

/// An app's name when the iPhone does not give it: the last part of its
/// identifier (net.whatsapp.WhatsApp is WhatsApp).
pub fn app_fallback(app: &[u8]) -> String {
    let name = name_text(app);
    let last = name.rsplit('.').next().unwrap_or("");
    if last.is_empty() {
        "iPhone".into()
    } else {
        last.into()
    }
}

/// Text that the shell reads as markup, shown as it is.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            c => out.push(c),
        }
    }
    out
}

/// A notification's summary and body: the app and the title, as the
/// iPhone's lock screen has them in that order, and the subtitle and the
/// message below. The body is markup to the shell, so it is escaped.
pub fn toast_text(app: &str, title: &str, subtitle: &str, message: &str) -> (String, String) {
    let summary = if !title.is_empty() && title != app {
        format!("{app} · {title}")
    } else if !app.is_empty() {
        app.to_string()
    } else {
        title.to_string()
    };
    let body: Vec<&str> = [subtitle, message]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect();
    (summary, escape(&body.join("\n")))
}

#[repr(C)]
struct Tm {
    sec: i32,
    min: i32,
    hour: i32,
    mday: i32,
    mon: i32,
    year: i32,
    wday: i32,
    yday: i32,
    isdst: i32,
    gmtoff: i64,
    zone: *const u8,
}

extern "C" {
    // std has no local time; the C library's knows the zone.
    fn mktime(tm: *mut Tm) -> i64;
}

/// The Date attribute, yyyyMMdd'T'HHmmSS in the iPhone's local time, as
/// seconds since the epoch, or None.
pub fn parse_date(raw: &[u8]) -> Option<f64> {
    let value = text(raw, None);
    let bytes = value.as_bytes();
    // ASCII first: the parts below are cut by byte, and a character of two
    // bytes across a cut would panic, which a device must never be able to do.
    if !value.is_ascii() || bytes.len() != 15 || bytes[8] != b'T' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i32> {
        let part = &value[range];
        part.bytes()
            .all(|b| b.is_ascii_digit())
            .then(|| part.parse().ok())
            .flatten()
    };
    let (year, month, day) = (number(0..4)?, number(4..6)?, number(6..8)?);
    let (hour, minute, second) = (number(9..11)?, number(11..13)?, number(13..15)?);
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 61
    {
        return None;
    }
    let mut tm = Tm {
        sec: second,
        min: minute,
        hour,
        mday: day,
        mon: month - 1,
        year: year - 1900,
        wday: 0,
        yday: 0,
        isdst: -1,
        gmtoff: 0,
        zone: std::ptr::null(),
    };
    // SAFETY: a struct tm laid out as glibc's, which mktime reads and normalises in place.
    let when = unsafe { mktime(&mut tm) };
    (when != -1).then_some(when as f64)
}

/// Whether a notification of <date> came after the link dropped at
/// <dropped>, give or take a minute of the two clocks, and not from the
/// future.
pub fn arrived_while_away(date: &[u8], dropped: f64, now: f64) -> bool {
    parse_date(date).is_some_and(|when| dropped - 60.0 <= when && when <= now + 300.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn unhex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn an_event_is_eight_bytes_little_endian() {
        // Added, Important + NegativeAction, Social, 3 in the category, UID 0x01020304.
        let event = parse_event(&unhex("0012040304030201")).unwrap();
        assert_eq!(
            event,
            Event {
                kind: ADDED,
                flags: IMPORTANT | NEGATIVE_ACTION,
                category: SOCIAL,
                count: 3,
                uid: 0x01020304
            }
        );
    }

    #[test]
    fn each_flag() {
        let event = parse_event(&[MODIFIED, 0x1F, EMAIL, 1, 9, 0, 0, 0]).unwrap();
        assert_eq!(
            event.flags,
            SILENT | IMPORTANT | PRE_EXISTING | POSITIVE_ACTION | NEGATIVE_ACTION
        );
        assert_eq!((event.kind, event.uid), (MODIFIED, 9));
    }

    #[test]
    fn malformed_events_are_none() {
        assert!(parse_event(b"").is_none());
        assert!(parse_event(&[0; 7]).is_none());
        assert!(parse_event(&[0; 9]).is_none());
        assert!(parse_event(&[3, 0, 0, 0, 1, 0, 0, 0]).is_none()); // no EventID 3
    }

    #[test]
    fn the_specification_numbers() {
        assert_eq!((ADDED, MODIFIED, REMOVED), (0, 1, 2));
        assert_eq!(
            (
                SILENT,
                IMPORTANT,
                PRE_EXISTING,
                POSITIVE_ACTION,
                NEGATIVE_ACTION
            ),
            (1, 2, 4, 8, 16)
        );
        assert_eq!(
            (INCOMING_CALL, MISSED_CALL, SOCIAL, ENTERTAINMENT),
            (1, 2, 4, 11)
        );
        assert_eq!(ANCS_SERVICE, "7905f431-b5ce-4e99-a40f-4b1e122d00d0");
        assert_eq!(NOTIFICATION_SOURCE, "9fbf120d-6301-42d9-8c58-25e699a21dbd");
        assert_eq!(CONTROL_POINT, "69d1d8f3-45e1-49a8-9821-9bbdfdaad9d9");
        assert_eq!(DATA_SOURCE, "22eac6e9-24d6-4bb5-be44-b36ace7c7bfb");
    }

    #[test]
    fn get_notification_attributes() {
        // CommandID 0, UID 5, then AppIdentifier; Title, Subtitle and
        // Message each with their most bytes, little-endian.
        let command =
            notification_attributes_command(5, &[APP_IDENTIFIER, TITLE, SUBTITLE, MESSAGE]);
        assert_eq!(
            hex(&command),
            "00 05 00 00 00 00 01 80 00 02 80 00 03 40 01"
        );
    }

    #[test]
    fn the_date_has_no_length() {
        let command = notification_attributes_command(0xA1B2C3D4, &[DATE]);
        assert_eq!(hex(&command), "00 d4 c3 b2 a1 05");
    }

    #[test]
    fn get_app_attributes() {
        let command = app_attributes_command(b"net.whatsapp.WhatsApp");
        assert_eq!(command, b"\x01net.whatsapp.WhatsApp\x00\x00");
    }

    #[test]
    fn perform_notification_action() {
        assert_eq!(hex(&action_command(5, NEGATIVE)), "02 05 00 00 00 01");
        assert_eq!(
            hex(&action_command(0x01020304, POSITIVE)),
            "02 04 03 02 01 00"
        );
    }

    fn note() -> Vec<u8> {
        let mut note = unhex("0005000000");
        note.extend_from_slice(&[0, 21, 0]);
        note.extend_from_slice(b"net.whatsapp.WhatsApp");
        note.extend_from_slice(&[1, 4, 0]);
        note.extend_from_slice(b"Anna");
        note.extend_from_slice(&[2, 0, 0]);
        note.extend_from_slice(&[3, 10, 0]);
        note.extend_from_slice(b"Ciao <3 :)");
        note
    }
    const WANTED: [u8; 4] = [APP_IDENTIFIER, TITLE, SUBTITLE, MESSAGE];

    #[test]
    fn whole_in_one() {
        let note = note();
        let found = Answer::new(&note[..5], &WANTED)
            .feed(&note)
            .unwrap()
            .unwrap();
        assert_eq!(attribute(&found, 0), b"net.whatsapp.WhatsApp");
        assert_eq!(attribute(&found, 1), b"Anna");
        assert_eq!(attribute(&found, 2), b"");
        assert_eq!(attribute(&found, 3), b"Ciao <3 :)");
        assert_eq!(found.len(), 4);
    }

    #[test]
    fn put_back_together_from_fragments_of_any_size() {
        let note = note();
        for size in [1, 2, 3, 7, 20, 23] {
            let mut answer = Answer::new(&note[..5], &WANTED);
            let results: Vec<_> = note
                .chunks(size)
                .map(|piece| answer.feed(piece).unwrap())
                .collect();
            assert!(
                results[..results.len() - 1].iter().all(|r| r.is_none()),
                "{size}"
            );
            let last = results.last().unwrap().as_ref().unwrap();
            assert_eq!(attribute(last, 3), b"Ciao <3 :)", "{size}");
        }
    }

    #[test]
    fn the_tail_of_an_answer_given_up_on_is_passed_over() {
        let note = note();
        let mut answer = Answer::new(&note[..5], &WANTED);
        assert!(answer.feed(b"\x03\x05\x00tail!").unwrap().is_none());
        assert!(answer.feed(&note[..3]).unwrap().is_none());
        let found = answer.feed(&note[3..]).unwrap().unwrap();
        assert_eq!(attribute(&found, 1), b"Anna");
    }

    #[test]
    fn an_attribute_not_asked_for_does_not_fit() {
        let note = note();
        let mut answer = Answer::new(&note[..5], &[APP_IDENTIFIER]);
        let mut reply = unhex("0005000000");
        reply.extend_from_slice(&[1, 1, 0, b'x']);
        assert!(answer.feed(&reply).is_err());
    }

    #[test]
    fn another_notification_answer_is_not_this_one() {
        let mut answer = Answer::new(&unhex("0006000000"), &WANTED);
        assert!(answer.feed(&note()).unwrap().is_none());
    }

    #[test]
    fn an_app_answer() {
        let command = app_attributes_command(b"com.apple.MobileSMS");
        let mut reply = b"\x01com.apple.MobileSMS\x00".to_vec();
        reply.extend_from_slice(&[0, 8, 0]);
        reply.extend_from_slice(b"Messages");
        let mut answer = Answer::new(&command[..command.len() - 1], &[DISPLAY_NAME]);
        assert!(answer.feed(&reply[..10]).unwrap().is_none());
        let found = answer.feed(&reply[10..]).unwrap().unwrap();
        assert_eq!(found, vec![(0, b"Messages".to_vec())]);
    }

    #[test]
    fn plain_text() {
        assert_eq!(
            text(b"Hello  there\r\n\n\tyou\x00", None),
            "Hello there\nyou"
        );
    }

    #[test]
    fn cut_short_at_the_limit() {
        let all = "é".repeat(64);
        let raw = &all.as_bytes()[..127]; // 63 whole, then half of one
        assert_eq!(text(raw, Some(127)), "é".repeat(63) + "…");
        assert_eq!(text(b"short", Some(128)), "short");
    }

    #[test]
    fn emoji_sequences_stay_whole() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
        assert_eq!(text(family.as_bytes(), None), family);
    }

    #[test]
    fn line_separators_become_lines() {
        assert_eq!(
            text("one\u{2028}two\u{2029}three".as_bytes(), None),
            "one\ntwo\nthree"
        );
    }

    #[test]
    fn format_characters_go_but_the_joiners() {
        // U+202E turns what follows around: "exe.txt" would read "txt.exe".
        let spoof = "invoice\u{202E}txt.exe";
        assert_eq!(text(spoof.as_bytes(), None), "invoicetxt.exe");
        let hidden = "\u{2066}a\u{2069}\u{200B}b\u{FEFF}\u{00AD}c\u{200E}";
        assert_eq!(text(hidden.as_bytes(), None), "abc");
        let joined = "a\u{200C}b\u{200D}c";
        assert_eq!(text(joined.as_bytes(), None), joined);
    }

    #[test]
    fn more_than_the_limit_is_cut_here() {
        // An iPhone keeps to the lengths asked for; text past them is cut
        // all the same, before it is decoded.
        assert_eq!(text(&[b'A'; 5000], Some(128)), "A".repeat(128) + "…");
        assert_eq!(
            text("é".repeat(3000).as_bytes(), Some(128)),
            "é".repeat(64) + "…"
        );
        let mixed = "\u{202E}".to_string() + &"B".repeat(400);
        assert_eq!(text(mixed.as_bytes(), Some(320)), "B".repeat(317) + "…");
    }

    #[test]
    fn names_are_one_line_and_short() {
        assert_eq!(name_text(b"Anna's\niPhone"), "Anna's iPhone");
        let long = "\u{202E}".to_string() + &"x".repeat(100);
        assert_eq!(name_text(long.as_bytes()), "x".repeat(61) + "…");
        assert_eq!(name_text(b"WhatsApp"), "WhatsApp");
        assert_eq!(name_text(b""), "");
        // Exactly the limit is whole; one byte more is cut.
        assert_eq!(name_text("y".repeat(64).as_bytes()), "y".repeat(64));
        assert_eq!(name_text("y".repeat(65).as_bytes()), "y".repeat(64) + "…");
        // A text the iPhone sends at exactly its limit was cut by the iPhone.
        assert_eq!(text(&[b'z'; 128], Some(128)), "z".repeat(128) + "…");
    }

    #[test]
    fn an_answer_longer_than_any_asked_for_does_not_fit() {
        let note = note();
        let mut answer = Answer::new(&note[..5], &WANTED);
        let mut oversize = note[..5].to_vec();
        oversize.push(0);
        oversize.extend_from_slice(&60000u16.to_le_bytes());
        oversize.extend_from_slice(&[b'x'; 4000]);
        assert!(answer.feed(&oversize).unwrap().is_none());
        assert!(answer.feed(&[b'x'; 5000]).is_err());
    }

    #[test]
    fn summary_and_body() {
        assert_eq!(
            toast_text("WhatsApp", "Anna", "", "Ciao <3 & more"),
            ("WhatsApp · Anna".into(), "Ciao &lt;3 &amp; more".into())
        );
        assert_eq!(
            toast_text("Mail", "Amazon", "Your order", "Shipped"),
            ("Mail · Amazon".into(), "Your order\nShipped".into())
        );
        assert_eq!(
            toast_text("Reminders", "Reminders", "", "Milk"),
            ("Reminders".into(), "Milk".into())
        );
        assert_eq!(
            toast_text("Clock", "", "", "Alarm"),
            ("Clock".into(), "Alarm".into())
        );
    }

    #[test]
    fn an_app_with_no_name() {
        assert_eq!(app_fallback(b"net.whatsapp.WhatsApp"), "WhatsApp");
        assert_eq!(app_fallback(b""), "iPhone");
    }

    #[test]
    fn the_date() {
        // Fifteen bytes with the T in place, but an é across the year's end.
        assert_eq!(parse_date("202é112T120000".as_bytes()), None);
        let a = parse_date(b"20261117T143005").unwrap();
        let b = parse_date(b"20261117T143000").unwrap();
        assert_eq!(a - b, 5.0);
        assert_eq!(parse_date(b"20261118T143000").unwrap() - b, 86400.0);
        assert!(parse_date(b"yesterday").is_none());
        assert!(parse_date(b"").is_none());
        assert!(parse_date(b"20261317T143000").is_none());
    }

    #[test]
    fn only_what_came_after_the_link_dropped() {
        let dropped = parse_date(b"20261117T143000").unwrap();
        let now = dropped + 120.0;
        assert!(arrived_while_away(b"20261117T143100", dropped, now));
        assert!(arrived_while_away(b"20261117T142930", dropped, now)); // a minute of clocks
        assert!(!arrived_while_away(b"20261117T140000", dropped, now));
        assert!(!arrived_while_away(b"20261118T143000", dropped, now));
        assert!(!arrived_while_away(b"", dropped, now));
    }
}
