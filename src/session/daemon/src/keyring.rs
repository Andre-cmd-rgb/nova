//! gnome-keyring's questions on Nova's card: a keyring's password when it
//! did not open at login (the account's password changed, or it was made
//! with another), a new keyring's password twice, and its yes-or-no ones.
//!
//! gnome-keyring asks through gcr's system prompter, the session bus's
//! org.gnome.keyring.SystemPrompter, which gcr's GTK dialog is when nobody
//! holds the name. This duty holds it, without letting it be taken over:
//!
//! - the keyring calls BeginPrompting(<callback>), and is answered first;
//!   then, its turn come (one question at a time), the duty calls its
//!   callback's PromptReady("", {}, <exchange>) with the duty's public value;
//! - PerformPrompt(<callback>, "password" | "confirm", <properties>,
//!   <exchange>) asks: the card shows the title, the words, a password field
//!   (two for a new password, checked against each other here), the switch
//!   the keyring names ("Automatically unlock…") and its buttons;
//! - the answer is PromptReady("yes" | "no", <properties>, <exchange>), the
//!   password in the exchange (exchange.rs), encrypted, with
//!   password-strength (0 for none) and choice-chosen; the card stays, busy,
//!   for the keyring's next word: a wrong password is PerformPrompt again
//!   with a warning, which the card shakes for;
//! - StopPrompting(<callback>), or the keyring leaving the bus, ends it: the
//!   card goes, and the next question, if any, has its turn.
//!
//! A card the shell cannot show yet (the keyring asks as the session starts,
//! before the shell listens) is tried for a while before it is a "no".

use std::collections::{HashMap, VecDeque};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use std::{cell::RefCell, rc::Rc};

use nova_sd::poll::{poll, PollFd, POLLIN};
use nova_sd::{
    Bus, Error, Interface, Message, Slot, Value, ERROR_FAILED, ERROR_INVALID_ARGS, NAME_QUEUE,
};

use crate::common::{Context, Waker};
use crate::exchange::Exchange;
use crate::prompt::{Ask, Dialog, Ender, Field, Glyph, Toggle, Values};

pub const DUTY: &str = "keyring";

const NAME: &str = "org.gnome.keyring.SystemPrompter";
const PATH: &str = "/org/gnome/keyring/Prompter";
const INTERFACE: &str = "org.gnome.keyring.internal.Prompter";
const CALLBACK: &str = "org.gnome.keyring.internal.Prompter.Callback";
const FAILED: &str = ERROR_FAILED;
const INVALID_ARGS: &str = ERROR_INVALID_ARGS;

/// How long a card is tried for while the shell does not listen.
const PATIENCE: Duration = Duration::from_secs(30);

/// A question: the asker's unique name and its callback's path.
type Key = (String, String);

/// What the keyring said the question is to show (gcr's prompt properties;
/// an empty string is none).
#[derive(Debug, Default, Clone, PartialEq)]
struct Props {
    title: String,
    message: String,
    description: String,
    warning: String,
    continue_label: String,
    cancel_label: String,
    choice_label: String,
    password_new: bool,
    choice_chosen: bool,
}

