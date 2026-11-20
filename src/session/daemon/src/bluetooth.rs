//! Bluetooth pairing's questions, on the shell's card, while a pairing the
//! user picked is under way.
//!
//! BlueZ asks an agent what a pairing needs from the person at the computer:
//! that the code a phone shows is the same as this one, the code to type on
//! a keyboard, a PIN. Nova's agent is here, and is there only while
//! nova-bluetooth-device pairs: it writes $XDG_RUNTIME_DIR/nova/bluetooth-pairing,
//! the session it is in and the device's address, and removes it when it is
//! done. BlueZ keeps the adapter pairable for as long as any agent is
//! registered, so one left there would let any device in range ask; and
//! this one answers for the device picked alone, and turns any other down.
//! Two and a half minutes after it came, it goes, file or no file.
//!
//! The device picked asks on the card (prompt.rs), in plain words:
//!
//!   RequestConfirmation     "Does “Pixel 8” show this code?", Cancel or Pair
//!   DisplayPasskey, -PinCode  "Type this code on “MX Keys”, then Return.",
//!                           Cancel alone, which calls the pairing off
//!   RequestPasskey          the code the other device shows, typed
//!   RequestPinCode          its PIN, typed
//!
//! With no code to compare (RequestAuthorization), and for its profiles
//! (AuthorizeService), it is let in without a question: the user picked it.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::rc::Rc;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner, PollFd, POLLIN};
use nova_sd::{Bus, Deferred, Error, Interface, Message, Slot, Value};

use crate::common::{
    Context, FolderWatch, Waker, IN_CLOSE_WRITE, IN_CREATE, IN_DELETE, IN_MOVED_FROM, IN_MOVED_TO,
};
use crate::prompt::{Ask, Dialog, Ender, Field, Glyph};
use crate::say;

pub const DUTY: &str = "bluetooth-pairing";
const BLUEZ: &str = "org.bluez";
const AGENT_MANAGER: &str = "org.bluez.AgentManager1";
const AGENT: &str = "org.bluez.Agent1";
const DEVICE: &str = "org.bluez.Device1";
const AGENT_PATH: &str = "/org/nova/BluetoothAgent";
const REJECTED: &str = "org.bluez.Error.Rejected";
const CANCELED: &str = "org.bluez.Error.Canceled";
/// The switch nova-bluetooth-device writes, in the runtime folder.
const SWITCH: &str = "bluetooth-pairing";
/// The longest the agent stays: nova-bluetooth-device gives up long before.
const LONGEST: Duration = Duration::from_secs(150);

/// "AA:BB:CC:DD:EE:FF", upper case, or none for anything else.
fn address(text: &str) -> Option<String> {
    let text = text.trim();
    let parts: Vec<&str> = text.split(':').collect();
    (parts.len() == 6
        && parts
            .iter()
            .all(|p| p.len() == 2 && p.chars().all(|c| c.is_ascii_hexdigit())))
    .then(|| text.to_ascii_uppercase())
}

/// The address a BlueZ device's path names: /org/bluez/hci0/dev_AA_BB_….
fn address_of(path: &str) -> Option<String> {
    address(
        &path
            .rsplit('/')
            .next()?
            .strip_prefix("dev_")?
            .replace('_', ":"),
    )
}

/// The device the switch names, when it is this session's.
fn switched_to(ctx: &Context) -> Option<String> {
    let text = fs::read_to_string(ctx.runtime.join(SWITCH)).ok()?;
    let mut lines = text.lines();
    if lines.next()? != ctx.session {
        return None;
    }
    lines.next().and_then(address)
}

/// What a question is, and so what its answer is for BlueZ.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Question {
    /// A code to compare: yes or no.
    Confirm(u32),
    /// A code or a PIN to type on the other device: shown, with Cancel.
    Show(String),
    /// The code the other device shows, typed here: a number.
    Passkey,
    /// The PIN, typed here.
    Pin,
}

