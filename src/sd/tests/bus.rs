//! nova-sd's D-Bus against a private bus: calls with every kind of value,
//! properties, signals, names and their owners, an exported object, and a
//! file descriptor handed over.

use std::cell::RefCell;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

use nova_sd::poll::{poll, sooner};
use nova_sd::testing::PrivateBus;
use nova_sd::{Bus, Error, Handler, Interface, Message, Value, ERROR_INVALID_ARGS, NAME_QUEUE};

const NAME: &str = "org.nova.Test";
const PATH: &str = "/org/nova/Test";
const IFACE: &str = "org.nova.Test";

extern "C" {
    fn pipe2(fds: *mut i32, flags: i32) -> i32;
    fn fcntl(fd: i32, cmd: i32, ...) -> i32;
}

/// The test object: Echo answers what it is sent, Sender says who called,
/// Pipe hands over the read end of a pipe, Fail fails; Volume is a property
/// that can be set, Name one that cannot.
struct Test {
    volume: u32,
}

impl Handler for Test {
    fn call(&mut self, call: &Message, args: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
        match call.member() {
            Some("Echo") => Ok(args),
            Some("Sender") => Ok(vec![Value::str(call.sender().unwrap_or(""))]),
            Some("Pipe") => {
                let mut fds = [0; 2];
                // SAFETY: a valid array of two.
                assert_eq!(unsafe { pipe2(fds.as_mut_ptr(), 0o2000000) }, 0);
                // SAFETY: both just made, and ours.
                let (read, write) =
                    unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
                drop(write);
                Ok(vec![Value::Fd(Arc::new(read))])
            }
            Some("Fail") => Err(Error::bus("org.nova.Test.Error.Refused", "no")),
            Some("Shout") => {
                call.bus().emit_signal(PATH, IFACE, "Shouted", &args)?;
                Ok(vec![])
            }
            _ => unreachable!(),
        }
    }

    fn get(&mut self, _: &str, property: &str) -> Option<Value> {
        match property {
            "Volume" => Some(Value::Uint32(self.volume)),
            "Name" => Some(Value::str("test")),
            _ => None,
        }
    }

    fn set(&mut self, _: &str, property: &str, value: &Value) -> nova_sd::Result<()> {
        assert_eq!(property, "Volume");
        self.volume = value.as_u64().unwrap() as u32;
        Ok(())
    }
}

/// The test object, served on its own connection and thread until the guard goes.
struct Server {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            t.join().unwrap();
        }
    }
}

fn serve(address: &str) -> Server {
    let stop = Arc::new(AtomicBool::new(false));
    let (ready, started) = mpsc::channel();
    let address = address.to_owned();
    let stopping = stop.clone();
    let thread = thread::spawn(move || {
        let bus = Bus::connect(&address).unwrap();
        let interface = Interface::new(IFACE)
            .method("Echo", "ya{sv}a(us)vdbxht", "ya{sv}a(us)vdbxht")
            .method("Sender", "", "s")
            .method("Pipe", "", "h")
            .method("Fail", "", "")
            .method("Shout", "s", "")
            .signal("Shouted", "s")
            .writable_property("Volume", "u")
            .property("Name", "s");
        let _object = bus
            .export(PATH, vec![interface], Test { volume: 3 })
            .unwrap();
        assert!(bus.request_name(NAME, 0).unwrap());
        ready.send(()).unwrap();
        while !stopping.load(Ordering::Relaxed) {
            let mut fds = [bus.poll_fd()];
            poll(
                &mut fds,
                sooner(bus.timeout(), Some(Duration::from_millis(20))),
            )
            .unwrap();
            bus.dispatch().unwrap();
        }
    });
    started.recv_timeout(Duration::from_secs(5)).unwrap();
    Server {
        stop,
        thread: Some(thread),
    }
}

/// Dispatches <bus> until <done> holds, for five seconds at most.
fn pump(bus: &Bus, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "waited five seconds");
        let mut fds = [bus.poll_fd()];
        poll(&mut fds, Some(Duration::from_millis(20))).unwrap();
        bus.dispatch().unwrap();
    }
}

