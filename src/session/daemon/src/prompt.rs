//! Nova's own dialogs, for what a duty needs from the person at the
//! computer: an encrypted drive's passphrase, a Bluetooth pairing's code, a
//! printer's user name and password. The shell asks, on a card like the one it asks the
//! administrator's password on (its prompts plugin), and listens for the
//! duties on $XDG_RUNTIME_DIR/nova/prompts.sock, in the user's own private
//! runtime folder.
//!
//! One connection is one dialog, a line of JSON each way at a time:
//!
//!   duty   {"type":"ask","glyph":…,"title":…,"text":…,"code":…,
//!           "fields":[{"id":…,"label":…,"secret":…,"value":…}],"accept":…,
//!           "cancel":…,"alone":…,"choices":[{"id":…,"label":…,"detail":…,
//!           "glyph":…,"section":…}],"chosen":…,
//!           "toggles":[{"id":…,"label":…,"value":…}]}
//!   shell  {"type":"answer","values":{"<id>":"…"}}, or {"type":"cancel"}
//!   duty   {"type":"done"}               the card goes
//!          {"type":"wrong","text":…}     it shakes, its secret fields
//!                                        emptied, and is answered again
//!
//! Either side closing the connection ends the dialog: the card goes, and a
//! duty takes it as cancelled. What is typed goes through the socket only,
//! never through a program's arguments or a file.

use std::collections::BTreeMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::Path;

use crate::common::Context;
use crate::json::{self, quote, Json};

/// The shell's socket, in the runtime folder.
pub const SOCKET: &str = "prompts.sock";

/// The longest line the shell's answer may be: a passphrase is far shorter.
const LONGEST: u64 = 64 * 1024;

/// What the card shows beside what it asks: what the question is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Glyph {
    Drive,
    Bluetooth,
    Printer,
    Key,
    Keyring,
    Share,
}

impl Glyph {
    fn name(self) -> &'static str {
        match self {
            Glyph::Drive => "drive",
            Glyph::Bluetooth => "bluetooth",
            Glyph::Printer => "printer",
            Glyph::Key => "key",
            Glyph::Keyring => "keyring",
            Glyph::Share => "share",
        }
    }
}

/// A line to type in: its answer comes back under <id>; a secret one shows
/// dots, and is emptied when the answer was wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Field {
    pub id: String,
    pub label: String,
    pub secret: bool,
    pub value: String,
}

impl Field {
    pub fn secret(id: &str, label: &str) -> Field {
        Field {
            id: id.to_owned(),
            label: label.to_owned(),
            secret: true,
            value: String::new(),
        }
    }

    pub fn plain(id: &str, label: &str, value: &str) -> Field {
        Field {
            id: id.to_owned(),
            label: label.to_owned(),
            secret: false,
            value: value.to_owned(),
        }
    }
}

/// One of a list to choose from: its answer is "choice", <id>. A choice
/// heads a section when its <section> is not the one before's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Choice {
    pub id: String,
    pub label: String,
    pub detail: String,
    /// The card's name for its glyph: "monitor", "window", "region".
    pub glyph: String,
    pub section: String,
}

/// A switch: its answer is "true" or "false" under <id>.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Toggle {
    pub id: String,
    pub label: String,
    pub value: bool,
}

/// A question: <title> on the tab above the card; on the card <code> large
/// (a pairing's digits) and <text> under it, the fields, a list to choose
/// one of (<chosen> at first, else the first) and the switches. With no
/// field, the card answers with Cancel (in <cancel>'s words, when given) or
/// <accept>; <alone>, with <accept> only (a message).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ask {
    pub glyph: Glyph,
    pub title: String,
    pub text: String,
    pub code: String,
    pub fields: Vec<Field>,
    pub accept: String,
    pub cancel: String,
    pub alone: bool,
    pub choices: Vec<Choice>,
    pub chosen: String,
    pub toggles: Vec<Toggle>,
}

impl Ask {
    pub fn new(glyph: Glyph, title: &str) -> Ask {
        Ask {
            glyph,
            title: title.to_owned(),
            text: String::new(),
            code: String::new(),
            fields: Vec::new(),
            accept: String::new(),
            cancel: String::new(),
            alone: false,
            choices: Vec::new(),
            chosen: String::new(),
            toggles: Vec::new(),
        }
    }