impl Question {
    fn ask(&self, name: &str) -> Ask {
        let mut ask = Ask::new(Glyph::Bluetooth, &format!("Pair with “{name}”"));
        match self {
            Question::Confirm(code) => {
                ask.code = format!("{code:06}");
                ask.text = format!("Does “{name}” show this code?");
                ask.accept = "Pair".into();
            }
            Question::Show(code) => {
                ask.code = code.clone();
                ask.text = format!("Type this code on “{name}”, then Return.");
            }
            Question::Passkey => {
                ask.text = format!("Type the code “{name}” shows.");
                ask.fields.push(Field::plain("code", "Code", ""));
            }
            Question::Pin => {
                ask.text = format!("Type the PIN of “{name}”, often 0000.");
                ask.fields.push(Field::plain("pin", "PIN", ""));
            }
        }
        ask
    }

    /// What BlueZ is answered with, from what was typed; none for what is
    /// not one (said wrong on the card, and asked again).
    fn reply(&self, mut values: crate::prompt::Values) -> Option<Vec<Value>> {
        match self {
            Question::Confirm(_) => Some(vec![]),
            // Only Cancel answers a code shown.
            Question::Show(_) => None,
            Question::Passkey => values
                .remove("code")
                .map(|c| c.replace(' ', ""))
                .filter(|c| (1..=6).contains(&c.len()) && c.chars().all(|d| d.is_ascii_digit()))
                .and_then(|c| c.parse::<u32>().ok())
                .map(|n| vec![Value::Uint32(n)]),
            Question::Pin => values
                .remove("pin")
                .filter(|p| (1..=16).contains(&p.chars().count()))
                .map(|p| vec![Value::str(p)]),
        }
    }

    fn wrong(&self) -> &'static str {
        match self {
            Question::Passkey => "A code is up to six digits.",
            _ => "A PIN is 1 to 16 characters.",
        }
    }
}

/// A question on the card: the hold on it, and whether the duty ended it
/// (BlueZ called it off, the pairing is over), not the person.
#[derive(Default)]
struct Asking {
    ender: Option<Ender>,
    ended: bool,
}

/// How a question went, for the duty to answer BlueZ with.
struct Outcome {
    call: u64,
    device: String,
    /// What BlueZ is answered with; an error for no (and for a code shown,
    /// Cancel).
    answer: Result<Vec<Value>, ()>,
}

/// The answer to <question>, from the card; an error for no.
fn answer_on_card(
    ctx: &Context,
    asking: &Mutex<Asking>,
    name: &str,
    question: &Question,
) -> Result<Vec<Value>, ()> {
    let mut dialog = Dialog::open(ctx, &question.ask(name))
        .inspect_err(|e| say!(DUTY, "no card to ask on ({e})"))
        .map_err(|_| ())?;
    {
        let mut asking = asking.lock().map_err(|_| ())?;
        if asking.ended {
            return Err(());
        }
        asking.ender = dialog.ender().ok();
    }
    loop {
        let typed = dialog.answer().ok_or(())?;
        match question.reply(typed) {
            Some(reply) => {
                dialog.done();
                return Ok(reply);
            }
            None => dialog.wrong(question.wrong()).map_err(|_| ())?,
        }
    }
}

/// What the agent's handler and the duty share, on the duty's thread.
#[derive(Default)]
struct Shared {
    /// The device picked and BlueZ's name on the bus, while asked for.
    picked: Option<(String, String)>,
    /// The code shown on the card, so that DisplayPasskey for it again (one
    /// more key typed on the other device) asks nothing new.
    shown: Option<Question>,
    /// The calls the handler took, for the duty.
    calls: Vec<Call>,
    count: u64,
}

/// A call to the agent: a question, kept for its answer unless it is one
/// that BlueZ is answered at once (a code shown); a cancel; a release.
enum Call {
    Ask {
        call: u64,
        device: String,
        question: Question,
        kept: Option<Deferred>,
    },
    Cancel,
    Release,
}

fn agent_interface() -> Interface {
    Interface::new(AGENT)
        .method("Release", "", "")
        .method("RequestPinCode", "o", "s")
        .method("DisplayPinCode", "os", "")
        .method("RequestPasskey", "o", "u")
        .method("DisplayPasskey", "ouq", "")
        .method("RequestConfirmation", "ou", "")
        .method("RequestAuthorization", "o", "")
        .method("AuthorizeService", "os", "")
        .method("Cancel", "", "")
}

