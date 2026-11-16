//! `nova airdrop send` at the command line: the receivers the daemon lists
//! (send.rs), numbered as they appear, one picked by its number or by its
//! name (--to), and how the send goes, in plain words. And the little of
//! JSON it takes to read the daemon's lines.

use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use crate::meet::size;

/// The one setting of an iPhone's that takes AirDrop from this computer: it is nobody's contact.
pub const EVERYONE: &str =
    "On the iPhone, choose Everyone for 10 Minutes (Settings, General, AirDrop).";
/// How long it looks before it says what the iPhone needs.
pub const HINT_AFTER: Duration = Duration::from_secs(10);

/// The last words of a send that ended without any of the daemon's.
pub const WENT_OFF: &str = "AirDrop went off before anything was sent.";

// ---------------------------------------------------------------------- JSON

/// A line of JSON, as far as it is read here.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    Text(String),
    List(Vec<Json>),
    Map(Vec<(String, Json)>),
}

impl Json {
    pub fn parse(text: &str) -> Option<Json> {
        let mut reading = Reading {
            bytes: text.as_bytes(),
            at: 0,
        };
        let value = reading.value(0)?;
        reading.space();
        (reading.at == reading.bytes.len()).then_some(value)
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Map(pairs) => pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// The text under `key`; "" for none.
    pub fn text(&self, key: &str) -> &str {
        match self.get(key) {
            Some(Json::Text(text)) => text,
            _ => "",
        }
    }

    pub fn number(&self, key: &str) -> f64 {
        match self.get(key) {
            Some(Json::Number(n)) => *n,
            _ => 0.0,
        }
    }

    pub fn list(&self, key: &str) -> &[Json] {
        match self.get(key) {
            Some(Json::List(items)) => items,
            _ => &[],
        }
    }

    pub fn flag(&self, key: &str) -> bool {
        matches!(self.get(key), Some(Json::Bool(true)))
    }
}

struct Reading<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reading<'_> {
    fn space(&mut self) {
        while matches!(self.bytes.get(self.at), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn eat(&mut self, word: &[u8]) -> bool {
        let there = self.bytes[self.at..].starts_with(word);
        if there {
            self.at += word.len();
        }
        there
    }

    fn value(&mut self, depth: usize) -> Option<Json> {
        if depth > 32 {
            return None;
        }
        self.space();
        match *self.bytes.get(self.at)? {
            b'{' => {
                self.at += 1;
                let mut pairs = Vec::new();
                self.space();
                if self.eat(b"}") {
                    return Some(Json::Map(pairs));
                }
                loop {
                    self.space();
                    let key = self.text()?;
                    self.space();
                    if !self.eat(b":") {
                        return None;
                    }
                    pairs.push((key, self.value(depth + 1)?));
                    self.space();
                    if self.eat(b"}") {
                        return Some(Json::Map(pairs));
                    }
                    if !self.eat(b",") {
                        return None;
                    }
                }
            }
            b'[' => {
                self.at += 1;
                let mut items = Vec::new();
                self.space();
                if self.eat(b"]") {
                    return Some(Json::List(items));
                }
                loop {
                    items.push(self.value(depth + 1)?);
                    self.space();
                    if self.eat(b"]") {
                        return Some(Json::List(items));
                    }
                    if !self.eat(b",") {
                        return None;
                    }
                }
            }
            b'"' => self.text().map(Json::Text),
            b't' => self.eat(b"true").then_some(Json::Bool(true)),
            b'f' => self.eat(b"false").then_some(Json::Bool(false)),
            b'n' => self.eat(b"null").then_some(Json::Null),
            _ => {
                let start = self.at;
                while matches!(
                    self.bytes.get(self.at),
                    Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
                ) {
                    self.at += 1;
                }
                let number = std::str::from_utf8(&self.bytes[start..self.at]).ok()?;
                number.parse().ok().map(Json::Number)
            }
        }
    }

    fn text(&mut self) -> Option<String> {
        if !self.eat(b"\"") {
            return None;
        }
        let mut out = Vec::new();
        loop {
            match *self.bytes.get(self.at)? {
                b'"' => {
                    self.at += 1;
                    return String::from_utf8(out).ok();
                }
                b'\\' => {
                    let escaped = *self.bytes.get(self.at + 1)?;
                    self.at += 2;
                    let c = match escaped {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let first = self.hex()?;
                            if (0xd800..0xdc00).contains(&first) {
                                if !self.eat(b"\\u") {
                                    return None;
                                }
                                let second = self.hex()?;
                                if !(0xdc00..0xe000).contains(&second) {
                                    return None;
                                }
                                char::from_u32(
                                    0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00),
                                )?
                            } else {
                                char::from_u32(first)?
                            }
                        }
                        _ => return None,
                    };
                    out.extend_from_slice(c.encode_utf8(&mut [0u8; 4]).as_bytes());
                }
                byte if byte < 0x20 => return None,
                byte => {
                    out.push(byte);
                    self.at += 1;
                }
            }
        }
    }