#[test]
fn a_call_carries_every_kind_of_value_there_and_back() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let _server = serve(&private.address);
    let bus = Bus::connect(&private.address).unwrap();
    let null = std::fs::File::open("/dev/null").unwrap();
    let sent = vec![
        Value::Byte(7),
        Value::options(vec![
            ("Label", Value::str("Backup")),
            ("Ids", Value::strings(&["a", "b"])),
        ]),
        Value::Array(
            "(us)".into(),
            vec![Value::Struct(vec![Value::Uint32(1), Value::str("one")])],
        ),
        Value::variant(Value::path("/org/nova/x")),
        Value::Double(1.5),
        Value::Bool(true),
        Value::Int64(-42),
        Value::Fd(Arc::new(OwnedFd::from(null))),
        Value::Uint64(u64::MAX),
    ];
    let answer = bus.call(NAME, PATH, IFACE, "Echo", &sent).unwrap();
    assert_eq!(answer.len(), sent.len());
    for (i, (a, s)) in answer.iter().zip(&sent).enumerate() {
        if i == 7 {
            // A descriptor comes back as a new one of this process's.
            assert!(matches!(a, Value::Fd(_)));
        } else {
            assert_eq!(a, s, "value {i}");
        }
    }
    assert_eq!(
        answer[1].get("Label").and_then(Value::as_str),
        Some("Backup")
    );
    // An empty array keeps its type.
    let empty = vec![
        Value::Byte(0),
        Value::Dict("s".into(), "v".into(), vec![]),
        Value::Array("(us)".into(), vec![]),
        Value::variant(Value::Bool(false)),
        Value::Double(0.0),
        Value::Bool(false),
        Value::Int64(0),
        Value::Fd(Arc::new(OwnedFd::from(
            std::fs::File::open("/dev/null").unwrap(),
        ))),
        Value::Uint64(0),
    ];
    let answer = bus.call(NAME, PATH, IFACE, "Echo", &empty).unwrap();
    assert_eq!(answer[1], empty[1]);
    assert_eq!(answer[2], empty[2]);
}

#[test]
fn the_object_knows_who_called_and_refuses_what_does_not_fit() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let _server = serve(&private.address);
    let bus = Bus::connect(&private.address).unwrap();
    let me = bus.unique_name().unwrap();
    assert_eq!(
        bus.call(NAME, PATH, IFACE, "Sender", &[]).unwrap(),
        vec![Value::str(me)]
    );
    // Arguments of the wrong type are refused before the handler sees them.
    let wrong = bus
        .call(NAME, PATH, IFACE, "Sender", &[Value::Uint32(1)])
        .unwrap_err();
    assert_eq!(wrong.name(), Some(ERROR_INVALID_ARGS));
    // The handler's own error, by its name.
    let refused = bus.call(NAME, PATH, IFACE, "Fail", &[]).unwrap_err();
    assert_eq!(refused.name(), Some("org.nova.Test.Error.Refused"));
    assert_eq!(refused.to_string(), "no (org.nova.Test.Error.Refused)");
    // What the object does not have, sd-bus refuses.
    let unknown = bus.call(NAME, PATH, IFACE, "Nothing", &[]).unwrap_err();
    assert_eq!(
        unknown.name(),
        Some("org.freedesktop.DBus.Error.UnknownMethod")
    );
    // A call without an interface finds the method by its name.
    assert!(bus.call(NAME, PATH, "", "Sender", &[]).is_ok());
}

