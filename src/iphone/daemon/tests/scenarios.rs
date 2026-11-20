//! nova-iphone-notifications, the whole service on a D-Bus bus of its own,
//! against a fake BlueZ with a fake iPhone behind it and a fake notification
//! server (tests/common). Nothing here reaches the computer's Bluetooth: the
//! service is told that BlueZ is on the private bus. Each scenario has a bus,
//! a scratch and a service of its own, and spends its seconds waiting on the
//! service's timers, not working, so `cargo test` runs them side by side.
//! Its ANCS byte for byte, and the rest of what can be tried without a bus,
//! are the unit tests in src.

mod common;

use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use common::*;
use nova_sd::{Error, Value};

const DAEMON: &str = env!("CARGO_BIN_EXE_nova-iphone-notifications");
const UNIT: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../nova-iphone-notifications.service"
);

/// The fake and the service, or a return from the test where there is no
/// dbus-daemon to make a bus with.
macro_rules! scenario {
    ($($env:expr),*) => {
        match Sim::start(DAEMON, UNIT, &[$($env),*]) {
            Some(sim) => sim,
            None => return,
        }
    };
}

/// Whether the service advertises in <mode>, by the interval it asked for.
fn advertising(fake: &Fake, mode: &str) -> bool {
    let low = match mode {
        "pairing" => 100.0,
        "fast" => 20.0,
        _ => 1285.0,
    };
    fake.advertising
        .as_ref()
        .is_some_and(|a| a.2.get("MinInterval").and_then(Json::as_f64) == Some(low))
}

fn state_is(fake: &Fake, state: &str) -> bool {
    fake.state_of("state") == state
}

fn yes() -> Vec<Value> {
    vec![Value::Bool(true)]
}

fn no() -> Vec<Value> {
    vec![Value::Bool(false)]
}

#[test]
fn pairing() {
    let f = scenario!();
    f.until("no iPhone at first", |s| state_is(s, "no-iphone"));
    f.check_that("with no iPhone it neither advertises nor can pair", |s| {
        s.advertising.is_none() && s.agent.is_none()
    });
    f.m().call_daemon("Pair", no());
    f.until("the pairing window opens", |s| {
        s.agent.is_some() && advertising(s, "pairing")
    });
    let advert = f.s().advertising.clone().expect("an advertisement").2;
    f.check(
        advert
            == Json::obj(vec![
                ("Type", Json::str("peripheral")),
                ("SolicitUUIDs", Json::strings(&[ANCS])),
                ("Discoverable", Json::Bool(true)),
                ("LocalName", Json::str("Test Laptop")),
                ("MinInterval", Json::num(100)),
                ("MaxInterval", Json::num(150)),
            ]),
        "the pairing advertisement: discoverable, the computer's name, ANCS solicited, 100-150 ms",
    );
    f.check_that("Settings is told the window is open, and until when", |s| {
        s.state_of("state") == "pairing"
            && s.state()
                .get("pairingUntil")
                .and_then(Json::as_f64)
                .unwrap_or(0.0)
                > now()
    });
    f.check_that("and says what the advertisement shows", |s| {
        s.said()
            .contains("\"Discoverable\": true, \"LocalName\": \"Test Laptop\"")
    });

    f.m().add_phone(false, true);
    f.until(
        "the advertisement stops once the iPhone has connected",
        |s| s.advertising.is_none(),
    );
    f.until("the code is shown to compare", |s| {
        !s.questions().is_empty()
    });
    let ask = f.s().questions()[0].clone();
    f.check(
        ask.summary == "Pair with \u{201c}Test iPhone\u{201d}?"
            && ask.body == "Check that your iPhone shows 123456."
            && ask.app == "nova-action"
            && ask.urgency == 2,
        "the question names the iPhone and gives the code, and stays until answered",
    );
    f.check(
        ask.argvs()
            == vec![
                vec!["nova-notification-iphone", "answer", "no"],
                vec!["nova-notification-iphone", "answer", "yes"],
            ]
            && ask.main_button(1),
        "Cancel and Pair, Pair the main one",
    );
    // A button closes the notification as it runs its command: the answer
    // comes a moment after the close.
    f.m().close_note(ask.id, 2);
    f.pause(0.5);
    f.m().call_daemon("Answer", yes());
    f.until("connected and subscribed after the pairing", |s| {
        state_is(s, "connected")
    });
    f.check_that(
        "the Data Source subscribed first, then the Notification Source",
        |s| s.subscriptions.len() >= 2 && s.subscriptions[..2] == ["ds", "ns"],
    );
    f.until("the pairing agent goes once paired", |s| s.agent.is_none());
    f.check_that("no advertising while the iPhone is connected", |s| {
        s.advertising.is_none()
    });
    f.check_that(
        "the connection's parameters, as the iPhone chose them, for Settings and the journal",
        |s| {
            s.state().get("link")
                == Some(&Json::obj(vec![
                    ("interval", Json::num(30.0)),
                    ("latency", Json::num(0)),
                    ("timeout", Json::num(720)),
                ]))
        },
    );

    f.m().note(1, b"com.apple.MobileSMS", b"Anna", b"Hi");
    f.m().event(0, 16, 4, 1);
    f.until("a message after pairing is shown", |s| {
        s.note_for("Messages \u{b7} Anna").is_some()
    });

    f.m().connect(false);
    f.until("the iPhone gone, it advertises fast", |s| {
        advertising(s, "fast")
    });
    f.check_that(
        "for the iPhone to come back: not discoverable, no name, 20-30 ms",
        |s| {
            s.advertising.as_ref().map(|a| &a.2)
                == Some(&Json::obj(vec![
                    ("Type", Json::str("peripheral")),
                    ("SolicitUUIDs", Json::strings(&[ANCS])),
                    ("Discoverable", Json::Bool(false)),
                    ("MinInterval", Json::num(20)),
                    ("MaxInterval", Json::num(30)),
                ]))
        },
    );
    f.until("then slowly", |s| advertising(s, "slow"));
    f.check_that("every 1285 ms", |s| {
        s.advertising.as_ref().and_then(|a| a.2.get("MaxInterval")) == Some(&Json::num(1285))
    });
    f.check_that("Settings says the iPhone is not connected", |s| {
        state_is(s, "waiting")
    });
    f.check_that("and the agent went with the window", |s| {
        s.said().contains("agent unregistered")
    });
    f.finish();
}