    fn hex(&mut self) -> Option<u32> {
        let digits = self.bytes.get(self.at..self.at + 4)?;
        if !digits.iter().all(u8::is_ascii_hexdigit) {
            return None;
        }
        self.at += 4;
        u32::from_str_radix(std::str::from_utf8(digits).ok()?, 16).ok()
    }
}

// -------------------------------------------------------------- the picker

/// A receiver as listed here, numbered in the order it first appeared.
#[derive(Debug, Clone, PartialEq)]
pub struct Listed {
    pub id: String,
    pub name: String,
    pub accepts: bool,
    /// In the daemon's last list.
    pub here: bool,
}

/// How a send ended, for the exit status; or that it never began, as AirDrop was on its way out
/// (`closing`), which is for the command to start again and ask again.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum End {
    Sent,
    NotSent,
    Again,
}

/// What a line of the daemon's, or one the user typed, comes to: words for the user (whole
/// lines, or a progress line drawn again in place), words for the daemon, and the end.
#[derive(Debug, Default, PartialEq)]
pub struct Step {
    pub say: String,
    pub tell: Option<String>,
    pub end: Option<End>,
}

/// What a name given with --to comes to among those listed.
enum Named {
    Nobody,
    One(Listed),
    More,
}

pub struct Picker {
    pub listed: Vec<Listed>,
    /// The name it was given (--to), to pick by itself.
    to: Option<String>,
    /// A receiver was picked: the list is over.
    picked: bool,
    began: Instant,
    hinted: bool,
    bluetooth_said: bool,
    /// Those named already as taking AirDrop from their contacts only.
    refusals_said: Vec<String>,
    /// Progress is drawn in place on a terminal; elsewhere, said once.
    terminal: bool,
    /// The progress line is on the screen, and wants ending.
    drawn: bool,
    sending_said: bool,
    opened: bool,
    /// What the last line said of AirDrop after the send: whether it stays on.
    pub stays: Option<bool>,
}

/// A name as people type it: no matter the case, or which apostrophe.
fn plain(name: &str) -> String {
    name.trim()
        .chars()
        .map(|c| match c {
            '\u{2018}' | '\u{2019}' | '\u{02bc}' => '\'',
            c => c,
        })
        .flat_map(char::to_lowercase)
        .collect()
}

fn quote(name: &str) -> String {
    if name.is_empty() {
        "the iPhone".into()
    } else {
        format!("“{name}”")
    }
}

impl Picker {
    pub fn new(to: Option<String>, terminal: bool, began: Instant) -> Picker {
        Picker {
            listed: Vec::new(),
            to,
            picked: false,
            began,
            hinted: false,
            bluetooth_said: false,
            refusals_said: Vec::new(),
            terminal,
            drawn: false,
            sending_said: false,
            opened: false,
            stays: None,
        }
    }

    /// What it says first: once, however many times the send is asked for.
    pub fn opening(&mut self) -> String {
        if std::mem::replace(&mut self.opened, true) {
            return String::new();
        }
        match &self.to {
            Some(name) => format!("Looking for {} nearby…\n", quote(name)),
            None => "Looking for iPhones nearby. Type the number of the one to send to, and \
                     press Enter.\n"
                .into(),
        }
    }