#[test]
fn introspection_and_properties_come_from_the_description() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let _server = serve(&private.address);
    let bus = Bus::connect(&private.address).unwrap();
    let xml = bus
        .call(
            NAME,
            PATH,
            "org.freedesktop.DBus.Introspectable",
            "Introspect",
            &[],
        )
        .unwrap();
    let xml = xml[0].as_str().unwrap();
    assert!(
        xml.contains(r#"<method name="Pipe"><arg type="h" direction="out"/></method>"#),
        "{xml}"
    );
    assert!(xml.contains(r#"<signal name="Shouted"><arg type="s"/></signal>"#));
    assert!(xml.contains(r#"<property name="Volume" type="u" access="readwrite"/>"#));

    assert_eq!(
        bus.get_property(NAME, PATH, IFACE, "Volume").unwrap(),
        Value::Uint32(3)
    );
    bus.set_property(NAME, PATH, IFACE, "Volume", Value::Uint32(9))
        .unwrap();
    let all = bus.get_all_properties(NAME, PATH, IFACE).unwrap();
    assert_eq!(all.get("Volume").and_then(Value::as_u64), Some(9));
    assert_eq!(all.get("Name").and_then(Value::as_str), Some("test"));
    let read_only = bus
        .set_property(NAME, PATH, IFACE, "Name", Value::str("x"))
        .unwrap_err();
    assert_eq!(
        read_only.name(),
        Some("org.freedesktop.DBus.Error.PropertyReadOnly")
    );
    let wrong_type = bus
        .set_property(NAME, PATH, IFACE, "Volume", Value::str("x"))
        .unwrap_err();
    assert_eq!(wrong_type.name(), Some(ERROR_INVALID_ARGS));
    let unknown = bus.get_property(NAME, PATH, IFACE, "Nothing").unwrap_err();
    assert_eq!(
        unknown.name(),
        Some("org.freedesktop.DBus.Error.UnknownProperty")
    );
}

#[test]
fn a_signal_reaches_its_match_and_only_while_the_slot_is_kept() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let _server = serve(&private.address);
    let bus = Bus::connect(&private.address).unwrap();
    let heard = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let log = heard.clone();
    let slot = bus
        .match_signal(
            Some(NAME),
            Some(PATH),
            Some(IFACE),
            Some("Shouted"),
            move |m| {
                assert!(m.is_signal(IFACE, "Shouted"));
                log.borrow_mut()
                    .push(m.args().unwrap()[0].as_str().unwrap().to_owned());
            },
        )
        .unwrap();
    bus.call(NAME, PATH, IFACE, "Shout", &[Value::str("it's here")])
        .unwrap();
    pump(&bus, || heard.borrow().len() == 1);
    assert_eq!(heard.borrow()[0], "it's here");
    drop(slot);
    bus.call(NAME, PATH, IFACE, "Shout", &[Value::str("again")])
        .unwrap();
    // A round trip after the signal: had the match still been there, it would have run by now.
    bus.call(NAME, PATH, IFACE, "Sender", &[]).unwrap();
    bus.dispatch().unwrap();
    assert_eq!(heard.borrow().len(), 1);
}

#[test]
fn a_rule_quotes_its_values() {
    assert_eq!(
        nova_sd::rule(&[("type", "signal"), ("arg0", "it's")]),
        r"type='signal',arg0='it'\''s'"
    );
}

#[test]
fn a_name_has_one_owner_and_its_watch_sees_it_go() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let bus = Bus::connect(&private.address).unwrap();
    let owner = Bus::connect(&private.address).unwrap();
    assert!(owner.request_name("org.nova.Owned", 0).unwrap());
    // Asked again by its owner, it is still its.
    assert!(owner.request_name("org.nova.Owned", 0).unwrap());
    let other = Bus::connect(&private.address).unwrap();
    assert_eq!(
        other.request_name("org.nova.Owned", 0).unwrap_err().errno(),
        Some(17)
    );
    // In the queue it waits.
    assert!(!other.request_name("org.nova.Owned", NAME_QUEUE).unwrap());

    let changes = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let log = changes.clone();
    let (_slot, now) = bus
        .watch_name("org.nova.Owned", move |new| {
            log.borrow_mut().push(new.map(str::to_owned))
        })
        .unwrap();
    assert_eq!(now, Some(owner.unique_name().unwrap()));
    let next = other.unique_name().unwrap();
    drop(owner);
    // The owner gone, the one waiting has it.
    pump(&bus, || !changes.borrow().is_empty());
    assert_eq!(changes.borrow()[0], Some(next));
    drop(other);
    pump(&bus, || changes.borrow().len() == 2);
    assert_eq!(changes.borrow()[1], None);
    assert_eq!(bus.name_owner("org.nova.Owned").unwrap(), None);
}

#[test]
fn a_descriptor_handed_over_is_ours_and_closed_on_exec() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let _server = serve(&private.address);
    let bus = Bus::connect(&private.address).unwrap();
    let answer = bus.call(NAME, PATH, IFACE, "Pipe", &[]).unwrap();
    let fd = answer[0].as_fd().unwrap().as_raw_fd();
    // F_GETFD has FD_CLOEXEC.
    // SAFETY: a descriptor the value holds open.
    assert_eq!(unsafe { fcntl(fd, 1) } & 1, 1);
    // Its writer closed, it reads as ended.
    let mut file = std::fs::File::from(answer[0].as_fd().unwrap().try_clone().unwrap());
    let mut text = String::new();
    std::io::Read::read_to_string(&mut file, &mut text).unwrap();
    assert!(text.is_empty());
}

#[test]
fn a_call_with_no_answer_wanted_and_a_bus_that_goes() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let server = serve(&private.address);
    let bus = Bus::connect(&private.address).unwrap();
    bus.call_no_reply(NAME, PATH, IFACE, "Shout", &[Value::str("x")])
        .unwrap();
    bus.flush().unwrap();
    drop(server);
    assert!(bus.is_open());
    drop(private);
    // The daemon gone, the connection says so.
    let deadline = Instant::now() + Duration::from_secs(5);
    let error = loop {
        let mut fds = [bus.poll_fd()];
        poll(&mut fds, Some(Duration::from_millis(50))).unwrap();
        if let Err(e) = bus.dispatch() {
            break e;
        }
        assert!(Instant::now() < deadline);
    };
    assert!(error.is_disconnect(), "{error}");
}