impl Props {
    fn update(&mut self, dict: &Value) {
        for (key, value) in dict.as_dict().unwrap_or(&[]) {
            let text = || value.as_str().unwrap_or("").to_owned();
            let flag = || value.as_bool().unwrap_or(false);
            match key.as_str().unwrap_or("") {
                "title" => self.title = text(),
                "message" => self.message = text(),
                "description" => self.description = text(),
                "warning" => self.warning = text(),
                "continue-label" => self.continue_label = text(),
                "cancel-label" => self.cancel_label = text(),
                "choice-label" => self.choice_label = text(),
                "password-new" => self.password_new = flag(),
                "choice-chosen" => self.choice_chosen = flag(),
                _ => {}
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Kind {
    Password,
    Confirm,
}

/// gcr's labels mark a mnemonic with "_": not on the card.
fn label(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '_' {
            if chars.peek() == Some(&'_') {
                out.push('_');
                chars.next();
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// The keyring writes some words for markup that gcr's dialog shows plain.
fn plain(text: &str) -> String {
    text.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
        .trim()
        .to_owned()
}

/// The card for a question.
fn ask(props: &Props, kind: Kind) -> Ask {
    let title = plain(&props.title);
    let mut ask = Ask::new(
        Glyph::Keyring,
        if title.is_empty() { "Keyring" } else { &title },
    );
    // "Authentication required", above every unlock, says nothing the
    // description does not.
    let message = plain(&props.message);
    let message = if message == "Authentication required" {
        String::new()
    } else {
        message
    };
    ask.text = [message, plain(&props.description)]
        .into_iter()
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if kind == Kind::Password {
        if props.password_new {
            ask.fields.push(Field::secret("password", "New password"));
            ask.fields
                .push(Field::secret("confirm", "Confirm password"));
        } else {
            ask.fields.push(Field::secret("password", "Password"));
        }
    }
    let accept = label(&props.continue_label);
    ask.accept = if accept.is_empty() {
        "Continue".into()
    } else {
        accept
    };
    ask.cancel = label(&props.cancel_label);
    if !props.choice_label.is_empty() {
        ask.toggles.push(Toggle {
            id: "remember".into(),
            label: label(&plain(&props.choice_label)),
            value: props.choice_chosen,
        });
    }
    ask
}

/// What the duty tells a card's thread once the card was answered.
enum ToCard {
    /// Another question on the same card.
    Ask(Ask),
    /// The answer did not do: the card shakes and says so.
    Wrong(String),
    Done,
}

/// A card's answer, or none once it was cancelled or went.
type Answered = (Key, Option<Values>);

/// One question, from BeginPrompting to StopPrompting.
struct Prompt {
    exchange: Exchange,
    props: Props,
    kind: Kind,
    /// Its turn has come, and nothing is being asked: the keyring may
    /// PerformPrompt.
    ready: bool,
    /// The card's thread, while one is up.
    card: Option<Sender<ToCard>>,
    /// The asker's name, watched.
    _watch: Option<Slot>,
}

/// What the handler leaves for the loop to do once the calls are answered.
enum Call {
    Begin,
    Perform(Key),
    Stop(Key, bool),
}

#[derive(Default)]
struct State {
    prompts: HashMap<Key, Prompt>,
    active: Option<Key>,
    queue: VecDeque<Key>,
    calls: Vec<Call>,
}

fn failed(text: &str) -> Error {
    Error::bus(FAILED, text)
}

fn key_of(call: &Message, args: &[Value]) -> Result<Key, Error> {
    let sender = call.sender().ok_or_else(|| failed("no sender"))?;
    let path = args
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| failed("no callback"))?;
    Ok((sender.to_owned(), path.to_owned()))
}

/// The prompter's three methods.
fn handle(
    bus: &Bus,
    state: &Rc<RefCell<State>>,
    call: &Message,
    args: Vec<Value>,
) -> Result<Vec<Value>, Error> {
    let key = key_of(call, &args)?;
    let mut s = state.borrow_mut();
    match call.member().unwrap_or("") {
        "BeginPrompting" => {
            if s.prompts.contains_key(&key) {
                return Err(failed("Already begun prompting for this prompt callback"));
            }
            let weak = Rc::downgrade(state);
            let gone = key.clone();
            let watch = bus
                .watch_name(&key.0, move |owner| {
                    if owner.is_none() {
                        if let Some(state) = weak.upgrade() {
                            state
                                .borrow_mut()
                                .calls
                                .push(Call::Stop(gone.clone(), false));
                        }
                    }
                })
                .ok()
                .map(|(slot, _)| slot);
            s.prompts.insert(
                key.clone(),
                Prompt {
                    exchange: Exchange::new(),
                    props: Props::default(),
                    kind: Kind::Password,
                    ready: false,
                    card: None,
                    _watch: watch,
                },
            );
            s.queue.push_back(key.clone());
            s.calls.push(Call::Begin);
        }
        "PerformPrompt" => {
            let prompt = s
                .prompts
                .get_mut(&key)
                .ok_or_else(|| failed("Not begun prompting for this prompt callback"))?;
            if !prompt.ready {
                return Err(failed(
                    "Already performing a prompt for this prompt callback",
                ));
            }
            let kind = match args.get(1).and_then(Value::as_str) {
                Some("password") => Kind::Password,
                Some("confirm") => Kind::Confirm,
                _ => return Err(Error::bus(INVALID_ARGS, "Invalid type argument")),
            };
            let exchange = args.get(3).and_then(Value::as_str).unwrap_or("");
            if !prompt.exchange.receive(exchange) {
                return Err(Error::bus(INVALID_ARGS, "Invalid secret exchange received"));
            }
            if let Some(props) = args.get(2) {
                prompt.props.update(props);
            }
            prompt.kind = kind;
            prompt.ready = false;
            s.calls.push(Call::Perform(key));
        }
        "StopPrompting" => {
            if !s.prompts.contains_key(&key) {
                return Err(failed("Not begun prompting for this prompt callback"));
            }
            s.calls.push(Call::Stop(key, true));
        }
        _ => {}
    }
    Ok(vec![])
}

/// A card's life on its own thread: shown (tried for a while if the shell
/// does not listen yet), each answer handed back, and the duty's next word
/// waited for.
struct CardJob {
    ctx: Context,
    key: Key,
    first: Ask,
    told: Receiver<ToCard>,
    answers: Sender<Answered>,
    waker: Arc<Waker>,
    enders: Arc<Mutex<HashMap<Key, Ender>>>,
    patience: Duration,
}

fn card(job: CardJob) {
    let tell = |answer: Option<Values>| {
        let _ = job.answers.send((job.key.clone(), answer));
        job.waker.wake();
    };
    let since = Instant::now();
    let mut dialog = loop {
        match Dialog::open(&job.ctx, &job.first) {
            Ok(dialog) => break dialog,
            Err(e) => {
                // Over before the shell listened: nothing to show.
                if matches!(
                    job.told.try_recv(),
                    Ok(ToCard::Done) | Err(TryRecvError::Disconnected)
                ) {
                    return;
                }
                if since.elapsed() >= job.patience {
                    eprintln!("{DUTY}: no card to ask on ({e})");
                    return tell(None);
                }
                thread::sleep(Duration::from_millis(250));
            }
        }
    };
    if let Ok(ender) = dialog.ender() {
        job.enders.lock().unwrap().insert(job.key.clone(), ender);
    }
    loop {
        let answer = dialog.answer();
        let gone = answer.is_none();
        tell(answer);
        if gone {
            break;
        }
        match job.told.recv() {
            Ok(ToCard::Ask(ask)) => {
                let _ = dialog.ask(&ask);
            }
            Ok(ToCard::Wrong(text)) => {
                let _ = dialog.wrong(&text);
            }
            Ok(ToCard::Done) | Err(_) => {
                dialog.done();
                break;
            }
        }
    }
    job.enders.lock().unwrap().remove(&job.key);
}

struct Prompter<'a> {
    ctx: &'a Context,
    bus: &'a Bus,
    state: Rc<RefCell<State>>,
    answers: Sender<Answered>,
    waker: Arc<Waker>,
    enders: Arc<Mutex<HashMap<Key, Ender>>>,
    patience: Duration,
}

impl Prompter<'_> {
    fn take(&self, call: Call) {
        match call {
            Call::Begin => self.next(),
            Call::Perform(key) => self.perform(key),
            Call::Stop(key, told) => self.stop(key, told),
        }
    }

    /// The next question in line has its turn, if none has it.
    fn next(&self) {
        let mut s = self.state.borrow_mut();
        if s.active.is_some() {
            return;
        }
        let Some(key) = s.queue.pop_front() else {
            return;
        };
        let Some(prompt) = s.prompts.get_mut(&key) else {
            drop(s);
            return self.next();
        };
        prompt.ready = true;
        let exchange = prompt.exchange.begin();
        s.active = Some(key.clone());
        drop(s);
        self.ready(&key, "", Vec::new(), exchange);
    }

    fn ready(&self, key: &Key, reply: &str, props: Vec<(&str, Value)>, exchange: String) {
        // gcr's prompter puts each property in a variant of its own inside
        // the dictionary's, and the keyring takes it out of both.
        let props = props
            .into_iter()
            .map(|(k, v)| (k, Value::variant(v)))
            .collect();
        let sent = self.bus.call_async(
            &key.0,
            &key.1,
            CALLBACK,
            "PromptReady",
            &[
                Value::str(reply),
                Value::options(props),
                Value::str(exchange),
            ],
            None,
            |_| {},
        );
        if let Err(e) = sent {
            eprintln!("{DUTY}: could not answer {}: {e}", key.0);
        }
    }

    fn perform(&self, key: Key) {
        let mut s = self.state.borrow_mut();
        let Some(prompt) = s.prompts.get_mut(&key) else {
            return;
        };
        let ask = ask(&prompt.props, prompt.kind);
        let warning = plain(&prompt.props.warning);
        if let Some(card) = &prompt.card {
            // The card is up, busy since its last answer: a warning is the
            // last answer refused (the card shakes and says it), anything
            // else a new question on it.
            let word = if warning.is_empty() {
                ToCard::Ask(ask.clone())
            } else {
                ToCard::Wrong(warning.clone())
            };
            if card.send(word).is_ok() {
                return;
            }
        }
        let mut first = ask;
        if !warning.is_empty() {
            first.text = [warning, first.text]
                .into_iter()
                .filter(|t| !t.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
        }
        let (tx, told) = mpsc::channel();
        prompt.card = Some(tx);
        let job = CardJob {
            ctx: self.ctx.clone(),
            key,
            first,
            told,
            answers: self.answers.clone(),
            waker: self.waker.clone(),
            enders: self.enders.clone(),
            patience: self.patience,
        };
        let spawned = thread::Builder::new()
            .name("keyring-card".into())
            .stack_size(256 * 1024)
            .spawn(move || card(job));
        if let Err(e) = spawned {
            eprintln!("{DUTY}: could not ask: {e}");
        }
    }

    /// A card's answer: back to the keyring, or, two new passwords that
    /// differ, the card says so and is answered again.
    fn answered(&self, (key, answer): Answered) {
        let mut s = self.state.borrow_mut();
        let Some(prompt) = s.prompts.get_mut(&key) else {
            return;
        };
        if prompt.ready {
            return;
        }
        if answer.is_none() {
            prompt.card = None;
        }
        let mut props = Vec::new();
        let (reply, exchange) = match (prompt.kind, answer) {
            (Kind::Password, Some(mut values)) => {
                let mut password = values.remove("password").unwrap_or_default();
                let mut confirm = values.remove("confirm").unwrap_or_default();
                let differ = prompt.props.password_new && password != confirm;
                // SAFETY: zeroes are valid UTF-8.
                unsafe { confirm.as_bytes_mut().fill(0) };
                if differ {
                    // SAFETY: as above.
                    unsafe { password.as_bytes_mut().fill(0) };
                    if let Some(card) = &prompt.card {
                        let _ = card.send(ToCard::Wrong("The passwords do not match.".into()));
                    }
                    return;
                }
                if !prompt.props.choice_label.is_empty() {
                    prompt.props.choice_chosen =
                        values.get("remember").is_some_and(|v| v == "true");
                }
                props.push((
                    "password-strength",
                    Value::Int32(i32::from(!password.is_empty())),
                ));
                let exchange = prompt.exchange.send(Some(password.as_bytes()));
                // SAFETY: as above.
                unsafe { password.as_bytes_mut().fill(0) };
                ("yes", exchange)
            }
            (Kind::Confirm, Some(values)) => {
                if !prompt.props.choice_label.is_empty() {
                    prompt.props.choice_chosen =
                        values.get("remember").is_some_and(|v| v == "true");
                }
                ("yes", prompt.exchange.send(None))
            }
            (_, None) => ("no", prompt.exchange.send(None)),
        };
        props.push(("choice-chosen", Value::Bool(prompt.props.choice_chosen)));
        prompt.ready = true;
        let exchange = exchange.unwrap_or_else(|| prompt.exchange.begin());
        drop(s);
        self.ready(&key, reply, props, exchange);
    }

    /// The question is over: told by the keyring (which hears PromptDone),
    /// or the keyring left.
    fn stop(&self, key: Key, told: bool) {
        let mut s = self.state.borrow_mut();
        let Some(prompt) = s.prompts.remove(&key) else {
            return;
        };
        s.queue.retain(|k| *k != key);
        let was_active = s.active.as_ref() == Some(&key);
        if was_active {
            s.active = None;
        }
        drop(s);
        if let Some(card) = prompt.card {
            // Answered, the card waits for the duty's word; else it waits
            // for the user, and is ended.
            let _ = card.send(ToCard::Done);
            if !prompt.ready {
                if let Some(ender) = self.enders.lock().unwrap().remove(&key) {
                    ender.end();
                }
            }
        }
        if told {
            let _ = self
                .bus
                .call_no_reply(&key.0, &key.1, CALLBACK, "PromptDone", &[]);
        }
        if was_active {
            self.next();
        }
    }
}

pub fn serve(bus: &Bus, ctx: &Context, patience: Duration) -> Result<(), String> {
    let waker = Arc::new(Waker::new().map_err(|e| format!("cannot make a waker: {e}"))?);
    let (answers, answered) = mpsc::channel();
    let state: Rc<RefCell<State>> = Rc::default();
    let handler_state = state.clone();
    let handler_bus = bus.clone();
    let _object = bus
        .export(
            PATH,
            vec![Interface::new(INTERFACE)
                .method("BeginPrompting", "o", "")
                .method("PerformPrompt", "osa{sv}s", "")
                .method("StopPrompting", "o", "")],
            move |call: &Message, args: Vec<Value>| {
                handle(&handler_bus, &handler_state, call, args)
            },
        )
        .map_err(|e| format!("cannot put the prompter on the bus: {e}"))?;
    // Queued behind gcr's prompter if it runs just now; never let go to it.
    bus.request_name(NAME, NAME_QUEUE)
        .map_err(|e| format!("cannot ask for {NAME}: {e}"))?;
    let prompter = Prompter {
        ctx,
        bus,
        state: state.clone(),
        answers,
        waker: waker.clone(),
        enders: Arc::default(),
        patience,
    };
    loop {
        let mut fds = [bus.poll_fd(), PollFd::new(waker.fd(), POLLIN)];
        if let Err(e) = poll(&mut fds, bus.timeout()) {
            return Err(format!("could not wait: {e}"));
        }
        if let Err(e) = bus.dispatch() {
            return Err(format!("the session bus went: {e}"));
        }
        let calls = std::mem::take(&mut state.borrow_mut().calls);
        for call in calls {
            prompter.take(call);
        }
        if fds[1].ready() {
            waker.drain();
            while let Ok(answer) = answered.try_recv() {
                prompter.answered(answer);
            }
        }
    }
}

pub fn run(ctx: &Context) -> Result<(), String> {
    let bus = Bus::user().map_err(|e| e.to_string())?;
    serve(&bus, ctx, PATIENCE)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prompt::fake::Card;
    use crate::testing::context;
    use nova_sd::testing::{scratch, PrivateBus};

    #[test]
    fn labels_and_words_are_shown_plain() {
        assert_eq!(label("_Unlock"), "Unlock");
        assert_eq!(label("Save__as"), "Save_as");
        assert_eq!(plain(" Tom &amp; Jerry &lt;3 "), "Tom & Jerry <3");
    }

    #[test]
    fn the_card_says_what_the_keyring_asks() {
        let mut props = Props::default();
        props.update(&Value::options(vec![
            ("title", Value::str("Unlock Keyring")),
            ("message", Value::str("Authentication required")),
            (
                "description",
                Value::str("An application wants access to the keyring “Work”, but it is locked"),
            ),
            ("continue-label", Value::str("_Unlock")),
            (
                "choice-label",
                Value::str("Automatically unlock this keyring whenever I’m logged in"),
            ),
            ("choice-chosen", Value::Bool(true)),
            ("password-strength", Value::Int32(3)),
        ]));
        let card = ask(&props, Kind::Password);
        assert_eq!(card.title, "Unlock Keyring");
        assert_eq!(
            card.text,
            "An application wants access to the keyring “Work”, but it is locked"
        );
        assert_eq!(
            card.fields
                .iter()
                .map(|f| f.id.as_str())
                .collect::<Vec<_>>(),
            ["password"]
        );
        assert_eq!(card.accept, "Unlock");
        assert_eq!(
            card.toggles[0].label,
            "Automatically unlock this keyring whenever I’m logged in"
        );
        assert!(card.toggles[0].value);

        props.password_new = true;
        props.message = "Choose password for new keyring".into();
        props.choice_label.clear();
        let card = ask(&props, Kind::Password);
        assert_eq!(
            card.fields
                .iter()
                .map(|f| f.id.as_str())
                .collect::<Vec<_>>(),
            ["password", "confirm"]
        );
        assert!(card.text.starts_with("Choose password for new keyring\n"));
        assert!(card.toggles.is_empty());

        let confirm = ask(
            &Props {
                message: "Store passwords unencrypted?".into(),
                ..Props::default()
            },
            Kind::Confirm,
        );
        assert!(confirm.fields.is_empty());
        assert_eq!(
            (
                confirm.title.as_str(),
                confirm.text.as_str(),
                confirm.accept.as_str()
            ),
            ("Keyring", "Store passwords unencrypted?", "Continue")
        );
    }

    /// What the keyring's side hears on its callback.
    #[derive(Debug)]
    enum Heard {
        Ready(String, Vec<(String, Value)>, String),
        Done,
    }

    /// The keyring's side, on its own connection and thread: its callback
    /// object, and its calls to the prompter.
    struct Keyring {
        bus: Bus,
        heard: Receiver<Heard>,
        _slot: Slot,
    }

    impl Keyring {
        fn new(address: &str, path: &str) -> Keyring {
            let bus = Bus::connect(address).unwrap();
            let (tx, heard) = mpsc::channel();
            let slot = bus
                .export(
                    path,
                    vec![Interface::new(CALLBACK)
                        .method("PromptReady", "sa{sv}s", "")
                        .method("PromptDone", "", "")],
                    move |call: &Message, args: Vec<Value>| {
                        let heard = match call.member() {
                            Some("PromptReady") => {
                                let props = args[1]
                                    .as_dict()
                                    .unwrap()
                                    .iter()
                                    .map(|(k, v)| (k.as_str().unwrap().to_owned(), v.clone()))
                                    .collect();
                                Heard::Ready(
                                    args[0].as_str().unwrap().into(),
                                    props,
                                    args[2].as_str().unwrap().into(),
                                )
                            }
                            _ => Heard::Done,
                        };
                        tx.send(heard).unwrap();
                        Ok(vec![])
                    },
                )
                .unwrap();
            Keyring {
                bus,
                heard,
                _slot: slot,
            }
        }

        fn call(&self, member: &str, args: &[Value]) -> Result<Vec<Value>, Error> {
            self.bus.call(NAME, PATH, INTERFACE, member, args)
        }

        /// The next thing heard, the bus turned meanwhile.
        fn hear(&self) -> Heard {
            let until = Instant::now() + Duration::from_secs(5);
            loop {
                self.bus.wait(Some(Duration::from_millis(20))).unwrap();
                self.bus.dispatch().unwrap();
                match self.heard.try_recv() {
                    Ok(heard) => return heard,
                    Err(_) if Instant::now() < until => continue,
                    Err(_) => panic!("heard nothing"),
                }
            }
        }

        fn nothing_for(&self, wait: Duration) -> bool {
            let until = Instant::now() + wait;
            while Instant::now() < until {
                self.bus.wait(Some(Duration::from_millis(20))).unwrap();
                self.bus.dispatch().unwrap();
                match self.heard.try_recv() {
                    Ok(_) => return false,
                    Err(mpsc::TryRecvError::Empty) => {}
                    Err(mpsc::TryRecvError::Disconnected) => return true,
                }
            }
            true
        }
    }

    /// A property the prompter sent, out of both its variants.
    fn prop<'a>(props: &'a [(String, Value)], name: &str) -> &'a Value {
        let value = &props.iter().find(|(k, _)| k == name).unwrap().1;
        let Value::Variant(outer) = value else {
            panic!("{name} is not in a variant")
        };
        let Value::Variant(inner) = outer.as_ref() else {
            panic!("{name} is not in a variant of its own")
        };
        inner
    }

    fn start(dir: &std::path::Path) -> Option<(PrivateBus, Context, thread::JoinHandle<()>)> {
        let bus = PrivateBus::start()?;
        let ctx = context(dir);
        let (address, duty_ctx) = (bus.address.clone(), ctx.clone());
        let (up, is_up) = mpsc::channel();
        let duty = thread::spawn(move || {
            let bus = Bus::connect(&address).unwrap();
            up.send(()).unwrap();
            let _ = serve(&bus, &duty_ctx, Duration::from_millis(300));
        });
        is_up.recv().unwrap();
        // The name is the duty's once it has asked for it.
        let probe = Bus::connect(&bus.address).unwrap();
        let until = Instant::now() + Duration::from_secs(5);
        while probe.name_owner(NAME).unwrap().is_none() {
            assert!(Instant::now() < until, "the duty never held {NAME}");
            thread::sleep(Duration::from_millis(10));
        }
        Some((bus, ctx, duty))
    }

    #[test]
    fn an_unlock_a_wrong_password_and_the_right_one() {
        let dir = scratch("keyring-unlock");
        let Some((bus, ctx, _duty)) = start(&dir) else {
            return;
        };
        let card = Card::listen(
            &ctx.runtime,
            &[
                Some(r#"{"password":"wrong","remember":"true"}"#),
                Some(r#"{"password":"right","remember":"false"}"#),
            ],
        );
        let keyring = Keyring::new(&bus.address, "/org/gnome/keyring/Prompt/p0");
        let mut mine = Exchange::new();
        keyring
            .call(
                "BeginPrompting",
                &[Value::path("/org/gnome/keyring/Prompt/p0")],
            )
            .unwrap();
        let Heard::Ready(reply, props, theirs) = keyring.hear() else {
            panic!("not ready")
        };
        assert_eq!((reply.as_str(), props.len()), ("", 0));
        assert!(mine.receive(&theirs) && !theirs.contains("secret="));

        let perform = |props: Value, exchange: String| {
            keyring.call(
                "PerformPrompt",
                &[
                    Value::path("/org/gnome/keyring/Prompt/p0"),
                    Value::str("password"),
                    props,
                    Value::str(exchange),
                ],
            )
        };
        perform(
            Value::options(vec![
            ("title", Value::str("Unlock Login Keyring")),
            (
                "description",
                Value::str(
                    "The login keyring did not get unlocked when you logged into your computer.",
                ),
            ),
            ("continue-label", Value::str("Unlock")),
            (
                "choice-label",
                Value::str("Automatically unlock this keyring whenever I’m logged in"),
            ),
            ("choice-chosen", Value::Bool(false)),
        ]),
            mine.send(None).unwrap(),
        )
        .unwrap();
        let Heard::Ready(reply, props, theirs) = keyring.hear() else {
            panic!("no answer")
        };
        assert_eq!(reply, "yes");
        assert_eq!(prop(&props, "password-strength"), &Value::Int32(1));
        assert_eq!(prop(&props, "choice-chosen"), &Value::Bool(true));
        assert!(mine.receive(&theirs));
        assert_eq!(mine.received().unwrap(), b"wrong");

        // Wrong: the keyring asks again with a warning; the card shakes.
        perform(
            Value::options(vec![
                ("warning", Value::str("The unlock password was incorrect")),
                ("choice-chosen", Value::Bool(false)),
            ]),
            mine.send(None).unwrap(),
        )
        .unwrap();
        let Heard::Ready(reply, props, theirs) = keyring.hear() else {
            panic!("no answer")
        };
        assert_eq!(reply, "yes");
        assert_eq!(prop(&props, "choice-chosen"), &Value::Bool(false));
        assert!(mine.receive(&theirs));
        assert_eq!(mine.received().unwrap(), b"right");

        keyring
            .call(
                "StopPrompting",
                &[Value::path("/org/gnome/keyring/Prompt/p0")],
            )
            .unwrap();
        assert!(matches!(keyring.hear(), Heard::Done));

        let lines = card.lines_when_done();
        assert!(
            lines.iter().all(|(n, _)| *n == 0),
            "one card for it all: {lines:?}"
        );
        let ask = &lines[0].1;
        assert!(
            ask.contains(r#""glyph":"keyring""#)
                && ask.contains(r#""title":"Unlock Login Keyring""#)
        );
        assert!(ask.contains(r#""accept":"Unlock""#) && ask.contains(r#""id":"remember""#));
        assert!(lines
            .iter()
            .any(|(_, l)| l == r#"{"type":"wrong","text":"The unlock password was incorrect"}"#));
        assert!(lines.last().unwrap().1.contains(r#""type":"done""#));
    }

    #[test]
    fn a_new_password_twice_a_cancel_and_one_question_at_a_time() {
        let dir = scratch("keyring-new");
        let Some((bus, ctx, _duty)) = start(&dir) else {
            return;
        };
        let card = Card::listen(
            &ctx.runtime,
            &[
                Some(r#"{"password":"one","confirm":"two"}"#),
                Some(r#"{"password":"same","confirm":"same"}"#),
                Some("cancel"),
            ],
        );
        let first = Keyring::new(&bus.address, "/org/gnome/keyring/Prompt/p1");
        let second = Keyring::new(&bus.address, "/org/gnome/keyring/Prompt/p2");
        let mut mine = Exchange::new();
        first
            .call(
                "BeginPrompting",
                &[Value::path("/org/gnome/keyring/Prompt/p1")],
            )
            .unwrap();
        let Heard::Ready(_, _, theirs) = first.hear() else {
            panic!()
        };
        assert!(mine.receive(&theirs));
        // A second asker waits its turn.
        second
            .call(
                "BeginPrompting",
                &[Value::path("/org/gnome/keyring/Prompt/p2")],
            )
            .unwrap();
        assert!(second.nothing_for(Duration::from_millis(200)));

        first
            .call(
                "PerformPrompt",
                &[
                    Value::path("/org/gnome/keyring/Prompt/p1"),
                    Value::str("password"),
                    Value::options(vec![("password-new", Value::Bool(true))]),
                    Value::str(mine.send(None).unwrap()),
                ],
            )
            .unwrap();
        let Heard::Ready(reply, props, theirs) = first.hear() else {
            panic!()
        };
        assert_eq!(reply, "yes");
        assert_eq!(prop(&props, "password-strength"), &Value::Int32(1));
        assert!(mine.receive(&theirs));
        assert_eq!(mine.received().unwrap(), b"same");
        assert!(card
            .lines()
            .iter()
            .any(|(_, l)| l.contains("The passwords do not match.")));

        first
            .call(
                "StopPrompting",
                &[Value::path("/org/gnome/keyring/Prompt/p1")],
            )
            .unwrap();
        assert!(matches!(first.hear(), Heard::Done));

        // Now the second's turn; it is cancelled.
        let Heard::Ready(reply, _, theirs) = second.hear() else {
            panic!()
        };
        assert_eq!(reply, "");
        let mut its = Exchange::new();
        assert!(its.receive(&theirs));
        second
            .call(
                "PerformPrompt",
                &[
                    Value::path("/org/gnome/keyring/Prompt/p2"),
                    Value::str("confirm"),
                    Value::options(vec![(
                        "message",
                        Value::str("Store passwords unencrypted?"),
                    )]),
                    Value::str(its.send(None).unwrap()),
                ],
            )
            .unwrap();
        let Heard::Ready(reply, props, theirs) = second.hear() else {
            panic!()
        };
        assert_eq!(reply, "no");
        assert!(props.iter().all(|(k, _)| k != "password-strength"));
        assert!(!theirs.contains("secret="));
    }

    #[test]
    fn a_question_asked_again_before_the_answer_is_refused() {
        let dir = scratch("keyring-again");
        let Some((bus, ctx, _duty)) = start(&dir) else {
            return;
        };
        // A card that never answers, so the second question is always
        // before the answer.
        let card = Card::listen(&ctx.runtime, &[None]);
        let keyring = Keyring::new(&bus.address, "/p");
        let mut mine = Exchange::new();
        keyring
            .call("BeginPrompting", &[Value::path("/p")])
            .unwrap();
        let Heard::Ready(_, _, theirs) = keyring.hear() else {
            panic!("not ready")
        };
        assert!(mine.receive(&theirs));
        let perform = |exchange: String| {
            keyring.call(
                "PerformPrompt",
                &[
                    Value::path("/p"),
                    Value::str("password"),
                    Value::options(vec![("title", Value::str("Unlock Login Keyring"))]),
                    Value::str(exchange),
                ],
            )
        };
        perform(mine.send(None).unwrap()).unwrap();
        crate::testing::wait_until("the card", || !card.lines().is_empty());
        let again = perform(mine.send(None).unwrap()).unwrap_err();
        assert_eq!(again.name(), Some(FAILED), "refused, as gcr does");
        assert_eq!(card.lines().len(), 1, "and not asked on the card");
    }

    #[test]
    fn an_asker_that_leaves_lets_the_next_one_ask_and_calls_out_of_turn_are_refused() {
        let dir = scratch("keyring-leave");
        let Some((bus, ctx, _duty)) = start(&dir) else {
            return;
        };
        let _card = Card::listen(&ctx.runtime, &[None]);
        let keyring = Keyring::new(&bus.address, "/p");
        let not_begun = keyring
            .call(
                "PerformPrompt",
                &[
                    Value::path("/p"),
                    Value::str("password"),
                    Value::options(Vec::<(&str, Value)>::new()),
                    Value::str(""),
                ],
            )
            .unwrap_err();
        assert_eq!(not_begun.name(), Some(FAILED));
        assert_eq!(
            keyring
                .call("StopPrompting", &[Value::path("/p")])
                .unwrap_err()
                .name(),
            Some(FAILED)
        );
        keyring
            .call("BeginPrompting", &[Value::path("/p")])
            .unwrap();
        assert_eq!(
            keyring
                .call("BeginPrompting", &[Value::path("/p")])
                .unwrap_err()
                .name(),
            Some(FAILED)
        );
        let Heard::Ready(..) = keyring.hear() else {
            panic!()
        };
        let garbled = keyring
            .call(
                "PerformPrompt",
                &[
                    Value::path("/p"),
                    Value::str("password"),
                    Value::options(Vec::<(&str, Value)>::new()),
                    Value::str("nonsense"),
                ],
            )
            .unwrap_err();
        assert_eq!(garbled.name(), Some(INVALID_ARGS));

        let next = Keyring::new(&bus.address, "/q");
        next.call("BeginPrompting", &[Value::path("/q")]).unwrap();
        drop(keyring);
        let Heard::Ready(reply, ..) = next.hear() else {
            panic!()
        };
        assert_eq!(reply, "");
    }

    #[test]
    fn with_no_shell_to_ask_on_the_answer_is_no() {
        let dir = scratch("keyring-noshell");
        let Some((bus, _ctx, _duty)) = start(&dir) else {
            return;
        };
        let keyring = Keyring::new(&bus.address, "/p");
        let mut mine = Exchange::new();
        keyring
            .call("BeginPrompting", &[Value::path("/p")])
            .unwrap();
        let Heard::Ready(_, _, theirs) = keyring.hear() else {
            panic!()
        };
        assert!(mine.receive(&theirs));
        keyring
            .call(
                "PerformPrompt",
                &[
                    Value::path("/p"),
                    Value::str("password"),
                    Value::options(Vec::<(&str, Value)>::new()),
                    Value::str(mine.send(None).unwrap()),
                ],
            )
            .unwrap();
        let Heard::Ready(reply, ..) = keyring.hear() else {
            panic!()
        };
        assert_eq!(reply, "no");
    }
}