/// One of the agent's methods: only BlueZ is answered, and for the device
/// picked alone. A question is handed to the duty, kept for the card's
/// answer.
fn take_call(shared: &mut Shared, call: &Message, args: &[Value]) -> nova_sd::Result<Vec<Value>> {
    let Some((picked, bluez)) = shared.picked.clone() else {
        return Err(Error::bus(REJECTED, "no pairing under way"));
    };
    if call.sender() != Some(bluez.as_str()) {
        return Err(Error::bus(REJECTED, "only BlueZ asks this"));
    }
    let member = call.member().unwrap_or_default();
    match member {
        "Cancel" => {
            shared.calls.push(Call::Cancel);
            return Ok(vec![]);
        }
        "Release" => {
            shared.calls.push(Call::Release);
            return Ok(vec![]);
        }
        _ => {}
    }
    let device = args
        .first()
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    if address_of(&device).as_deref() != Some(picked.as_str()) {
        say!(
            DUTY,
            "turned down {member} from {device}, which was not picked"
        );
        return Err(Error::bus(REJECTED, "not the device being paired"));
    }
    let number = |i: usize| {
        args.get(i)
            .and_then(Value::as_u64)
            .and_then(|n| u32::try_from(n).ok())
            .unwrap_or(0)
    };
    let (question, keep) = match member {
        "RequestConfirmation" => (Question::Confirm(number(1)), true),
        "RequestPasskey" => (Question::Passkey, true),
        "RequestPinCode" => (Question::Pin, true),
        "DisplayPasskey" => (Question::Show(format!("{:06}", number(1))), false),
        "DisplayPinCode" => {
            let pin = args.get(1).and_then(Value::as_str).unwrap_or_default();
            (Question::Show(pin.to_owned()), false)
        }
        "RequestAuthorization" | "AuthorizeService" => return Ok(vec![]),
        _ => {
            return Err(Error::bus(
                "org.freedesktop.DBus.Error.UnknownMethod",
                member,
            ))
        }
    };
    if !keep {
        if shared.shown.as_ref() == Some(&question) {
            return Ok(vec![]);
        }
        shared.shown = Some(question.clone());
    }
    shared.count += 1;
    let kept = if keep { Some(call.defer()?) } else { None };
    shared.calls.push(Call::Ask {
        call: shared.count,
        device,
        question,
        kept,
    });
    Ok(vec![])
}

struct Agent<'a> {
    ctx: &'a Context,
    bus: &'a Bus,
    shared: Rc<RefCell<Shared>>,
    /// The export, while the agent is registered.
    slot: Option<Slot>,
    since: Option<Instant>,
    /// A device whose pairing took too long: not asked for again until the
    /// switch names another, or goes.
    expired: Option<String>,
    /// The calls kept for the card's answer, by number.
    kept: HashMap<u64, Deferred>,
    asking: Arc<Mutex<Asking>>,
    outcomes: Sender<Outcome>,
    waker: Arc<Waker>,
}