#[test]
fn declined() {
    let f = scenario!();
    f.until("no iPhone at first", |s| state_is(s, "no-iphone"));
    f.m().call_daemon("Pair", no());
    f.until("the pairing window opens", |s| {
        s.agent.is_some() && advertising(s, "pairing")
    });
    f.m().add_phone(false, true);
    f.until("the code is shown to compare", |s| {
        !s.questions().is_empty()
    });
    f.m().call_daemon("Answer", no());
    f.until("the subscription that asked", |s| {
        s.subscriptions.contains(&"ds")
    });
    f.pause(2.0);
    f.check_that("turned down, it is not asked again on the same link", |s| {
        s.questions().len() == 1 && s.subscriptions == ["ds"]
    });
    f.check_that(
        "not paired, and the window still open for another try",
        |s| {
            s.property(PHONE, DEVICE, "Paired")
                .and_then(|v| v.as_bool())
                == Some(false)
                && s.state_of("state") == "pairing"
        },
    );
    f.check_that("and BlueZ was told no", |s| {
        s.said()
            .contains("pairing: refused, org.bluez.Error.Rejected")
    });
    f.finish();
}

#[test]
fn strangers() {
    let f = scenario!(("NOVA_IPHONE_PAIR_SECONDS", "10"));
    f.until("no iPhone at first", |s| state_is(s, "no-iphone"));
    // The pairing agent BlueZ will not make the default: registered, it would
    // still be asked, so it is unregistered, and the window closes.
    f.m().fail_default = true;
    f.m().call_daemon("Pair", no());
    f.until("an agent not made the default is unregistered", |s| {
        s.registrations == 1 && s.agent.is_none()
    });
    f.until("and the window closes", |s| state_is(s, "no-iphone"));
    f.check_that("with nothing advertised", |s| s.advertising.is_none());
    f.m().fail_default = false;
    f.check_that("it said so, and let the agent go", |s| {
        s.said_in_order(&["agent not made the default", "agent unregistered"])
    });

    // A device with a name of its choosing: bidirectional characters, too long.
    let name = format!("\u{202e}enohPi\u{2066} {}", "x".repeat(80));
    f.m().add_stranger(&name);
    f.m().pair(STRANGER, "confirm", None);
    f.until("a pairing it begins outside the window", |s| {
        s.pairings.len() == 1
    });
    f.check_that(
        "outside the window there is no agent: BlueZ turns the pairing down, and nothing is asked",
        |s| s.pairings[0].1 == "refused, not bondable: no agent" && s.notes.is_empty(),
    );

    f.m().call_daemon("Pair", no());
    f.until("the window opens, with an agent", |s| s.agent.is_some());
    f.m().pair(STRANGER, "justworks", None);
    f.until("a pairing with no code to compare", |s| {
        s.pairings.len() == 2
    });
    f.check_that(
        "with no code to compare (Just Works): turned down, nothing asked",
        |s| s.pairings[1].1 == "refused, org.bluez.Error.Rejected" && s.notes.is_empty(),
    );
    f.check_that("and the service said why", |s| {
        s.said()
            .contains("turned down a pairing with no code to compare")
    });

    // Anyone on the bus may call the agent: only BlueZ is answered.
    let other = f.connect_another();
    let answers = Rc::new(RefCell::new(Vec::<String>::new()));
    let (sender, path) = f.s().agent.clone().expect("an agent");
    let collected = answers.clone();
    other
        .call_async(
            &sender,
            &path,
            AGENT,
            "RequestConfirmation",
            &[Value::path(STRANGER), Value::Uint32(111111)],
            Some(Duration::from_secs(10)),
            move |result| {
                collected.borrow_mut().push(match result {
                    Ok(_) => "agreed".to_owned(),
                    Err(error) => error.name().unwrap_or("").to_owned(),
                })
            },
        )
        .expect("a call to the agent");
    f.until("an agent's question from another program", |_| {
        !answers.borrow().is_empty()
    });
    f.check(
        *answers.borrow() == ["org.bluez.Error.Rejected"] && f.s().notes.is_empty(),
        "from another program than BlueZ: turned down, nothing asked",
    );

    f.m().pair(STRANGER, "confirm", None);
    f.until("the code is shown to compare", |s| {
        !s.questions().is_empty()
    });
    let ask = f.s().questions()[0].clone();
    f.check(
        ask.summary
            == format!(
                "Pair with \u{201c}enohPi {}\u{2026}\u{201d}?",
                "x".repeat(51)
            ),
        "the device's name as plain text: no bidirectional characters, cut short",
    );

    // An iPhone asking meanwhile is turned down; the first question stands.
    f.m().add_phone(false, true);
    f.until("a second pairing while the first is asked about", |s| {
        s.pairings.len() == 3
    });
    f.check_that("the second one is turned down", |s| {
        s.pairings[2]
            == (
                PHONE.to_owned(),
                "refused, org.bluez.Error.Rejected".to_owned(),
            )
    });
    f.check_that("the first question stays, and no second is asked", |s| {
        !s.closed.contains(&ask.id) && s.questions().len() == 1
    });
    f.check_that("and the service said why", |s| {
        s.said()
            .contains("turned down a second pairing while one is asked about")
    });
    f.m().call_daemon("Answer", yes());
    f.until("the first question answered", |s| s.pairings.len() == 4);
    f.check_that("the answer goes to the first one", |s| {
        s.pairings[3] == (STRANGER.to_owned(), "agreed".to_owned())
    });

    // The window over, the agent goes, and BlueZ lets nothing pair.
    f.until_within(20, "the window closes", |s| {
        s.state_of("state") != "pairing" && s.agent.is_none()
    });
    f.m().pair(STRANGER, "confirm", None);
    f.until("a pairing begun after the window", |s| {
        s.pairings.len() == 5
    });
    f.check_that("after the window: no agent, nothing pairs", |s| {
        s.pairings[4].1 == "refused, not bondable: no agent"
    });
    f.finish();
}