#[test]
fn a_call_answered_later_while_its_caller_goes_on() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    // One connection keeps the calls to Later and answers them when told;
    // the other calls without waiting, and goes on dispatching meanwhile.
    let server = Bus::connect(&private.address).unwrap();
    let kept: Rc<RefCell<Vec<nova_sd::Deferred>>> = Rc::default();
    let keep = kept.clone();
    let _object = server
        .export(
            PATH,
            vec![Interface::new(IFACE).method("Later", "s", "s")],
            move |call: &Message, _: Vec<Value>| -> nova_sd::Result<Vec<Value>> {
                keep.borrow_mut().push(call.defer()?);
                // Not sent: the call is answered through what was kept.
                Ok(vec![Value::str("not this")])
            },
        )
        .unwrap();
    let name = server.unique_name().unwrap();
    let client = Bus::connect(&private.address).unwrap();
    let answers: Rc<RefCell<Vec<nova_sd::Result<Vec<Value>>>>> = Rc::default();
    for word in ["yes", "no"] {
        let got = answers.clone();
        client
            .call_async(
                &name,
                PATH,
                IFACE,
                "Later",
                &[Value::str(word)],
                None,
                move |answer| got.borrow_mut().push(answer),
            )
            .unwrap();
    }
    pump(&client, || {
        server.dispatch().unwrap();
        kept.borrow().len() == 2
    });
    assert!(
        answers.borrow().is_empty(),
        "nothing answered before the reply"
    );
    let mut calls = std::mem::take(&mut *kept.borrow_mut()).into_iter();
    calls
        .next()
        .unwrap()
        .reply(Ok(vec![Value::str("later")]))
        .unwrap();
    calls
        .next()
        .unwrap()
        .reply(Err(Error::bus(
            "org.nova.Test.Error.Refused",
            "turned down",
        )))
        .unwrap();
    server.flush().unwrap();
    pump(&client, || answers.borrow().len() == 2);
    let answers = answers.borrow();
    assert_eq!(answers[0].as_ref().unwrap(), &vec![Value::str("later")]);
    assert_eq!(
        answers[1].as_ref().unwrap_err().name(),
        Some("org.nova.Test.Error.Refused")
    );
}

#[test]
fn a_call_not_waited_for_says_how_it_failed() {
    let Some(private) = PrivateBus::start() else {
        return;
    };
    let bus = Bus::connect(&private.address).unwrap();
    let failed: Rc<RefCell<Option<Error>>> = Rc::default();
    let got = failed.clone();
    bus.call_async(
        "org.nova.Nobody",
        PATH,
        IFACE,
        "Echo",
        &[],
        Some(Duration::from_secs(2)),
        move |answer| *got.borrow_mut() = answer.err(),
    )
    .unwrap();
    pump(&bus, || failed.borrow().is_some());
    assert_eq!(
        failed.borrow().as_ref().and_then(Error::name),
        Some("org.freedesktop.DBus.Error.ServiceUnknown")
    );
}