    fn line(&self) -> String {
        let fields: Vec<String> = self
            .fields
            .iter()
            .map(|f| {
                format!(
                    r#"{{"id":{},"label":{},"secret":{},"value":{}}}"#,
                    quote(&f.id),
                    quote(&f.label),
                    f.secret,
                    quote(&f.value)
                )
            })
            .collect();
        let choices: Vec<String> = self
            .choices
            .iter()
            .map(|c| {
                format!(
                    r#"{{"id":{},"label":{},"detail":{},"glyph":{},"section":{}}}"#,
                    quote(&c.id),
                    quote(&c.label),
                    quote(&c.detail),
                    quote(&c.glyph),
                    quote(&c.section)
                )
            })
            .collect();
        let toggles: Vec<String> = self
            .toggles
            .iter()
            .map(|t| {
                format!(
                    r#"{{"id":{},"label":{},"value":{}}}"#,
                    quote(&t.id),
                    quote(&t.label),
                    t.value
                )
            })
            .collect();
        format!(
            r#"{{"type":"ask","glyph":{},"title":{},"text":{},"code":{},"fields":[{}],"accept":{},"cancel":{},"alone":{},"choices":[{}],"chosen":{},"toggles":[{}]}}"#,
            quote(self.glyph.name()),
            quote(&self.title),
            quote(&self.text),
            quote(&self.code),
            fields.join(","),
            quote(&self.accept),
            quote(&self.cancel),
            self.alone,
            choices.join(","),
            quote(&self.chosen),
            toggles.join(",")
        )
    }
}

/// What was typed in each field, by its id.
pub type Values = BTreeMap<String, String>;

/// A dialog on the shell's card, open until done() or dropped.
pub struct Dialog {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

/// Another thread's hold on a dialog, to end it from there (the drive went,
/// the device called the pairing off): the card goes, and the answer waited
/// for is none.
pub struct Ender(UnixStream);

impl Ender {
    pub fn end(&self) {
        let _ = self.0.shutdown(Shutdown::Both);
    }
}

impl Dialog {
    /// Asks on the shell's card; an error when the shell is not listening.
    pub fn open(ctx: &Context, ask: &Ask) -> io::Result<Dialog> {
        Dialog::open_at(&ctx.runtime.join(SOCKET), ask)
    }

    fn open_at(socket: &Path, ask: &Ask) -> io::Result<Dialog> {
        let stream = UnixStream::connect(socket)?;
        let reader = BufReader::new(stream.try_clone()?);
        let mut dialog = Dialog { stream, reader };
        dialog.send(&ask.line())?;
        Ok(dialog)
    }

    pub fn ender(&self) -> io::Result<Ender> {
        Ok(Ender(self.stream.try_clone()?))
    }

    fn send(&mut self, line: &str) -> io::Result<()> {
        self.stream.write_all(format!("{line}\n").as_bytes())
    }

    /// What was typed, once the card is answered; none when it was
    /// cancelled, or the dialog ended.
    pub fn answer(&mut self) -> Option<Values> {
        loop {
            let mut line = Vec::new();
            match (&mut self.reader)
                .take(LONGEST)
                .read_until(b'\n', &mut line)
            {
                Ok(0) | Err(_) => return None,
                // Longer than any answer: not the shell's.
                Ok(_) if line.last() != Some(&b'\n') => return None,
                Ok(_) => {}
            }
            let doc = std::str::from_utf8(&line).ok().and_then(json::parse);
            line.fill(0);
            let Some(doc) = doc else { continue };
            match doc.get("type").and_then(Json::as_str) {
                Some("answer") => return Some(values(doc.get("values"))),
                Some("cancel") => return None,
                _ => continue,
            }
        }
    }

    /// Another question on the same card, from the start: a prompt whose
    /// asker changed it (gpg asking again with new words).
    pub fn ask(&mut self, ask: &Ask) -> io::Result<()> {
        self.send(&ask.line())
    }