#[test]
fn notifications() {
    let f = scenario!();
    f.m()
        .note(1, b"net.whatsapp.WhatsApp", b"Old", b"Old message");
    f.m().add_phone(true, true);
    f.until("a paired iPhone connects without asking anything", |s| {
        state_is(s, "connected")
    });
    f.check_that(
        "no agent and no question for an iPhone paired before",
        |s| s.agent.is_none() && s.notes.is_empty(),
    );

    f.m().event(0, 4 | 16, 4, 1); // there before the connection
    f.pause(0.5);
    f.check_that(
        "what the iPhone had before the connection is not shown",
        |s| s.writes.is_empty() && s.notes.is_empty(),
    );

    f.m().note(2, b"net.whatsapp.WhatsApp", b"Anna", b"Ciao <3");
    f.m().event(0, 16, 4, 2);
    f.until("a new message is shown", |s| {
        s.note_for("WhatsApp \u{b7} Anna").is_some()
    });
    f.check_that(
        "its attributes asked for: the app, the title, subtitle and message with their limits",
        |s| s.writes[0] == "00 02 00 00 00 00 01 80 00 02 80 00 03 40 01",
    );
    f.check_that("then the app's name, once", |s| {
        s.writes[1] == format!("01 {} 00 00", hex(b"net.whatsapp.WhatsApp"))
    });
    let shown = f.s().note_for("WhatsApp \u{b7} Anna").expect("a note");
    f.check(
        shown.app == "WhatsApp"
            && shown.body == "Ciao &lt;3"
            && shown.glyph == "U+F0369"
            && !shown.quiet
            && shown.actions == ["default", "Show"]
            && shown.urgency == 1,
        "as the app, its markup escaped, a message's glyph, a click a dismissal",
    );

    f.m()
        .note(3, b"net.whatsapp.WhatsApp", b"Group", b"Quiet one");
    f.m().event(0, 1 | 16, 4, 3);
    f.until("a quiet one goes to the shell", |s| {
        s.note_for("WhatsApp \u{b7} Group").is_some()
    });
    f.check_that("marked quiet: to the history, no toast", |s| {
        s.note_for("WhatsApp \u{b7} Group").is_some_and(|n| n.quiet)
    });
    f.check_that("the app's name is not asked again", |s| s.writes.len() == 3);

    f.m().note(4, b"com.apple.mobilephone", b"Mum", b"");
    f.m().event(0, 8 | 16, 1, 4);
    f.pause(0.5);
    f.check_that("an incoming call is neither asked about nor shown", |s| {
        s.writes.len() == 3 && s.notes.len() == 2
    });

    f.m().event(2, 0, 4, 2);
    f.until("removed on the iPhone, taken down here", |s| {
        s.closed.contains(&shown.id)
    });

    f.m()
        .note(5, b"net.whatsapp.WhatsApp", b"Bea", b"Dismiss me");
    f.m().event(0, 16, 4, 5);
    f.until("another is shown", |s| {
        s.note_for("WhatsApp \u{b7} Bea").is_some()
    });
    let bea = f.s().note_for("WhatsApp \u{b7} Bea").expect("a note").id;
    f.m().close_note(bea, 2);
    f.until("dismissed here, it is cleared on the iPhone", |s| {
        s.writes.contains(&"02 05 00 00 00 01".to_owned())
    });
    f.check_that("and the service wrote the clearing", |s| {
        s.said().contains("write: 02 05 00 00 00 01")
    });

    f.m()
        .note(6, b"net.whatsapp.WhatsApp", b"Cara", b"Let me run out");
    f.m().event(0, 16, 4, 6);
    f.until("another is shown", |s| {
        s.note_for("WhatsApp \u{b7} Cara").is_some()
    });
    let count = f.s().writes.len();
    let cara = f.s().note_for("WhatsApp \u{b7} Cara").expect("a note").id;
    f.m().close_note(cara, 1);
    f.pause(0.5);
    f.check_that("one that ran out stays on the iPhone", |s| {
        s.writes.len() == count
    });
    f.m().event(1, 16, 4, 6);
    f.pause(0.5);
    f.check_that("a change to one no longer shown shows nothing", |s| {
        s.writes.len() == count && s.notes.len() == 4
    });

    f.m()
        .note(7, b"com.apple.MobileSMS", b"Dan", b"No clearing");
    f.m().event(0, 0, 4, 7);
    f.until("one the iPhone cannot clear is shown", |s| {
        s.note_for("Messages \u{b7} Dan").is_some()
    });
    let count = f.s().writes.len();
    let dan = f.s().note_for("Messages \u{b7} Dan").expect("a note").id;
    f.m().close_note(dan, 2);
    f.pause(0.5);
    f.check_that(
        "dismissed, nothing is asked of the iPhone it has no action for",
        |s| s.writes.len() == count,
    );

    f.m().event(0, 16, 6, 9); // the iPhone no longer has it (0xA2)
    f.m().note_with(
        10,
        b"com.apple.MobileSMS",
        b"Eve",
        b"After a refusal",
        b"Re: plans",
        None,
    );
    f.m().event(0, 16, 6, 10);
    f.until("a refused command does not hold up the next", |s| {
        s.note_for("Messages \u{b7} Eve").is_some()
    });
    f.check_that("the subtitle above the message; mail's glyph", |s| {
        s.note_for("Messages \u{b7} Eve")
            .is_some_and(|n| n.body == "Re: plans\nAfter a refusal" && n.glyph == "U+F01EE")
    });
    f.check_that("nothing shown for the refused one", |s| {
        s.note_for("WhatsApp \u{b7} ").is_none() && s.notes.iter().all(|n| !n.summary.contains('9'))
    });
    f.finish();
}