impl Agent<'_> {
    fn picked(&self) -> Option<String> {
        self.shared.borrow().picked.as_ref().map(|(d, _)| d.clone())
    }

    /// Asks for <device>'s pairing, or for none.
    fn follow(&mut self, device: Option<String>) {
        if device != self.expired {
            self.expired = None;
        }
        let device = device.filter(|d| self.expired.as_ref() != Some(d));
        if device == self.picked() {
            return;
        }
        self.let_go();
        let Some(device) = device else { return };
        if let Err(e) = self.register(&device) {
            say!(DUTY, "could not be BlueZ's agent: {e}");
            self.let_go();
        }
    }

    fn register(&mut self, device: &str) -> Result<(), String> {
        let bluez = self
            .bus
            .name_owner(BLUEZ)
            .map_err(|e| e.to_string())?
            .ok_or("BlueZ is not running")?;
        let shared = self.shared.clone();
        self.slot = Some(
            self.bus
                .export(
                    AGENT_PATH,
                    vec![agent_interface()],
                    move |call: &Message, args: Vec<Value>| {
                        take_call(&mut shared.borrow_mut(), call, &args)
                    },
                )
                .map_err(|e| e.to_string())?,
        );
        self.shared.borrow_mut().picked = Some((device.to_owned(), bluez));
        self.since = Some(Instant::now());
        let manager = |method: &str, args: &[Value]| {
            self.bus
                .call(BLUEZ, "/org/bluez", AGENT_MANAGER, method, args)
                .map(|_| ())
                .map_err(|e| e.to_string())
        };
        manager(
            "RegisterAgent",
            &[Value::path(AGENT_PATH), Value::str("KeyboardDisplay")],
        )?;
        manager("RequestDefaultAgent", &[Value::path(AGENT_PATH)])?;
        say!(DUTY, "asking for the pairing with {device}");
        Ok(())
    }

    fn let_go(&mut self) {
        self.end_question();
        for (_, kept) in self.kept.drain() {
            let _ = kept.reply(Err(Error::bus(CANCELED, "the pairing is over")));
        }
        let was = {
            let mut shared = self.shared.borrow_mut();
            shared.shown = None;
            shared.picked.take()
        };
        if was.is_some() && self.slot.is_some() {
            let _ = self.bus.call(
                BLUEZ,
                "/org/bluez",
                AGENT_MANAGER,
                "UnregisterAgent",
                &[Value::path(AGENT_PATH)],
            );
            say!(DUTY, "no longer asking");
        }
        self.slot = None;
        self.since = None;
    }

    /// The card's question, ended by the duty: it goes, and its answer is
    /// none.
    fn end_question(&mut self) {
        if let Ok(mut asking) = self.asking.lock() {
            asking.ended = true;
            if let Some(ender) = asking.ender.take() {
                ender.end();
            }
        }
    }

    /// The pairing took too long: let go, and not asked for again for this
    /// device until the switch changes.
    fn expire(&mut self) {
        say!(DUTY, "the pairing took too long");
        self.expired = self.picked();
        self.let_go();
    }

    fn take(&mut self, call: Call) {
        match call {
            Call::Ask {
                call,
                device,
                question,
                kept,
            } => {
                if let Some(kept) = kept {
                    self.kept.insert(call, kept);
                }
                // One question at a time: a new one ends the last.
                self.end_question();
                self.asking = Arc::new(Mutex::new(Asking::default()));
                let name = self.name(&device);
                let (ctx, asking, outcomes, waker) = (
                    self.ctx.clone(),
                    self.asking.clone(),
                    self.outcomes.clone(),
                    self.waker.clone(),
                );
                let started = thread::Builder::new()
                    .name("pairing-ask".into())
                    .spawn(move || {
                        let answer = answer_on_card(&ctx, &asking, &name, &question);
                        if asking.lock().map_or(true, |a| a.ended) {
                            return;
                        }
                        if outcomes
                            .send(Outcome {
                                call,
                                device,
                                answer,
                            })
                            .is_ok()
                        {
                            waker.wake();
                        }
                    });
                if let Err(e) = started {
                    say!(DUTY, "could not ask: {e}");
                }
            }
            // The question is over before its answer: BlueZ waits for none.
            Call::Cancel => {
                self.end_question();
                self.kept.clear();
                self.shared.borrow_mut().shown = None;
            }
            Call::Release => {
                self.end_question();
                self.kept.clear();
                self.shared.borrow_mut().picked = None;
                self.slot = None;
                self.since = None;
            }
        }
    }

    fn answered(&mut self, outcome: Outcome) {
        match self.kept.remove(&outcome.call) {
            Some(kept) => {
                let answer = outcome
                    .answer
                    .map_err(|()| Error::bus(REJECTED, "turned down"));
                if let Err(e) = kept.reply(answer) {
                    say!(DUTY, "could not answer BlueZ: {e}");
                }
            }
            // A code shown, and Cancel pressed: the pairing is called off.
            None if outcome.answer.is_err() => {
                say!(DUTY, "the pairing was cancelled");
                self.shared.borrow_mut().shown = None;
                let _ =
                    self.bus
                        .call_no_reply(BLUEZ, &outcome.device, DEVICE, "CancelPairing", &[]);
            }
            None => {}
        }
    }

    /// The device's name, as BlueZ has it, else its address.
    fn name(&self, device: &str) -> String {
        self.bus
            .call_timeout(
                BLUEZ,
                device,
                "org.freedesktop.DBus.Properties",
                "Get",
                &[Value::str(DEVICE), Value::str("Alias")],
                Some(Duration::from_secs(2)),
            )
            .ok()
            .and_then(|a| {
                a.first()
                    .and_then(|v| v.unvariant().as_str().map(str::to_owned))
            })
            .filter(|a| !a.trim().is_empty())
            .unwrap_or_else(|| address_of(device).unwrap_or_else(|| device.to_owned()))
    }
}