    /// What --to names among those listed: the one of that name, else the only one whose name
    /// begins so; or that more than one could be meant. A name is anybody's to give.
    fn named(&self) -> Named {
        let Some(wanted) = self.to.as_deref().map(plain) else {
            return Named::Nobody;
        };
        let here = || self.listed.iter().filter(|l| l.here);
        let exactly: Vec<&Listed> = here().filter(|l| plain(&l.name) == wanted).collect();
        let starting: Vec<&Listed> = here()
            .filter(|l| plain(&l.name).starts_with(&wanted))
            .collect();
        match (exactly.as_slice(), starting.as_slice()) {
            ([one], _) | ([], [one]) => Named::One((*one).clone()),
            ([], []) => Named::Nobody,
            _ => Named::More,
        }
    }

    fn line(&mut self, words: &str) -> String {
        let mut said = String::new();
        if self.drawn {
            said.push('\n');
            self.drawn = false;
        }
        said.push_str(words);
        said.push('\n');
        said
    }

    fn contacts_only(&mut self, name: &str) -> String {
        if self.refusals_said.iter().any(|n| n == name) {
            return String::new();
        }
        self.refusals_said.push(name.to_owned());
        self.line(&format!(
            "{} takes AirDrop from its contacts only. {EVERYONE}",
            quote(name)
        ))
    }

    /// A line of the daemon's.
    pub fn told(&mut self, line: &str) -> Step {
        let Some(said) = Json::parse(line) else {
            return Step::default();
        };
        let to = said.text("to").to_owned();
        let mut step = Step::default();
        if said.get("stays").is_some() {
            self.stays = Some(said.flag("stays"));
        }
        match said.text("state") {
            "closing" => step.end = Some(End::Again),
            "looking" => {
                for listed in &mut self.listed {
                    listed.here = false;
                }
                for receiver in said.list("receivers") {
                    let (id, name) = (receiver.text("id"), receiver.text("name"));
                    let accepts = receiver.flag("accepts");
                    let shown = match self.listed.iter().position(|l| l.id == id) {
                        Some(at) => {
                            let listed = &mut self.listed[at];
                            listed.here = true;
                            // One whose owner switched it to Everyone is listed again, without the note.
                            let changed = accepts && !listed.accepts;
                            listed.accepts = accepts;
                            changed.then_some(at)
                        }
                        None => {
                            self.listed.push(Listed {
                                id: id.into(),
                                name: name.into(),
                                accepts,
                                here: true,
                            });
                            Some(self.listed.len() - 1)
                        }
                    };
                    if let (Some(at), false) = (shown, self.picked) {
                        let note = if accepts {
                            ""
                        } else {
                            " (takes AirDrop from its contacts only)"
                        };
                        let words = format!("  {}. {}{note}", at + 1, self.listed[at].name);
                        step.say += &self.line(&words);
                    }
                }
                let bluetooth = said.text("bluetooth");
                if !bluetooth.is_empty() && !self.bluetooth_said {
                    self.bluetooth_said = true;
                    step.say += &self.line(bluetooth);
                }
                if !self.picked {
                    match self.named() {
                        Named::One(named) if named.accepts => {
                            self.picked = true;
                            step.tell = Some(format!("to {}", named.id));
                        }
                        Named::One(named) => step.say += &self.contacts_only(&named.name),
                        // Not picked for the user: which is theirs is theirs to say, by number.
                        Named::More => {
                            let name = self.to.take().unwrap_or_default();
                            step.say += &self.line(&format!(
                                "More than one iPhone nearby goes by {}: type the number of yours.",
                                quote(&name)
                            ));
                        }
                        Named::Nobody => {}
                    }
                }
            }
            "asking" => {
                self.picked = true;
                step.say = self.line(&format!("Waiting for {} to accept…", quote(&to)));
            }
            "sending" => {
                let (sent, bytes) = (said.number("sent"), said.number("bytes"));
                if self.terminal {
                    let share = if bytes > 0.0 {
                        (sent / bytes * 100.0).clamp(0.0, 100.0) as u32
                    } else {
                        0
                    };
                    step.say = format!(
                        "\r\x1b[KSending to {}: {share}% of {}",
                        quote(&to),
                        size(bytes as u64)
                    );
                    self.drawn = true;
                } else if !self.sending_said {
                    self.sending_said = true;
                    step.say = self.line(&format!("Sending to {}…", quote(&to)));
                }
            }
            "sent" => {
                step.say = self.line(&format!("Sent to {}.", quote(&to)));
                step.end = Some(End::Sent);
            }
            "declined" => {
                step.say = self.line(&format!("{} declined.", quote(&to)));
                step.end = Some(End::NotSent);
            }
            "failed" => {
                step.say = self.line(said.text("why"));
                step.end = Some(End::NotSent);
            }
            "nobody" => {
                step.say = self.line("No one nearby.");
                for name in said.list("refused") {
                    if let Json::Text(name) = name {
                        let name = name.clone();
                        step.say += &self.contacts_only(&name);
                    }
                }
                if said.list("refused").is_empty() {
                    step.say += &self.line(EVERYONE);
                }
                step.end = Some(End::NotSent);
            }
            "cancelled" => {
                step.say = self.line("Cancelled.");
                step.end = Some(End::NotSent);
            }
            _ => {}
        }
        step
    }

