//! nova-pinentry: gpg-agent's questions on Nova's card, for gpg and all that
//! goes through gpg-agent (git's signing, pass): a key's passphrase, a new
//! one twice, a yes or no, a message.
//!
//! gpg-agent runs a pinentry and speaks Assuan to it on its standard input
//! and output, a command a line ("SETDESC ...", "GETPIN"), each answered with
//! "OK", data ("D ..."), or "ERR <code> <words>". Arch's /usr/bin/pinentry
//! reads /etc/pinentry/preexec before it chooses one; Nova's runs this one
//! while a Nova shell listens for questions, and this one hands over to the
//! usual pinentry (NOVA_PINENTRY=off) when no shell answers.
//!
//! One card for a run: a wrong passphrase is gpg-agent's SETERROR and GETPIN
//! again on the same pinentry, which the card shakes for and asks again.
//! What is typed goes to gpg-agent and nowhere else, percent-escaped as
//! Assuan has it, and is zeroed after.

use std::io::{self, BufRead, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::common::Context;
use crate::prompt::{self, Ask, Dialog, Field, Glyph};

/// gpg-error's codes, from the pinentry's source (5): the code is
/// source << 24 | error.
const CANCELED: &str = "ERR 83886179 Operation cancelled <Pinentry>";
const NOT_CONFIRMED: &str = "ERR 83886194 Not confirmed <Pinentry>";
const TIMEOUT: &str = "ERR 83886142 Timeout <Pinentry>";
const UNKNOWN: &str = "ERR 83886355 Unknown IPC command <Pinentry>";
/// An Assuan line is 1000 bytes at most, its "D " and newline in them.
const DATA_LINE: usize = 900;

/// What gpg-agent said the next question is to say.
#[derive(Default, Debug, Clone)]
struct Words {
    title: String,
    description: String,
    prompt: String,
    ok: String,
    cancel: String,
    not_ok: String,
    error: String,
    repeat: Option<String>,
    repeat_error: String,
    timeout: u64,
}

fn hex(byte: u8) -> Option<u8> {
    (byte as char).to_digit(16).map(|d| d as u8)
}

/// "%25" and the like as the bytes they stand for, as Assuan escapes them.
fn unescape(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 3 <= bytes.len() {
            if let (Some(high), Some(low)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(high << 4 | low);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Data for a "D" line: %, CR and LF escaped.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '%' => out.push_str("%25"),
            '\r' => out.push_str("%0D"),
            '\n' => out.push_str("%0A"),
            c => out.push(c),
        }
    }
    out
}

/// gpg's words for a card: a line or two, its quotes kept, its blank lines
/// gone.
fn tidy(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// The prompt's label without its colon: "Passphrase:" is "Passphrase".
fn label(prompt: &str, otherwise: &str) -> String {
    let words = prompt.trim().trim_end_matches(':').trim();
    if words.is_empty() {
        otherwise.to_owned()
    } else {
        words.to_owned()
    }
}

struct Pinentry<'a, W: Write> {
    ctx: &'a Context,
    out: W,
    words: Words,
    /// The card, while one is up.
    dialog: Option<Dialog>,
    /// Whether the card's last answer is with gpg-agent: its next GETPIN is
    /// the answer said wrong.
    answered: bool,
}

impl<W: Write> Pinentry<'_, W> {
    fn say(&mut self, line: &str) -> io::Result<()> {
        writeln!(self.out, "{line}")?;
        self.out.flush()
    }

    fn data(&mut self, text: &str) -> io::Result<()> {
        let mut line = escape(text);
        let mut rest = line.as_str();
        while !rest.is_empty() {
            let mut cut = rest.len().min(DATA_LINE);
            while !rest.is_char_boundary(cut) {
                cut -= 1;
            }
            // Never through a %XX.
            if let Some(at) = rest[..cut].rfind('%') {
                if at + 3 > cut && at > 0 {
                    cut = at;
                }
            }
            let (now, later) = rest.split_at(cut);
            writeln!(self.out, "D {now}")?;
            rest = later;
        }
        // SAFETY: zeroes are valid UTF-8.
        unsafe { line.as_bytes_mut().fill(0) };
        self.out.flush()
    }

    fn ask(&self) -> Ask {
        let w = &self.words;
        let mut ask = Ask::new(
            Glyph::Key,
            if w.title.is_empty() {
                "Passphrase"
            } else {
                &w.title
            },
        );
        ask.text = tidy(&w.description);
        ask.accept = if w.ok.is_empty() {
            "OK".into()
        } else {
            label(&w.ok, "OK")
        };
        ask.cancel = label(&w.cancel, "");
        ask
    }

    /// The card for <ask>: the one up, asked again, or a new one.
    fn show(&mut self, ask: &Ask) -> io::Result<()> {
        if let Some(dialog) = self.dialog.as_mut() {
            if dialog.ask(ask).is_ok() {
                return Ok(());
            }
        }
        self.dialog = Some(Dialog::open(self.ctx, ask)?);
        Ok(())
    }

    /// The card's answer, or none: cancelled, or gone. Past <timeout>
    /// seconds the card goes and the answer is a timeout.
    fn wait(&mut self) -> (Option<prompt::Values>, bool) {
        let Some(dialog) = self.dialog.as_mut() else {
            return (None, false);
        };
        let late = Arc::new(AtomicBool::new(false));
        let answered = Arc::new(AtomicBool::new(false));
        if self.words.timeout > 0 {
            if let Ok(ender) = dialog.ender() {
                let (late, answered, seconds) =
                    (late.clone(), answered.clone(), self.words.timeout);
                thread::spawn(move || {
                    thread::sleep(Duration::from_secs(seconds));
                    if !answered.load(Ordering::SeqCst) {
                        late.store(true, Ordering::SeqCst);
                        ender.end();
                    }
                });
            }
        }
        let answer = dialog.answer();
        answered.store(true, Ordering::SeqCst);
        if answer.is_none() {
            // Cancelled, or ended: the card is gone either way.
            self.dialog = None;
        }
        (answer, late.load(Ordering::SeqCst))
    }

    fn getpin(&mut self) -> io::Result<()> {
        let mut ask = self.ask();
        ask.fields.push(Field::secret(
            "pin",
            &label(&self.words.prompt, "Passphrase"),
        ));
        if let Some(repeat) = &self.words.repeat {
            ask.fields
                .push(Field::secret("again", &label(repeat, "Again")));
        }
        // A wrong one: the card that is up says so, and is answered again.
        let error = tidy(&self.words.error);
        if self.answered && self.dialog.is_some() && !error.is_empty() {
            let dialog = self.dialog.as_mut().expect("a card");
            if dialog.wrong(&error).is_err() {
                self.dialog = None;
            }
        }
        if !(self.answered && self.dialog.is_some()) {
            if !error.is_empty() {
                ask.text = if ask.text.is_empty() {
                    error.clone()
                } else {
                    format!("{error}\n{}", ask.text)
                };
            }
            if let Err(e) = self.show(&ask) {
                eprintln!("nova-pinentry: no card to ask on ({e})");
                return self.say(CANCELED);
            }
        }
        self.answered = false;
        loop {
            let (answer, late) = self.wait();
            let Some(mut values) = answer else {
                return self.say(if late { TIMEOUT } else { CANCELED });
            };
            let mut pin = values.remove("pin").unwrap_or_default();
            let mut again = values.remove("again").unwrap_or_default();
            if self.words.repeat.is_some() && pin != again {
                let words = tidy(&self.words.repeat_error);
                let words = if words.is_empty() {
                    "The passphrases do not match.".to_owned()
                } else {
                    words
                };
                // SAFETY: zeroes are valid UTF-8.
                unsafe {
                    pin.as_bytes_mut().fill(0);
                    again.as_bytes_mut().fill(0);
                }
                if self
                    .dialog
                    .as_mut()
                    .is_some_and(|d| d.wrong(&words).is_ok())
                {
                    continue;
                }
                return self.say(CANCELED);
            }
            if self.words.repeat.is_some() {
                self.say("S PIN_REPEATED")?;
            }
            let sent = self.data(&pin).and_then(|()| self.say("OK"));
            // SAFETY: zeroes are valid UTF-8.
            unsafe {
                pin.as_bytes_mut().fill(0);
                again.as_bytes_mut().fill(0);
            }
            self.answered = true;
            return sent;
        }
    }

    /// A yes or no; <alone>, a message with its one answer.
    fn confirm(&mut self, alone: bool) -> io::Result<()> {
        let mut ask = self.ask();
        ask.alone = alone;
        if !alone && !self.words.not_ok.is_empty() {
            ask.cancel = label(&self.words.not_ok, "No");
        }
        let error = tidy(&self.words.error);
        if !error.is_empty() {
            ask.text = if ask.text.is_empty() {
                error
            } else {
                format!("{error}\n{}", ask.text)
            };
        }
        if let Err(e) = self.show(&ask) {
            eprintln!("nova-pinentry: no card to ask on ({e})");
            return self.say(CANCELED);
        }
        let (answer, late) = self.wait();
        // Asked and answered: the next question is a card of its own.
        if let Some(dialog) = self.dialog.take() {
            dialog.done();
        }
        self.answered = false;
        match answer {
            Some(_) => self.say("OK"),
            None if late => self.say(TIMEOUT),
            None if alone => self.say("OK"),
            None if !self.words.not_ok.is_empty() => self.say(NOT_CONFIRMED),
            None => self.say(CANCELED),
        }
    }

    /// One command; false once it is BYE.
    fn command(&mut self, line: &str) -> io::Result<bool> {
        let (name, rest) = line.split_once(' ').unwrap_or((line, ""));
        let text = unescape(rest);
        let w = &mut self.words;
        match name.to_ascii_uppercase().as_str() {
            "SETTITLE" => w.title = text,
            "SETDESC" => w.description = text,
            "SETPROMPT" => w.prompt = text,
            "SETOK" => w.ok = text,
            "SETCANCEL" => w.cancel = text,
            "SETNOTOK" => w.not_ok = text,
            "SETERROR" => w.error = text,
            "SETREPEAT" => {
                w.repeat = Some(if text.is_empty() {
                    "Again".into()
                } else {
                    text
                })
            }
            "SETREPEATERROR" => w.repeat_error = text,
            "SETTIMEOUT" => w.timeout = text.trim().parse().unwrap_or(0),
            // What the card has no place for: a quality bar, a key's grip, a
            // generated passphrase, the agent's options.
            "OPTION" | "SETKEYINFO" | "SETQUALITYBAR" | "SETQUALITYBAR_TT" | "SETGENPIN"
            | "SETGENPIN_TT" | "SETREPEATOK" | "SETCONSTRAINTS" | "NOP" => {}
            "RESET" => self.words = Words::default(),
            "GETINFO" => {
                let answer = match text.trim() {
                    "version" => Some("1.3.1".to_owned()),
                    "pid" => Some(std::process::id().to_string()),
                    "flavor" => Some("nova".to_owned()),
                    "ttyinfo" => Some("- - - - 0/0 -".to_owned()),
                    _ => None,
                };
                if let Some(answer) = answer {
                    self.data(&answer)?;
                }
            }
            "GETPIN" => {
                self.getpin()?;
                self.words.error.clear();
                return Ok(true);
            }
            "CONFIRM" => {
                self.confirm(text.trim() == "--one-button")?;
                self.words.error.clear();
                return Ok(true);
            }
            "MESSAGE" => {
                self.confirm(true)?;
                self.words.error.clear();
                return Ok(true);
            }
            "BYE" => {
                self.say("OK closing connection")?;
                return Ok(false);
            }
            "" => return Ok(true),
            _ => {
                self.say(UNKNOWN)?;
                return Ok(true);
            }
        }
        self.say("OK")?;
        Ok(true)
    }
}