#[test]
fn reused() {
    let f = scenario!();
    f.m().add_phone(true, true);
    f.until("connected", |s| state_is(s, "connected"));
    f.m()
        .note(5, b"net.whatsapp.WhatsApp", b"Anna", b"Before the drop");
    f.m().event(0, 16, 4, 5);
    f.until("a notification shown", |s| {
        s.note_for("WhatsApp \u{b7} Anna").is_some()
    });
    let old = f.s().note_for("WhatsApp \u{b7} Anna").expect("a note");
    f.m().connect(false);
    f.until("the link drops, its toast still on screen", |s| {
        state_is(s, "waiting")
    });
    f.m().connect(true);
    f.until("back", |s| state_is(s, "connected"));
    // The iPhone numbers its notifications anew: uid 5 is another one now.
    f.m()
        .note(5, b"net.whatsapp.WhatsApp", b"Bea", b"After the drop");
    f.m().event(0, 16, 4, 5);
    f.until("a new notification under the same uid", |s| {
        s.note_for("WhatsApp \u{b7} Bea").is_some()
    });
    let new = f.s().note_for("WhatsApp \u{b7} Bea").expect("a note");
    let count = f.s().writes.len();
    f.m().close_note(old.id, 2);
    f.pause(0.5);
    f.check_that(
        "the old toast dismissed: nothing cleared on the iPhone, where its uid is another's",
        |s| s.writes.len() == count,
    );
    f.m().close_note(new.id, 2);
    f.until("the new one dismissed is cleared on the iPhone", |s| {
        s.writes[count..].contains(&"02 05 00 00 00 01".to_owned())
    });
    f.finish();
}