/// Asks BlueZ's questions on <bus> while the switch says so, until the bus goes.
pub fn serve(bus: &Bus, ctx: &Context) -> Result<(), String> {
    serve_at_most(bus, ctx, LONGEST)
}

fn serve_at_most(bus: &Bus, ctx: &Context, longest: Duration) -> Result<(), String> {
    let runtime = ctx
        .runtime_dir()
        .map_err(|e| format!("no runtime folder: {e}"))?
        .to_owned();
    let switch = FolderWatch::new(
        &runtime,
        IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE,
    )
    .map_err(|e| format!("cannot watch {}: {e}", runtime.display()))?;
    let waker = Arc::new(Waker::new().map_err(|e| format!("cannot make a waker: {e}"))?);
    let (outcomes, answered) = mpsc::channel();
    let mut agent = Agent {
        ctx,
        bus,
        shared: Rc::default(),
        slot: None,
        since: None,
        expired: None,
        kept: HashMap::new(),
        asking: Arc::default(),
        outcomes,
        waker: waker.clone(),
    };
    agent.follow(switched_to(ctx));
    let ended = loop {
        let left = agent.since.map(|s| longest.saturating_sub(s.elapsed()));
        let mut fds = [
            bus.poll_fd(),
            PollFd::new(switch.fd(), POLLIN),
            PollFd::new(waker.fd(), POLLIN),
        ];
        if let Err(e) = poll(&mut fds, sooner(bus.timeout(), left)) {
            break format!("could not wait: {e}");
        }
        if fds[1].ready() && switch.names().iter().any(|n| n == SWITCH) {
            agent.follow(switched_to(ctx));
        }
        if agent.since.is_some_and(|s| s.elapsed() >= longest) {
            agent.expire();
        }
        if let Err(e) = bus.dispatch() {
            break format!("the system bus went: {e}");
        }
        let calls = std::mem::take(&mut agent.shared.borrow_mut().calls);
        for call in calls {
            agent.take(call);
        }
        if fds[2].ready() {
            waker.drain();
            while let Ok(outcome) = answered.try_recv() {
                agent.answered(outcome);
            }
        }
    };
    agent.let_go();
    Err(ended)
}