    /// The answer did not do: the card shakes, says <text>, and is answered
    /// again.
    pub fn wrong(&mut self, text: &str) -> io::Result<()> {
        self.send(&format!(r#"{{"type":"wrong","text":{}}}"#, quote(text)))
    }

    /// The question is over: the card goes.
    pub fn done(mut self) {
        let _ = self.send(r#"{"type":"done"}"#);
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

fn values(doc: Option<&Json>) -> Values {
    doc.and_then(Json::as_object)
        .map(|fields| {
            fields
                .iter()
                .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                .collect()
        })
        .unwrap_or_default()
}

/// The shell's card, as the duties' tests need it.
#[cfg(test)]
pub mod fake {
    use std::collections::VecDeque;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    use std::path::Path;
    use std::sync::{Arc, Mutex};
    use std::thread;

    use super::SOCKET;

    /// Every line a duty sent, by the dialog it came on (numbered from 0),
    /// and the answers still to give.
    #[derive(Clone, Default)]
    pub struct Card {
        pub heard: Arc<Mutex<Vec<(usize, String)>>>,
        answers: Arc<Mutex<VecDeque<Option<String>>>>,
        ended: Arc<Mutex<Vec<usize>>>,
    }

    impl Card {
        /// Listens in <runtime>; each ask or wrong is answered with the next
        /// of <answers>: the values as JSON ({"passphrase":"right"}),
        /// "cancel" for Cancel, or none, for a card left unanswered until the
        /// duty ends it.
        pub fn listen(runtime: &Path, answers: &[Option<&str>]) -> Card {
            std::fs::create_dir_all(runtime).unwrap();
            let listener = UnixListener::bind(runtime.join(SOCKET)).unwrap();
            let card = Card {
                heard: Arc::default(),
                answers: Arc::new(Mutex::new(
                    answers.iter().map(|a| a.map(str::to_owned)).collect(),
                )),
                ended: Arc::default(),
            };
            let shared = card.clone();
            thread::spawn(move || {
                for (n, stream) in listener.incoming().enumerate() {
                    let Ok(stream) = stream else { return };
                    let card = shared.clone();
                    thread::spawn(move || card.serve(n, stream));
                }
            });
            card
        }

        fn serve(&self, n: usize, stream: std::os::unix::net::UnixStream) {
            let mut out = stream.try_clone().unwrap();
            for line in BufReader::new(stream).lines() {
                let Ok(line) = line else { break };
                self.heard.lock().unwrap().push((n, line.clone()));
                if line.starts_with(r#"{"type":"ask""#) || line.starts_with(r#"{"type":"wrong""#) {
                    let next = self.answers.lock().unwrap().pop_front().flatten();
                    match next.as_deref() {
                        Some("cancel") => {
                            let _ = writeln!(out, r#"{{"type":"cancel"}}"#);
                        }
                        Some(values) => {
                            let _ = writeln!(out, r#"{{"type":"answer","values":{values}}}"#);
                        }
                        None => {}
                    }
                }
            }
            self.ended.lock().unwrap().push(n);
        }

        /// The lines heard, by dialog.
        pub fn lines(&self) -> Vec<(usize, String)> {
            self.heard.lock().unwrap().clone()
        }

        /// The dialogs the duty has closed, by number.
        pub fn ended(&self) -> Vec<usize> {
            self.ended.lock().unwrap().clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::thread;

    fn listener() -> (tempdir::Dir, UnixListener) {
        let dir = tempdir::Dir::new();
        let listener = UnixListener::bind(dir.path().join(SOCKET)).unwrap();
        (dir, listener)
    }

    // A scratch folder, gone with the test.
    mod tempdir {
        use std::path::{Path, PathBuf};

        pub struct Dir(PathBuf);

        impl Dir {
            pub fn new() -> Dir {
                let path = std::env::temp_dir().join(format!(
                    "nova-prompt-{}-{:?}",
                    std::process::id(),
                    std::thread::current().id()
                ));
                let _ = std::fs::remove_dir_all(&path);
                std::fs::create_dir_all(&path).unwrap();
                Dir(path)
            }

            pub fn path(&self) -> &Path {
                &self.0
            }
        }

        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    fn passphrase_ask() -> Ask {
        let mut ask = Ask::new(Glyph::Drive, "“Samsung T7” is encrypted");
        ask.fields
            .push(Field::secret("passphrase", "Enter passphrase"));
        ask.accept = "Unlock".into();
        ask
    }

    #[test]
    fn an_ask_is_one_line_of_json_the_shell_reads() {
        let mut ask = passphrase_ask();
        ask.text = "line one\nline \"two\"".into();
        ask.fields.push(Field::plain("user", "User name", "andre"));
        let line = ask.line();
        assert!(!line.contains('\n'));
        let doc = json::parse(&line).unwrap();
        assert_eq!(doc.get("type").and_then(Json::as_str), Some("ask"));
        assert_eq!(doc.get("glyph").and_then(Json::as_str), Some("drive"));
        assert_eq!(
            doc.get("title").and_then(Json::as_str),
            Some("“Samsung T7” is encrypted")
        );
        assert_eq!(
            doc.get("text").and_then(Json::as_str),
            Some("line one\nline \"two\"")
        );
        let fields = doc.get("fields").and_then(Json::as_array).unwrap();
        assert_eq!(fields.len(), 2);
        assert_eq!(fields[0].get("secret"), Some(&Json::Bool(true)));
        assert_eq!(fields[1].get("value").and_then(Json::as_str), Some("andre"));
        assert_eq!(doc.get("accept").and_then(Json::as_str), Some("Unlock"));
    }

    #[test]
    fn asks_takes_the_answer_says_wrong_and_asks_again() {
        let (dir, listener) = listener();
        let shell = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut out = stream;
            let mut heard = Vec::new();
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            heard.push(line.clone());
            // Something the duty does not know comes first, and is passed over.
            out.write_all(b"{\"type\":\"later\"}\nnot json\n").unwrap();
            out.write_all(b"{\"type\":\"answer\",\"values\":{\"passphrase\":\"one two \"}}\n")
                .unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            heard.push(line.clone());
            out.write_all(b"{\"type\":\"answer\",\"values\":{\"passphrase\":\"right\",\"n\":3}}\n")
                .unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            heard.push(line.clone());
            line.clear();
            // Then the duty closes it.
            assert_eq!(reader.read_line(&mut line).unwrap(), 0);
            heard
        });
        let mut dialog = Dialog::open_at(&dir.path().join(SOCKET), &passphrase_ask()).unwrap();
        let first = dialog.answer().unwrap();
        assert_eq!(
            first.get("passphrase").map(String::as_str),
            Some("one two ")
        );
        dialog.wrong("That passphrase did not open it.").unwrap();
        let second = dialog.answer().unwrap();
        assert_eq!(second.get("passphrase").map(String::as_str), Some("right"));
        // A value that is not a string is not one.
        assert_eq!(second.get("n"), None);
        dialog.done();
        let heard = shell.join().unwrap();
        assert!(heard[0].starts_with(r#"{"type":"ask","glyph":"drive""#));
        assert_eq!(
            heard[1],
            "{\"type\":\"wrong\",\"text\":\"That passphrase did not open it.\"}\n"
        );
        assert_eq!(heard[2], "{\"type\":\"done\"}\n");
    }

    #[test]
    fn a_cancel_or_a_closed_card_is_no_answer() {
        let (dir, listener) = listener();
        let shell = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.write_all(b"{\"type\":\"cancel\"}\n").unwrap();
            // The card closed once it has the question.
            let (stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(&stream).read_line(&mut line).unwrap();
            drop(stream);
        });
        let socket = dir.path().join(SOCKET);
        assert_eq!(
            Dialog::open_at(&socket, &passphrase_ask())
                .unwrap()
                .answer(),
            None
        );
        assert_eq!(
            Dialog::open_at(&socket, &passphrase_ask())
                .unwrap()
                .answer(),
            None
        );
        shell.join().unwrap();
    }

    #[test]
    fn an_ender_on_another_thread_ends_the_wait() {
        let (dir, listener) = listener();
        let shell = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut all = String::new();
            // The card hears the connection close.
            reader.read_to_string(&mut all).unwrap();
            all
        });
        let mut dialog = Dialog::open_at(&dir.path().join(SOCKET), &passphrase_ask()).unwrap();
        let ender = dialog.ender().unwrap();
        let ending = thread::spawn(move || {
            thread::sleep(std::time::Duration::from_millis(100));
            ender.end();
        });
        assert_eq!(dialog.answer(), None);
        ending.join().unwrap();
        assert!(shell.join().unwrap().starts_with(r#"{"type":"ask""#));
    }

    #[test]
    fn an_answer_longer_than_any_is_none() {
        let (dir, listener) = listener();
        let shell = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let long = vec![b'x'; LONGEST as usize + 10];
            let _ = stream.write_all(&long);
        });
        let mut dialog = Dialog::open_at(&dir.path().join(SOCKET), &passphrase_ask()).unwrap();
        assert_eq!(dialog.answer(), None);
        shell.join().unwrap();
    }

    #[test]
    fn no_shell_listening_is_an_error() {
        let dir = tempdir::Dir::new();
        assert!(Dialog::open_at(&dir.path().join(SOCKET), &passphrase_ask()).is_err());
    }
}