#[test]
fn changing() {
    let f = scenario!();
    f.m().add_phone(true, true);
    f.until("connected", |s| state_is(s, "connected"));
    f.m().note(5, b"net.whatsapp.WhatsApp", b"Anna", b"First");
    f.m().event(0, 16, 4, 5);
    f.until("a notification shown", |s| {
        s.note_for("WhatsApp \u{b7} Anna").is_some()
    });
    let old = f.s().note_for("WhatsApp \u{b7} Anna").expect("a note");
    // It changes on the iPhone; the change is on its way to the shell when
    // the toast is dismissed.
    f.m().hold_notify = true;
    f.m().note(5, b"net.whatsapp.WhatsApp", b"Anna", b"Changed");
    f.m().event(1, 16, 4, 5);
    f.until("the change on its way to the shell", |s| {
        !s.held_notes.is_empty()
    });
    let changed = f.s().notes.last().expect("a note").clone();
    f.check(
        changed.replaces == old.id,
        "a change replaces the toast shown",
    );
    let count = f.s().writes.len();
    f.m().close_note(old.id, 2);
    f.until("dismissed meanwhile: cleared on the iPhone", |s| {
        s.writes[count..].contains(&"02 05 00 00 00 01".to_owned())
    });
    f.m().hold_notify = false;
    let (answer, id) = f.m().held_notes.pop().expect("a held reply");
    answer
        .reply(Ok(vec![Value::Uint32(id)]))
        .expect("the reply");
    f.until(
        "the change, shown anew by the shell, is closed: dismissed, it stays so",
        |s| s.closed.contains(&changed.id),
    );
    f.finish();
}