pub fn run(ctx: &Context) -> Result<(), String> {
    // The switch names the session it is for.
    if ctx.session.is_empty() {
        say!(DUTY, "not in a Hyprland session: no pairing asked for here");
        return Ok(());
    }
    let bus = Bus::system().map_err(|e| e.to_string())?;
    serve(&bus, ctx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::write_atomically;
    use crate::prompt::fake::Card;
    use crate::testing::{context, duty, wait_until, Service};
    use nova_sd::testing::{scratch, PrivateBus};
    use nova_sd::Handler;
    use std::any::Any;

    const PIXEL: &str = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01";
    const OTHER: &str = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_02";

    #[test]
    fn addresses_from_the_switch_and_from_bluez_paths() {
        assert_eq!(
            address(" aa:bb:cc:dd:ee:01\n").as_deref(),
            Some("AA:BB:CC:DD:EE:01")
        );
        assert_eq!(address("aa:bb:cc:dd:ee"), None);
        assert_eq!(address("aa:bb:cc:dd:ee:0g"), None);
        assert_eq!(address("aa:bb:cc:dd:ee:011"), None);
        assert_eq!(address_of(PIXEL).as_deref(), Some("AA:BB:CC:DD:EE:01"));
        assert_eq!(address_of("/org/bluez/hci0"), None);
        assert_eq!(address_of("/org/bluez/hci0/dev_AA_BB/x"), None);
    }

    #[test]
    fn what_is_typed_is_answered_only_when_it_is_a_code_or_a_pin() {
        let typed = |id: &str, v: &str| [(id.to_owned(), v.to_owned())].into_iter().collect();
        assert_eq!(
            Question::Passkey.reply(typed("code", "042 913")),
            Some(vec![Value::Uint32(42913)])
        );
        assert_eq!(Question::Passkey.reply(typed("code", "1234567")), None);
        assert_eq!(Question::Passkey.reply(typed("code", "12a")), None);
        assert_eq!(Question::Passkey.reply(typed("code", "")), None);
        assert_eq!(
            Question::Pin.reply(typed("pin", "0000")),
            Some(vec![Value::str("0000")])
        );
        assert_eq!(Question::Pin.reply(typed("pin", "")), None);
        assert_eq!(Question::Pin.reply(typed("pin", &"9".repeat(17))), None);
        assert_eq!(Question::Confirm(1).reply(Default::default()), Some(vec![]));
        assert_eq!(Question::Show("1".into()).reply(Default::default()), None);
        let ask = Question::Confirm(4321).ask("Pixel 8");
        assert_eq!((ask.code.as_str(), ask.accept.as_str()), ("004321", "Pair"));
        assert_eq!(ask.title, "Pair with “Pixel 8”");
        assert!(Question::Show("123456".into()).ask("K").accept.is_empty());
    }

    /// A device, as far as the agent asks it: its name.
    struct Device;

    impl Handler for Device {
        fn call(&mut self, _: &Message, _: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
            Ok(vec![])
        }

        fn get(&mut self, _: &str, property: &str) -> Option<Value> {
            (property == "Alias").then(|| Value::str("Pixel 8"))
        }
    }

    /// What the mock BlueZ heard and was answered: "RegisterAgent …" for a
    /// call to it, and the agent's answers by the question's name.
    type Heard = Arc<Mutex<Vec<String>>>;

    struct Bluez {
        heard: Heard,
        agent: Arc<Mutex<Option<String>>>,
        _slots: Vec<Slot>,
    }

    fn bluez(address: &str) -> (Service, Heard) {
        let heard: Heard = Arc::default();
        let h = heard.clone();
        let service = Service::start(address, move |bus| {
            let agent = Arc::new(Mutex::new(None));
            let (said, who) = (h.clone(), agent.clone());
            let manager = bus
                .export(
                    "/org/bluez",
                    vec![Interface::new(AGENT_MANAGER)
                        .method("RegisterAgent", "os", "")
                        .method("RequestDefaultAgent", "o", "")
                        .method("UnregisterAgent", "o", "")],
                    move |call: &Message, args: Vec<Value>| {
                        let words: Vec<String> = args
                            .iter()
                            .filter_map(|a| a.as_str().map(str::to_owned))
                            .collect();
                        said.lock().unwrap().push(format!(
                            "{} {}",
                            call.member().unwrap(),
                            words.join(" ")
                        ));
                        *who.lock().unwrap() = call.sender().map(str::to_owned);
                        Ok(vec![])
                    },
                )
                .unwrap();
            let said = h.clone();
            let device_calls = bus
                .export(
                    PIXEL,
                    vec![Interface::new(DEVICE).property("Alias", "s").method(
                        "CancelPairing",
                        "",
                        "",
                    )],
                    DeviceLog(Device, said),
                )
                .unwrap();
            let other = bus
                .export(
                    OTHER,
                    vec![Interface::new(DEVICE).property("Alias", "s")],
                    Device,
                )
                .unwrap();
            assert!(bus.request_name(BLUEZ, 0).unwrap());
            Box::new(Bluez {
                heard: h,
                agent,
                _slots: vec![manager, device_calls, other],
            }) as Box<dyn Any>
        });
        (service, heard)
    }

    struct DeviceLog(Device, Heard);

    impl Handler for DeviceLog {
        fn call(&mut self, call: &Message, _: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
            self.1.lock().unwrap().push(format!(
                "{} {}",
                call.member().unwrap(),
                call.path().unwrap()
            ));
            Ok(vec![])
        }

        fn get(&mut self, interface: &str, property: &str) -> Option<Value> {
            self.0.get(interface, property)
        }
    }

    /// BlueZ asks the agent <member>(<args>); the answer is heard as
    /// "<member> ok [values]" or "<member> error <name>".
    fn ask(service: &Service, member: &'static str, args: Vec<Value>) {
        service.send(move |bus, state| {
            let bluez = state.downcast_mut::<Bluez>().unwrap();
            let agent = bluez
                .agent
                .lock()
                .unwrap()
                .clone()
                .expect("an agent registered");
            let heard = bluez.heard.clone();
            bus.call_async(
                &agent,
                AGENT_PATH,
                AGENT,
                member,
                &args,
                None,
                move |answer| {
                    heard.lock().unwrap().push(match answer {
                        Ok(values) => format!("{member} ok {values:?}"),
                        Err(e) => format!("{member} error {}", e.name().unwrap_or("?")),
                    });
                },
            )
            .unwrap();
        });
    }

    fn heard(log: &Heard) -> Vec<String> {
        log.lock().unwrap().clone()
    }

    fn has(log: &Heard, line: &str) -> bool {
        heard(log).iter().any(|l| l == line)
    }

    fn pick(ctx: &Context, device: &str) {
        write_atomically(
            &ctx.runtime.join(SWITCH),
            &format!("{}\n{device}\n", ctx.session),
        )
        .unwrap();
    }

    #[test]
    fn the_device_picked_asks_on_the_card_and_no_other_is_answered() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("pairing");
        let ctx = context(&dir);
        let card = Card::listen(
            &ctx.runtime,
            &[
                Some("{}"),
                Some(r#"{"code":"12a"}"#),
                Some(r#"{"code":"042913"}"#),
                Some(r#"{"pin":"0000"}"#),
                Some("cancel"),
            ],
        );
        let (service, log) = bluez(&private.address);
        let _duty = duty(&private.address, &ctx, serve);
        thread::sleep(Duration::from_millis(200));
        // No pairing under way: no agent.
        assert!(heard(&log).is_empty());
        pick(&ctx, "aa:bb:cc:dd:ee:01");
        wait_until("the agent", || {
            has(&log, "RequestDefaultAgent /org/nova/BluetoothAgent")
        });
        assert!(has(
            &log,
            "RegisterAgent /org/nova/BluetoothAgent KeyboardDisplay"
        ));

        // A code to compare, agreed to.
        ask(
            &service,
            "RequestConfirmation",
            vec![Value::path(PIXEL), Value::Uint32(4321)],
        );
        wait_until("the answer", || has(&log, "RequestConfirmation ok []"));
        let asked = card.lines();
        assert!(asked[0].1.contains(r#""glyph":"bluetooth","title":"Pair with “Pixel 8”","text":"Does “Pixel 8” show this code?","code":"004321""#), "{}", asked[0].1);
        assert!(asked[0].1.contains(r#""accept":"Pair""#));

        // Another device, and a caller that is not BlueZ, are turned down unasked.
        ask(
            &service,
            "RequestConfirmation",
            vec![Value::path(OTHER), Value::Uint32(1)],
        );
        wait_until("the other's answer", || {
            has(&log, "RequestConfirmation error org.bluez.Error.Rejected")
        });
        let stranger = Bus::connect(&private.address).unwrap();
        let agent = service_agent(&service);
        let answer = stranger.call(
            &agent,
            AGENT_PATH,
            AGENT,
            "RequestAuthorization",
            &[Value::path(PIXEL)],
        );
        assert_eq!(answer.unwrap_err().name(), Some(REJECTED));

        // With no code to compare, and its profiles: let in.
        ask(&service, "RequestAuthorization", vec![Value::path(PIXEL)]);
        ask(
            &service,
            "AuthorizeService",
            vec![
                Value::path(PIXEL),
                Value::str("0000110b-0000-1000-8000-00805f9b34fb"),
            ],
        );
        wait_until("let in", || {
            has(&log, "RequestAuthorization ok []") && has(&log, "AuthorizeService ok []")
        });

        // A code typed here: not one, said so, then one.
        ask(&service, "RequestPasskey", vec![Value::path(PIXEL)]);
        wait_until("the code", || {
            has(&log, "RequestPasskey ok [Uint32(42913)]")
        });
        assert!(card
            .lines()
            .iter()
            .any(|(_, l)| l == r#"{"type":"wrong","text":"A code is up to six digits."}"#));

        // A PIN typed here.
        ask(&service, "RequestPinCode", vec![Value::path(PIXEL)]);
        wait_until("the PIN", || {
            has(&log, r#"RequestPinCode ok [Str("0000")]"#)
        });

        // A code to type on the device: shown at once, BlueZ answered at once;
        // shown again as a key is typed there, nothing new; Cancel calls the
        // pairing off.
        let before = card.lines().len();
        ask(
            &service,
            "DisplayPasskey",
            vec![Value::path(PIXEL), Value::Uint32(7), Value::Uint16(0)],
        );
        ask(
            &service,
            "DisplayPasskey",
            vec![Value::path(PIXEL), Value::Uint32(7), Value::Uint16(1)],
        );
        wait_until("the cancelled pairing", || {
            has(&log, &format!("CancelPairing {PIXEL}"))
        });
        assert_eq!(
            heard(&log)
                .iter()
                .filter(|l| l.starts_with("DisplayPasskey ok"))
                .count(),
            2
        );
        let shown: Vec<String> = card.lines()[before..]
            .iter()
            .map(|(_, l)| l.clone())
            .collect();
        assert_eq!(
            shown
                .iter()
                .filter(|l| l.contains(r#""code":"000007""#))
                .count(),
            1,
            "{shown:?}"
        );
        assert!(shown[0].contains(r#""accept":"""#));

        // The pairing over: the agent goes.
        std::fs::remove_file(ctx.runtime.join(SWITCH)).unwrap();
        wait_until("the agent gone", || {
            has(&log, "UnregisterAgent /org/nova/BluetoothAgent")
        });
    }

    fn service_agent(service: &Service) -> String {
        let (tx, rx) = mpsc::channel();
        service.send(move |_, state| {
            let bluez = state.downcast_mut::<Bluez>().unwrap();
            tx.send(bluez.agent.lock().unwrap().clone().unwrap())
                .unwrap();
        });
        rx.recv_timeout(Duration::from_secs(5)).unwrap()
    }

    #[test]
    fn a_question_bluez_calls_off_leaves_the_card_and_a_long_pairing_lets_the_agent_go() {
        let Some(private) = PrivateBus::start() else {
            return;
        };
        let dir = scratch("pairing");
        let ctx = context(&dir);
        // The card is left unanswered.
        let card = Card::listen(&ctx.runtime, &[None]);
        let (service, log) = bluez(&private.address);
        let address = private.address.clone();
        let c = ctx.clone();
        let _duty = thread::spawn(move || {
            let bus = Bus::connect(&address).unwrap();
            serve_at_most(&bus, &c, Duration::from_secs(2))
        });
        // A switch of another session counts for nothing.
        write_atomically(
            &ctx.runtime.join(SWITCH),
            "an-earlier-session\nAA:BB:CC:DD:EE:01\n",
        )
        .unwrap();
        thread::sleep(Duration::from_millis(300));
        assert!(heard(&log).is_empty());
        pick(&ctx, "AA:BB:CC:DD:EE:01");
        wait_until("the agent", || {
            has(&log, "RequestDefaultAgent /org/nova/BluetoothAgent")
        });
        ask(
            &service,
            "RequestConfirmation",
            vec![Value::path(PIXEL), Value::Uint32(1)],
        );
        wait_until("the card", || card.lines().len() == 1);
        ask(&service, "Cancel", vec![]);
        // The card is ended: its connection closes, and nothing is answered
        // for the question BlueZ called off.
        wait_until("Cancel answered", || has(&log, "Cancel ok []"));
        thread::sleep(Duration::from_millis(200));
        assert!(!heard(&log)
            .iter()
            .any(|l| l.starts_with("RequestConfirmation")));
        // Two seconds on, the switch still there: the agent goes, and is not
        // asked for again by the same switch.
        wait_until("the agent gone", || {
            has(&log, "UnregisterAgent /org/nova/BluetoothAgent")
        });
        pick(&ctx, "AA:BB:CC:DD:EE:01");
        thread::sleep(Duration::from_millis(300));
        assert_eq!(
            heard(&log)
                .iter()
                .filter(|l| l.starts_with("RegisterAgent"))
                .count(),
            1
        );
    }
}