    /// A line the user typed: the number of a receiver.
    pub fn typed(&mut self, words: &str) -> Step {
        let words = words.trim();
        if self.picked || words.is_empty() {
            return Step::default();
        }
        let at = words.parse::<usize>().ok().and_then(|n| n.checked_sub(1));
        let Some(listed) = at.and_then(|at| self.listed.get(at)).cloned() else {
            return Step {
                say: self.line("Type the number of one of those listed."),
                ..Step::default()
            };
        };
        if !listed.here {
            return Step {
                say: self.line(&format!("{} is not nearby any more.", quote(&listed.name))),
                ..Step::default()
            };
        }
        if !listed.accepts {
            self.refusals_said.retain(|n| n != &listed.name);
            return Step {
                say: self.contacts_only(&listed.name),
                ..Step::default()
            };
        }
        self.picked = true;
        Step {
            tell: Some(format!("to {}", listed.id)),
            ..Step::default()
        }
    }

    /// Time going by: once, a while into looking with nobody to send to, what the iPhone needs.
    pub fn tick(&mut self, now: Instant) -> String {
        if self.picked || self.hinted || now < self.began + HINT_AFTER {
            return String::new();
        }
        let wanted = match &self.to {
            Some(name) if matches!(self.named(), Named::Nobody) => quote(name),
            Some(_) => return String::new(),
            None if self.listed.iter().any(|l| l.here && l.accepts) => return String::new(),
            None => "an iPhone".into(),
        };
        self.hinted = true;
        self.line(&format!("No sign of {wanted} yet. {EVERYONE}"))
    }
}

/// A send at the command line, from the daemon's first line to its last: the receivers listed
/// as they appear, what the user types (`typed`, a line at a time) taken as a pick, and how it
/// ends, said to `out`.
pub fn converse(
    stream: &UnixStream,
    picker: &mut Picker,
    typed: &mpsc::Receiver<String>,
    out: &mut dyn Write,
) -> End {
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
    let Ok(clone) = stream.try_clone() else {
        let _ = out.write_all(WENT_OFF.as_bytes());
        return End::NotSent;
    };
    let mut reader = BufReader::new(clone);
    let mut writer = stream;
    let say = |out: &mut dyn Write, words: &str| {
        let _ = out.write_all(words.as_bytes()).and_then(|_| out.flush());
    };
    say(out, &picker.opening());
    let mut line = Vec::new();
    loop {
        let read = reader.read_until(b'\n', &mut line);
        match read {
            Ok(0) => {
                let words = picker.line(WENT_OFF);
                say(out, &words);
                return End::NotSent;
            }
            Ok(_) => {
                let text = String::from_utf8_lossy(&line).trim_end().to_owned();
                line.clear();
                let step = picker.told(&text);
                say(out, &step.say);
                if let Some(words) = step.tell {
                    let _ = writeln!(writer, "{words}");
                }
                if let Some(end) = step.end {
                    return end;
                }
            }
            // A part of a line stays in `line` for the rest of it.
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(_) => {
                let words = picker.line(WENT_OFF);
                say(out, &words);
                return End::NotSent;
            }
        }
        while let Ok(words) = typed.try_recv() {
            let step = picker.typed(&words);
            say(out, &step.say);
            if let Some(words) = step.tell {
                let _ = writeln!(writer, "{words}");
            }
        }
        let hint = picker.tick(Instant::now());
        say(out, &hint);
    }
}