#[test]
fn evicted() {
    let f = scenario!();
    f.m().add_phone(true, true);
    f.until("connected", |s| state_is(s, "connected"));
    // More than the service remembers of what the iPhone has (1000): the six
    // listed first fall out, and look new when the link is back.
    let listed: Vec<u32> = (1000..2006).collect();
    for uid in &listed {
        f.m().event(0, 4, 4, *uid);
    }
    for uid in &listed[..6] {
        f.m().note_with(
            *uid,
            b"com.apple.MobileSMS",
            format!("Old {uid}").as_bytes(),
            b"old",
            b"",
            Some(b"20200101T000000"),
        );
    }
    f.pause(1.0);
    f.m().connect(false);
    f.until("the link drops", |s| state_is(s, "waiting"));
    f.m()
        .note(3000, b"com.apple.MobileSMS", b"Cat", b"in the gap");
    f.m().connect(true);
    f.until("back a moment later", |s| state_is(s, "connected"));
    for uid in listed.iter().chain([&3000]) {
        f.m().event(0, 4, 4, *uid);
    }
    f.until_within(
        20,
        "the one that came in the gap is shown, the six old ones looked at first",
        |s| s.note_for("Messages \u{b7} Cat").is_some(),
    );
    f.check_that("the old ones are not", |s| {
        !s.notes
            .iter()
            .any(|n| n.summary.starts_with("Messages \u{b7} Old"))
    });
    f.finish();
}

#[test]
fn asking() {
    let f = scenario!();
    f.until("no iPhone at first", |s| state_is(s, "no-iphone"));
    f.m().call_daemon("Pair", no());
    f.until("the window opens, with an agent", |s| s.agent.is_some());
    f.m().add_stranger("Test iPhone");
    f.m().pair(STRANGER, "confirm", None);
    f.until("the code is shown to compare", |s| {
        !s.questions().is_empty()
    });
    let first = f.s().questions()[0].clone();
    // BlueZ restarts while the question is open, and forgets its agents.
    f.m().release_bluez();
    f.m().agent = None;
    f.m().own_bluez();
    f.until(
        "BlueZ gone: the question withdrawn, its toast closed",
        |s| s.closed.contains(&first.id) && !s.pairings.is_empty(),
    );
    f.check_that("the pairing it was about turned down", |s| {
        s.pairings.last()
            == Some(&(
                STRANGER.to_owned(),
                "refused, org.bluez.Error.Rejected".to_owned(),
            ))
    });
    f.check_that("and the service said why", |s| {
        s.said()
            .contains("pairing question withdrawn: BlueZ restarted")
    });
    f.until(
        "the agent registered with the BlueZ back, the window still open",
        |s| s.agent.is_some(),
    );
    f.m().pair(STRANGER, "confirm", None);
    f.until(
        "a pairing the BlueZ back asks about is asked, not turned down as a second one",
        |s| s.questions().len() == 2,
    );
    f.finish();
}

#[test]
fn hostile() {
    let f = scenario!();
    // An iPhone, or what passes for one, that keeps to no limit.
    f.m().apps.insert(
        b"com.example.loud".to_vec(),
        format!("\u{2066}Loud\u{2069}{}", "x".repeat(100)).into_bytes(),
    );
    f.m().add_phone(true, true);
    f.until("connected", |s| state_is(s, "connected"));
    f.m().note_with(
        1,
        b"com.example.loud",
        format!("\u{202e}{}", "A".repeat(1000)).as_bytes(),
        "B".repeat(3000).as_bytes(),
        "\u{200b}Sub\u{200d}title".as_bytes(),
        None,
    );
    f.m().event(0, 16, 4, 1);
    f.until("the oversize one is shown", |s| {
        s.notes.iter().any(|n| n.summary.starts_with("Loud"))
    });
    let shown = f
        .s()
        .notes
        .iter()
        .find(|n| n.summary.starts_with("Loud"))
        .expect("a note")
        .clone();
    f.check(
        shown.app == format!("Loud{}\u{2026}", "x".repeat(54))
            && shown.summary == format!("{} \u{b7} {}\u{2026}", shown.app, "A".repeat(125)),
        "the app's name and the title cut at their limits, the bidirectional characters gone",
    );
    f.check(
        shown.body == format!("Sub\u{200d}title\n{}\u{2026}", "B".repeat(320)),
        "the message cut at its limit; format characters gone but the joiner",
    );

    // An answer longer than any asked for is given up on, and the next one
    // is read past what is left of it.
    f.m().note(
        2,
        b"com.apple.MobileSMS",
        b"Big",
        "C".repeat(9000).as_bytes(),
    );
    f.m().event(0, 16, 4, 2);
    f.m()
        .note(3, b"com.apple.MobileSMS", b"After", b"the big one");
    f.m().event(0, 16, 4, 3);
    f.until("the next one is shown", |s| {
        s.note_for("Messages \u{b7} After").is_some()
    });
    f.check_that("the one with the long answer is not", |s| {
        s.note_for("Messages \u{b7} Big").is_none()
    });
    f.check_that("and the service said why", |s| {
        s.said()
            .contains("an answer that does not fit: an answer of more than 8192 bytes")
    });

    // A flood: two hundred at once. Fifty are followed, the rest passed over.
    let before = f.s().notes.len();
    for uid in 100..300 {
        f.m().note(
            uid,
            b"com.apple.MobileSMS",
            format!("Flood {uid}").as_bytes(),
            b"x",
        );
        f.m().event(0, 16, 4, uid);
    }
    f.until_within(20, "the flood's first fifty shown", |s| {
        s.notes.len() - before >= 50
    });
    f.pause(1.0);
    f.check_that("of a flood, the first fifty only", |s| {
        let flood: Vec<&Note> = s.notes[before..]
            .iter()
            .filter(|n| n.summary.starts_with("Messages \u{b7} Flood"))
            .collect();
        flood.len() == 50
            && flood[0].summary == "Messages \u{b7} Flood 100"
            && flood[49].summary == "Messages \u{b7} Flood 149"
    });
    f.check_that("and the service said so once", |s| {
        s.transcript
            .iter()
            .filter(|l| l.contains("more than 50 notifications at once"))
            .count()
            == 1
    });
    f.m()
        .note(400, b"com.apple.MobileSMS", b"Later", b"after the flood");
    f.m().event(0, 16, 4, 400);
    f.until("after the flood, a new one is shown", |s| {
        s.note_for("Messages \u{b7} Later").is_some()
    });
    f.finish();
}