/// The conversation with gpg-agent on <input> and <output>, until BYE or
/// the end of its input; the card goes with it.
pub fn serve(ctx: &Context, input: impl BufRead, output: impl Write) -> io::Result<()> {
    let mut pinentry = Pinentry {
        ctx,
        out: output,
        words: Words::default(),
        dialog: None,
        answered: false,
    };
    pinentry.say("OK Pleased to meet you")?;
    for line in input.lines() {
        let line = line?;
        if !pinentry.command(line.trim_end_matches('\r'))? {
            break;
        }
    }
    if let Some(dialog) = pinentry.dialog.take() {
        dialog.done();
    }
    Ok(())
}

/// Whether a shell listens for questions: a connection that asks nothing is
/// none to it.
fn shell_listens(ctx: &Context) -> bool {
    UnixStream::connect(ctx.runtime.join(prompt::SOCKET)).is_ok()
}

/// The usual pinentry, as Arch chooses it, told not to come back here.
fn hand_over() -> i32 {
    use std::os::unix::process::CommandExt;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let error = std::process::Command::new("/usr/bin/pinentry")
        .args(args)
        .env("NOVA_PINENTRY", "off")
        .exec();
    eprintln!("nova-pinentry: could not run /usr/bin/pinentry: {error}");
    1
}