/// The daemon's lines as they are, for the shell; and one more should they end without an end.
pub fn pass_on(stream: &UnixStream, out: &mut dyn Write) -> End {
    let mut lines = BufReader::new(stream).lines();
    loop {
        let Some(Ok(line)) = lines.next() else {
            let _ = writeln!(
                out,
                r#"{{"state":"failed","why":{}}}"#,
                crate::meet::quoted(WENT_OFF)
            );
            let _ = out.flush();
            return End::NotSent;
        };
        let state = Json::parse(&line).map(|said| said.text("state").to_owned());
        // Not one of the send's lines: for the command to ask again.
        if state.as_deref() == Some("closing") {
            return End::Again;
        }
        if writeln!(out, "{line}").and_then(|_| out.flush()).is_err() {
            // Nobody reads it any more: the send is not theirs to see through.
            let _ = (&*stream).write_all(b"cancel\n");
        }
        match state.as_deref() {
            Some("sent") => return End::Sent,
            Some("declined" | "failed" | "nobody" | "cancelled") => return End::NotSent,
            _ => {}
        }
    }
}

/// What the shell may say on to the daemon in a send: a pick, or stop.
pub fn passable(words: &str) -> bool {
    words == "cancel"
        || words
            .strip_prefix("to ")
            .is_some_and(|id| !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const LOOKING: &str = r#"{"state":"looking","receivers":[{"id":"1","name":"Zoë’s iPhone","model":"iPhone15,2","accepts":true},{"id":"2","name":"Bob","model":"","accepts":false}],"bluetooth":""}"#;

    #[test]
    fn its_json_reads_what_the_daemon_writes() {
        let said = Json::parse(LOOKING).unwrap();
        assert_eq!(said.text("state"), "looking");
        assert_eq!(said.list("receivers")[0].text("name"), "Zoë’s iPhone");
        assert!(!said.list("receivers")[1].flag("accepts"));
        let escaped = Json::parse(r#"{"why":"a \"b\"\né😀\/","n":12.5,"x":null,"l":[]}"#).unwrap();
        assert_eq!(escaped.text("why"), "a \"b\"\né😀/");
        assert_eq!(escaped.number("n"), 12.5);
        assert_eq!(escaped.get("x"), Some(&Json::Null));
        // What is not JSON, or more than one value, is nothing.
        for broken in [
            "",
            "{",
            r#"{"a":}"#,
            r#"{"a":1} x"#,
            r#""\ud83d""#,
            r#""\u12g4""#,
            "\"a\nb\"",
        ] {
            assert_eq!(Json::parse(broken), None, "{broken:?}");
        }
        let deep = "[".repeat(40) + &"]".repeat(40);
        assert_eq!(Json::parse(&deep), None);
    }

    #[test]
    fn receivers_are_numbered_as_they_appear_and_picked_by_number() {
        let began = Instant::now();
        let mut picker = Picker::new(None, false, began);
        let step = picker.told(LOOKING);
        assert_eq!(
            step.say,
            "  1. Zoë’s iPhone\n  2. Bob (takes AirDrop from its contacts only)\n"
        );
        assert_eq!(step.tell, None);
        // Listed again, nothing is said again.
        assert_eq!(picker.told(LOOKING), Step::default());
        assert_eq!(
            picker.typed("7").say,
            "Type the number of one of those listed.\n"
        );
        assert_eq!(
            picker.typed("2").say,
            format!("“Bob” takes AirDrop from its contacts only. {EVERYONE}\n")
        );
        // Bob's owner chose Everyone: Bob is listed anew, and can be picked.
        let everyone = LOOKING.replace("false", "true");
        assert_eq!(picker.told(&everyone).say, "  2. Bob\n");
        // Zoë's went away.
        let gone = r#"{"state":"looking","receivers":[{"id":"2","name":"Bob","model":"","accepts":true}],"bluetooth":""}"#;
        picker.told(gone);
        assert_eq!(
            picker.typed("1").say,
            "“Zoë’s iPhone” is not nearby any more.\n"
        );
        assert_eq!(picker.typed("2").tell.as_deref(), Some("to 2"));
        // Picked: the rest of what is typed is nobody's business.
        assert_eq!(picker.typed("1"), Step::default());
        assert_eq!(
            picker.told(r#"{"state":"asking","to":"Bob"}"#).say,
            "Waiting for “Bob” to accept…\n"
        );
        let sending = r#"{"state":"sending","to":"Bob","sent":500000,"bytes":2000000}"#;
        assert_eq!(picker.told(sending).say, "Sending to “Bob”…\n");
        assert_eq!(picker.told(sending).say, "");
        let sent = picker.told(r#"{"state":"sent","to":"Bob","bytes":2000000,"seconds":3}"#);
        assert_eq!(
            (sent.say.as_str(), sent.end),
            ("Sent to “Bob”.\n", Some(End::Sent))
        );
    }

    #[test]
    fn on_a_terminal_the_progress_is_drawn_in_place() {
        let mut picker = Picker::new(None, true, Instant::now());
        let sending = r#"{"state":"sending","to":"Bob","sent":500000,"bytes":2000000}"#;
        assert_eq!(
            picker.told(sending).say,
            "\r\x1b[KSending to “Bob”: 25% of 2.0 MB"
        );
        let declined = picker.told(r#"{"state":"declined","to":"Bob"}"#);
        assert_eq!(declined.say, "\n“Bob” declined.\n");
        assert_eq!(declined.end, Some(End::NotSent));
    }

    #[test]
    fn a_name_given_picks_by_itself_whatever_the_apostrophe_and_case() {
        let began = Instant::now();
        let mut picker = Picker::new(Some("zoë's iphone".into()), false, began);
        assert_eq!(picker.opening(), "Looking for “zoë's iphone” nearby…\n");
        assert_eq!(picker.told(LOOKING).tell.as_deref(), Some("to 1"));
        // A beginning that is one name's only, too; none that is two names', which is said.
        let mut picker = Picker::new(Some("zo".into()), false, began);
        assert_eq!(picker.told(LOOKING).tell.as_deref(), Some("to 1"));
        let two = LOOKING.replace("\"Bob\"", "\"Zoe's iPad\"");
        let mut picker = Picker::new(Some("zo".into()), false, began);
        let step = picker.told(&two);
        assert_eq!(step.tell, None);
        assert!(step
            .say
            .ends_with("More than one iPhone nearby goes by “zo”: type the number of yours.\n"));
        // Two of the very name, as another device may call itself: neither is picked for the
        // user, who picks by number, whichever came first.
        let twins = LOOKING
            .replace("\"Bob\"", "\"zoë’s iPhone\"")
            .replace("false", "true");
        let mut picker = Picker::new(Some("Zoë's iPhone".into()), false, began);
        let step = picker.told(&twins);
        assert_eq!(step.tell, None);
        assert!(step
            .say
            .contains("More than one iPhone nearby goes by “Zoë's iPhone”"));
        assert_eq!(picker.typed("2").tell.as_deref(), Some("to 2"));
        // One listed first, and its twin after: by then the first was picked, as it was alone.
        let mut picker = Picker::new(Some("Zoë's iPhone".into()), false, began);
        let one = r#"{"state":"looking","receivers":[{"id":"1","name":"Zoë’s iPhone","model":"","accepts":true}],"bluetooth":""}"#;
        assert_eq!(picker.told(one).tell.as_deref(), Some("to 1"));
        // One that takes AirDrop from its contacts only is waited for, and said so once.
        let mut picker = Picker::new(Some("Bob".into()), false, began);
        let step = picker.told(LOOKING);
        assert_eq!(step.tell, None);
        assert!(step.say.ends_with(&format!(
            "“Bob” takes AirDrop from its contacts only. {EVERYONE}\n"
        )));
        assert!(!picker.told(LOOKING).say.contains("contacts"));
        assert_eq!(
            picker
                .told(&LOOKING.replace("false", "true"))
                .tell
                .as_deref(),
            Some("to 2")
        );
    }

    #[test]
    fn a_while_with_nobody_says_what_the_iphone_needs_once() {
        let began = Instant::now();
        let mut picker = Picker::new(None, false, began);
        assert_eq!(picker.tick(began + Duration::from_secs(3)), "");
        let later = began + HINT_AFTER;
        assert_eq!(
            picker.tick(later),
            format!("No sign of an iPhone yet. {EVERYONE}\n")
        );
        assert_eq!(picker.tick(later), "");
        // With one to send to, nothing.
        let mut picker = Picker::new(None, false, began);
        picker.told(LOOKING);
        assert_eq!(picker.tick(later), "");
        // A name not seen is the one waited for.
        let mut picker = Picker::new(Some("Ann".into()), false, began);
        picker.told(LOOKING);
        assert_eq!(
            picker.tick(later),
            format!("No sign of “Ann” yet. {EVERYONE}\n")
        );
        // Bluetooth that cannot wake an iPhone is said, once.
        let mut picker = Picker::new(None, false, began);
        let off = r#"{"state":"looking","receivers":[],"bluetooth":"Bluetooth is off."}"#;
        assert_eq!(picker.told(off).say, "Bluetooth is off.\n");
        assert_eq!(picker.told(off).say, "");
    }

    #[test]
    fn the_ends_in_plain_words() {
        let mut picker = Picker::new(None, false, Instant::now());
        let nobody = picker.told(r#"{"state":"nobody","refused":[]}"#);
        assert_eq!(nobody.say, format!("No one nearby.\n{EVERYONE}\n"));
        let mut picker = Picker::new(None, false, Instant::now());
        let refused = picker.told(r#"{"state":"nobody","refused":["Bob"]}"#);
        assert_eq!(
            refused.say,
            format!("No one nearby.\n“Bob” takes AirDrop from its contacts only. {EVERYONE}\n")
        );
        let failed = picker.told(r#"{"state":"failed","why":"“Bob” could not be reached."}"#);
        assert_eq!(
            (failed.say.as_str(), failed.end),
            ("“Bob” could not be reached.\n", Some(End::NotSent))
        );
        assert_eq!(picker.told(r#"{"state":"cancelled"}"#).say, "Cancelled.\n");
        assert_eq!(picker.told("not json"), Step::default());
        // The last line says whether AirDrop stays on after the send.
        assert_eq!(picker.stays, None);
        picker.told(r#"{"state":"cancelled","stays":true}"#);
        assert_eq!(picker.stays, Some(true));
        picker.told(r#"{"state":"declined","to":"Bob","stays":false}"#);
        assert_eq!(picker.stays, Some(false));
    }

    #[test]
    fn a_daemon_on_its_way_out_is_asked_again_with_nothing_said_twice() {
        let mut picker = Picker::new(None, false, Instant::now());
        assert!(picker.opening().starts_with("Looking for iPhones nearby."));
        let closing = picker.told(r#"{"state":"closing"}"#);
        assert_eq!((closing.say.as_str(), closing.end), ("", Some(End::Again)));
        // Asked of the next daemon, it does not say it looks a second time.
        assert_eq!(picker.opening(), "");
        let (ours, mut daemon) = UnixStream::pair().unwrap();
        writeln!(daemon, r#"{{"state":"closing"}}"#).unwrap();
        let mut out = Vec::new();
        assert_eq!(pass_on(&ours, &mut out), End::Again);
        assert!(out.is_empty(), "the shell is not told of it");
    }

    #[test]
    fn a_conversation_with_the_daemon_from_its_first_line_to_its_last() {
        let (ours, mut daemon) = UnixStream::pair().unwrap();
        let (typing, typed) = mpsc::channel();
        let talk = std::thread::spawn(move || {
            let mut picker = Picker::new(None, false, Instant::now());
            let mut out = Vec::new();
            let end = converse(&ours, &mut picker, &typed, &mut out);
            (end, String::from_utf8(out).unwrap())
        });
        writeln!(daemon, "{LOOKING}").unwrap();
        // Half a line, then the rest, a moment later: read as one.
        daemon
            .write_all(br#"{"state":"looking","receivers":[{"id":"1","name":"Zo"#)
            .unwrap();
        std::thread::sleep(Duration::from_millis(300));
        daemon
            .write_all(
                "ë’s iPhone\",\"model\":\"\",\"accepts\":true}],\"bluetooth\":\"\"}\n".as_bytes(),
            )
            .unwrap();
        typing.send("1".to_owned()).unwrap();
        let mut asked = String::new();
        BufReader::new(&daemon).read_line(&mut asked).unwrap();
        assert_eq!(asked, "to 1\n");
        writeln!(daemon, r#"{{"state":"asking","to":"Zoë’s iPhone"}}"#).unwrap();
        writeln!(
            daemon,
            r#"{{"state":"sent","to":"Zoë’s iPhone","bytes":3,"seconds":1}}"#
        )
        .unwrap();
        let (end, said) = talk.join().unwrap();
        assert_eq!(end, End::Sent);
        assert!(said.starts_with("Looking for iPhones nearby."));
        assert!(said.ends_with(
            "  1. Zoë’s iPhone\n  2. Bob (takes AirDrop from its contacts only)\n\
             Waiting for “Zoë’s iPhone” to accept…\nSent to “Zoë’s iPhone”.\n"
        ));

        // A daemon that goes without a last word.
        let (ours, daemon) = UnixStream::pair().unwrap();
        drop(daemon);
        let (_typing, typed) = mpsc::channel();
        let mut out = Vec::new();
        let mut picker = Picker::new(None, false, Instant::now());
        assert_eq!(converse(&ours, &mut picker, &typed, &mut out), End::NotSent);
        assert!(String::from_utf8(out)
            .unwrap()
            .ends_with(&format!("{WENT_OFF}\n")));
    }

    #[test]
    fn for_the_shell_the_lines_go_on_as_they_are() {
        let (ours, mut daemon) = UnixStream::pair().unwrap();
        writeln!(daemon, "{LOOKING}").unwrap();
        writeln!(daemon, r#"{{"state":"declined","to":"Bob"}}"#).unwrap();
        let mut out = Vec::new();
        assert_eq!(pass_on(&ours, &mut out), End::NotSent);
        assert_eq!(
            String::from_utf8(out).unwrap(),
            format!("{LOOKING}\n{{\"state\":\"declined\",\"to\":\"Bob\"}}\n")
        );
        let (ours, mut daemon) = UnixStream::pair().unwrap();
        writeln!(daemon, "{LOOKING}").unwrap();
        drop(daemon);
        let mut out = Vec::new();
        assert_eq!(pass_on(&ours, &mut out), End::NotSent);
        assert!(String::from_utf8(out).unwrap().ends_with(
            "{\"state\":\"failed\",\"why\":\"AirDrop went off before anything was sent.\"}\n"
        ));
        assert!(passable("to 12") && passable("cancel"));
        for not in ["to ", "to 1\nstop", "to x", "stop", "cancel please"] {
            assert!(!passable(not), "{not:?}");
        }
    }
}