#[test]
fn late() {
    let f = scenario!(("NOVA_IPHONE_FAST_SECONDS", "60"));
    // BlueZ restarts while a registration waits for its answer. The new BlueZ
    // refuses the registration asked of it; then the answer of the one
    // before comes, a yes, which is no longer true of anything.
    f.m().hold = true;
    f.m().add_phone(true, false);
    f.until("a registration BlueZ has not answered", |s| {
        s.held.len() == 1
    });
    f.m().release_bluez();
    f.m().own_bluez();
    f.until("BlueZ back, and asked again", |s| s.held.len() == 2);
    let refuse = f.m().held[1].take().expect("a held registration");
    refuse
        .reply(Err(Error::bus("org.bluez.Error.Failed", "Failed")))
        .expect("the refusal");
    f.pause(0.3);
    let ok = f.m().held[0].take().expect("a held registration");
    ok.reply(Ok(vec![])).expect("the answer");
    f.m().hold = false;
    f.pause(0.5);
    f.check_that("the answer of the BlueZ before counts for nothing", |s| {
        s.state_of("advertising").is_empty()
    });
    f.until_within(
        10,
        "after its wait, it asks the new BlueZ again, as nothing is advertised",
        |s| advertising(s, "fast"),
    );
    f.finish();
}

#[test]
fn taken() {
    let f = scenario!();
    f.until("the service runs", |s| state_is(s, "no-iphone"));
    let second = std::process::Command::new(f.binary())
        .envs(f.s().env.iter().map(|(k, v)| (k, v)))
        .output()
        .expect("a second service");
    f.m()
        .say(String::from_utf8_lossy(&second.stderr).trim().to_owned());
    let code = second.status.code();
    f.check(
        code == Some(3),
        &format!(
            "a second one, its name taken, ends with 3 ({})",
            code.map_or("a signal".into(), |c| c.to_string())
        ),
    );
    f.check(
        f.unit().contains("\nRestartPreventExitStatus=3\n"),
        "which its unit does not start again",
    );
    f.check_that("and the running one's state is left alone", |s| {
        state_is(s, "no-iphone")
    });
    f.finish();
}