pub fn main() -> i32 {
    let ctx = match Context::from_env() {
        Ok(ctx) if shell_listens(&ctx) => ctx,
        _ => return hand_over(),
    };
    let stdin = io::stdin();
    match serve(&ctx, stdin.lock(), io::stdout()) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("nova-pinentry: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prompt::fake::Card;
    use crate::testing::context;
    use nova_sd::testing::scratch;

    fn talk(ctx: &Context, lines: &[&str]) -> Vec<String> {
        let input = lines.join("\n") + "\n";
        let mut out = Vec::new();
        serve(ctx, input.as_bytes(), &mut out).unwrap();
        String::from_utf8(out)
            .unwrap()
            .lines()
            .map(String::from)
            .collect()
    }

    #[test]
    fn escaping_both_ways_is_assuans() {
        assert_eq!(unescape("a%0Ab%25c%2"), "a\nb%c%2");
        assert_eq!(escape("50% of\r\nit"), "50%25 of%0D%0Ait");
        assert_eq!(label("Passphrase:", "x"), "Passphrase");
        assert_eq!(label("  ", "x"), "x");
        assert_eq!(
            tidy("Please enter\n\n  \"Ann <a@b>\"\n"),
            "Please enter\n\"Ann <a@b>\""
        );
    }

    #[test]
    fn a_passphrase_asked_said_wrong_and_asked_again_on_one_card() {
        let dir = scratch("pinentry");
        let ctx = context(&dir);
        let card = Card::listen(
            &ctx.runtime,
            &[Some(r#"{"pin":"bad"}"#), Some(r#"{"pin":"50% right\n"}"#)],
        );
        let said = talk(
            &ctx,
            &[
                "OPTION ttyname=/dev/pts/1",
                "GETINFO version",
                "SETKEYINFO n/ABCDEF",
                "SETDESC Please enter the passphrase to unlock the OpenPGP secret key:%0A%22Ann <a@b>%22%0A",
                "SETPROMPT Passphrase:",
                "GETPIN",
                "SETERROR Bad Passphrase (try 2 of 3)",
                "GETPIN",
                "BYE",
            ],
        );
        assert_eq!(
            said,
            [
                "OK Pleased to meet you",
                "OK",
                "D 1.3.1",
                "OK",
                "OK",
                "OK",
                "OK",
                "D bad",
                "OK",
                "OK",
                "D 50%25 right%0A",
                "OK",
                "OK closing connection"
            ]
        );
        let lines = card.lines();
        assert!(lines.iter().all(|(n, _)| *n == 0), "one card: {lines:?}");
        assert!(lines[0].1.contains(r#""glyph":"key""#));
        assert!(lines[0].1.contains(r#""text":"Please enter the passphrase to unlock the OpenPGP secret key:\n\"Ann <a@b>\"""#));
        assert!(lines[0]
            .1
            .contains(r#"{"id":"pin","label":"Passphrase","secret":true,"value":""}"#));
        assert_eq!(
            lines[1].1,
            r#"{"type":"wrong","text":"Bad Passphrase (try 2 of 3)"}"#
        );
        assert_eq!(lines[2].1, r#"{"type":"done"}"#);
    }

    #[test]
    fn cancelled_is_gpgs_cancel_and_the_next_question_is_a_new_card() {
        let dir = scratch("pinentry");
        let ctx = context(&dir);
        let card = Card::listen(&ctx.runtime, &[Some("cancel"), Some(r#"{"pin":"x"}"#)]);
        let said = talk(&ctx, &["GETPIN", "GETPIN", "BYE"]);
        assert_eq!(said[1], CANCELED);
        assert_eq!(&said[2..], ["D x", "OK", "OK closing connection"]);
        assert!(card.lines().iter().any(|(n, _)| *n == 1));
    }

    #[test]
    fn a_new_passphrase_twice_must_match() {
        let dir = scratch("pinentry");
        let ctx = context(&dir);
        let card = Card::listen(
            &ctx.runtime,
            &[
                Some(r#"{"pin":"a","again":"b"}"#),
                Some(r#"{"pin":"a","again":"a"}"#),
            ],
        );
        let said = talk(
            &ctx,
            &[
                "SETREPEAT Repeat:",
                "SETREPEATERROR does not match - try again",
                "GETPIN",
                "BYE",
            ],
        );
        assert_eq!(
            &said[3..],
            ["S PIN_REPEATED", "D a", "OK", "OK closing connection"]
        );
        let lines = card.lines();
        assert!(lines[0]
            .1
            .contains(r#"{"id":"again","label":"Repeat","secret":true,"value":""}"#));
        assert_eq!(
            lines[1].1,
            r#"{"type":"wrong","text":"does not match - try again"}"#
        );
    }

    #[test]
    fn a_yes_or_no_and_a_message() {
        let dir = scratch("pinentry");
        let ctx = context(&dir);
        let _card = Card::listen(
            &ctx.runtime,
            &[Some("{}"), Some("cancel"), Some("cancel"), Some("{}")],
        );
        let said = talk(
            &ctx,
            &[
                "SETOK Yes",
                "CONFIRM",
                "CONFIRM",
                "SETNOTOK No",
                "CONFIRM",
                "MESSAGE",
                "UNHEARD",
                "BYE",
            ],
        );
        assert_eq!(
            said,
            [
                "OK Pleased to meet you",
                "OK",
                "OK",
                CANCELED,
                "OK",
                NOT_CONFIRMED,
                "OK",
                UNKNOWN,
                "OK closing connection"
            ]
        );
    }

    #[test]
    fn with_no_shell_it_hands_over() {
        let dir = scratch("pinentry");
        let ctx = context(&dir);
        assert!(!shell_listens(&ctx));
        let _card = Card::listen(&ctx.runtime, &[]);
        assert!(shell_listens(&ctx));
    }
}