#[test]
fn reconnect() {
    let f = scenario!();
    f.m().note(1, b"com.apple.MobileSMS", b"Ann", b"one");
    f.m().note(2, b"com.apple.MobileSMS", b"Ben", b"two");
    f.m().add_phone(true, true);
    f.until("connected", |s| state_is(s, "connected"));
    f.m().event(0, 4, 4, 1);
    f.m().event(0, 4, 4, 2);
    f.pause(0.3);
    f.m().connect(false);
    f.until("the link drops", |s| state_is(s, "waiting"));
    // In the gap: one message came; and the iPhone has one from long ago
    // that it had not listed before (it numbers them afresh after a restart).
    f.m().note(7, b"com.apple.MobileSMS", b"Cat", b"in the gap");
    f.m().note_with(
        8,
        b"com.apple.MobileSMS",
        b"Old",
        b"long ago",
        b"",
        Some(b"20200101T000000"),
    );
    f.pause(0.3);
    f.m().connect(true);
    f.until("back a moment later", |s| state_is(s, "connected"));
    let count = f.s().writes.len();
    for uid in [1, 2, 7, 8] {
        f.m().event(0, 4, 4, uid);
    }
    f.until("the message that came in the gap is shown", |s| {
        s.note_for("Messages \u{b7} Cat").is_some()
    });
    f.pause(0.5);
    let asked: Vec<String> = f.s().writes[count..].to_vec();
    f.check(
        asked[0] == "00 07 00 00 00 00 01 80 00 02 80 00 03 40 01 05",
        "for one not listed before the gap, its date is asked for too",
    );
    f.check(
        !asked
            .iter()
            .any(|w| w.starts_with("00 01 ") || w.starts_with("00 02 ")),
        "those listed before the gap are not asked about again",
    );
    f.check_that("one dated before the gap is not shown", |s| {
        s.note_for("Messages \u{b7} Old").is_none()
    });
    f.finish();
}

#[test]
fn restarts() {
    let f = scenario!();
    f.m().add_phone(true, false);
    f.until("a paired iPhone away: advertising fast", |s| {
        advertising(s, "fast")
    });
    f.until("then slowly", |s| advertising(s, "slow"));
    f.check_that("waiting for the iPhone", |s| state_is(s, "waiting"));

    f.m().release_bluez();
    f.m().say("bluez: stopped");
    f.m().advertising = None;
    f.until("BlueZ gone: no Bluetooth", |s| state_is(s, "no-bluetooth"));
    f.m().own_bluez();
    f.m().say("bluez: started");
    f.until("BlueZ back: advertising fast again", |s| {
        advertising(s, "fast")
    });

    // The card's firmware resets: BlueZ lets the advertisement go and the
    // controller with it, then the controller comes back.
    f.m().release();
    let adapter = f.s().node_interfaces(ADAPTER_PATH);
    f.m().remove(ADAPTER_PATH);
    f.until("the controller gone", |s| state_is(s, "no-bluetooth"));
    f.m().add(ADAPTER_PATH, adapter);
    f.until(
        "the controller back: advertising fast again, without waiting",
        |s| advertising(s, "fast"),
    );

    f.m()
        .update(ADAPTER_PATH, ADAPTER, vec![("Powered", Value::Bool(false))]);
    f.until("Bluetooth turned off: nothing advertised", |s| {
        s.advertising.is_none() && state_is(s, "bluetooth-off")
    });
    f.m()
        .update(ADAPTER_PATH, ADAPTER, vec![("Powered", Value::Bool(true))]);
    f.until("on again: advertising fast", |s| advertising(s, "fast"));

    let conf = f.s().scratch.join("main.conf");
    std::fs::write(conf, "[General]\nControllerMode = bredr\n").expect("main.conf");
    f.m().release_bluez();
    f.m().advertising = None;
    f.pause(0.3);
    f.m().own_bluez();
    f.until("with Bluetooth LE off, it says so", |s| {
        state_is(s, "no-le")
    });
    f.pause(0.5);
    f.check_that("and advertises nothing", |s| s.advertising.is_none());
    f.finish();
}

/// What a notification says goes to the shell alone: the log has none of it.
/// A whole log statement is looked at, up to its semicolon, as rustfmt may
/// spread one over several lines.
#[test]
fn it_never_logs_what_a_notification_says() {
    let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut offenders = Vec::new();
    let mut looked = 0;
    for entry in std::fs::read_dir(&source).expect("the source folder") {
        let path = entry.expect("a file").path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }
        let code = std::fs::read_to_string(&path).expect("a source file");
        looked += 1;
        for (at, _) in code.match_indices("log(") {
            let statement = code[at..].split(';').next().unwrap_or("");
            if ["summary", "body", "title", "subtitle", "info.", "found"]
                .iter()
                .any(|word| statement.contains(word))
            {
                offenders.push(format!(
                    "{}: {}",
                    path.display(),
                    statement.lines().next().unwrap_or("")
                ));
            }
        }
    }
    assert!(looked >= 4, "the sources were not found");
    assert!(
        offenders.is_empty(),
        "log statements that may carry a text: {offenders:#?}"
    );
}
