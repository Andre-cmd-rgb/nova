// nova-iphone-notifications: the computer takes an iPhone's notifications as
// a watch does, through Apple's Notification Center Service (ANCS), and
// shows them as Nova's own (docs/iphone.md has the why of each choice).
//
// - The iPhone is the one that connects, over Bluetooth Low Energy: the
//   computer advertises, and an iPhone it is bonded with comes back to it by
//   itself. The computer never scans, which is what crashes the Bluetooth of
//   some Intel cards (the AX210's among them). After every loss of the link
//   it advertises fast (20 ms) for half a minute, as Apple's accessory
//   guidelines ask, then slowly (1285 ms, one of the intervals they name);
//   while the iPhone is connected it does not advertise at all.
// - Pairing is a window opened on request (`nova notification iphone pair`,
//   Settings): for three minutes the computer is listed in the iPhone's
//   Settings → Bluetooth, and a notification shows the code to compare. Only
//   then is there a Bluetooth agent, and with no agent BlueZ lets no device
//   pair and turns down an untrusted device's profiles: the iPhone, which is
//   never trusted, cannot make the computer its headset.
// - Shown: each notification added on the iPhone, with its app's name, its
//   title and its message; taken down when the iPhone takes it down; one
//   dismissed here is cleared on the iPhone too, one that ran out stays
//   there. Not shown: those already there at a connection, calls, and the
//   ones the iPhone delivers quietly, which go to the history alone.
//
// Its state for Settings and `nova notification iphone` is written to
// $XDG_RUNTIME_DIR/nova/iphone-notifications.json at each change. It owns
// org.nova.iPhoneNotifications on the session bus, where Pair opens the
// pairing window and Answer is the pairing notification's buttons.
//
// The service itself (service.rs) speaks no D-Bus; this is the glue that
// hands it the buses' messages, makes its calls, and runs its timers. Every
// call is made without waiting for its answer: BlueZ calls back into the
// caller before it answers some (RegisterAdvertisement reads the
// advertisement, StartNotify on an iPhone not paired asks the agent).
//
// NOVA_IPHONE_BUS=session puts BlueZ and logind on the session bus too, for
// the tests' fake BlueZ; the NOVA_IPHONE_*_SECONDS variables shorten waits.

mod ancs;
mod service;
mod value;

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Instant;

use nova_sd::poll::{poll, sooner, PollFd, POLLIN};
use nova_sd::{Bus, Deferred, Error, Interface, Message, Slot};

use service::{
    log, Bus as Which, Reply, Service, Tunables, ADVERTISEMENT, ADVERTISEMENT_PATH, AGENT,
    AGENT_PATH, BLUEZ, NAME, NAME_PATH, NOTIFICATIONS, OBJECT_MANAGER,
};
use value::{map_of, strings_of, BusError, Value};

/// The exit status when another program owns NAME, which the unit does not
/// restart (RestartPreventExitStatus): starting again would not change that.
const NAME_TAKEN: i32 = 3;
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
const LOGIN: &str = "org.freedesktop.login1";

struct Glue {
    service: Service,
    system: Bus,
    session: Bus,
    /// The pairing agent's calls answered later, by the service's number.
    deferred: HashMap<u64, Deferred>,
    calls: u64,
}

type Shared = Rc<RefCell<Glue>>;

/// Makes the calls the service asked for and sends the answers it gave,
/// until it asks nothing more.
fn flush(shared: &Shared) {
    loop {
        let (calls, answers, deferred) = {
            let mut glue = shared.borrow_mut();
            let calls = std::mem::take(&mut glue.service.core.out);
            let answers = std::mem::take(&mut glue.service.core.answers);
            let deferred: Vec<_> = answers
                .into_iter()
                .filter_map(|(id, error)| glue.deferred.remove(&id).map(|d| (d, error)))
                .collect();
            (calls, deferred.len(), deferred)
        };
        if calls.is_empty() && answers == 0 {
            return;
        }
        for (call, error) in deferred {
            let answer = match error {
                None => Ok(vec![]),
                Some(error) => Err(Error::bus(&error.name, error.message)),
            };
            if let Err(error) = call.reply(answer) {
                log(&format!("could not answer BlueZ: {error}"));
            }
        }
        for call in calls {
            let bus = {
                let glue = shared.borrow();
                match call.bus {
                    Which::System => glue.system.clone(),
                    Which::Session => glue.session.clone(),
                }
            };
            let then = call.then.clone();
            let back = shared.clone();
            let sent = bus.call_async(
                call.destination,
                &call.path,
                call.interface,
                call.method,
                &call.args,
                Some(call.timeout),
                move |result: nova_sd::Result<Vec<Value>>| {
                    back.borrow_mut()
                        .service
                        .reply(then, result.map_err(BusError::from));
                    flush(&back);
                },
            );
            if let Err(error) = sent {
                shared
                    .borrow_mut()
                    .service
                    .reply(call.then, Err(BusError::from(error)));
            }
        }
    }
}

/// Runs <step> on the service, then makes what it asked for.
fn with(shared: &Shared, step: impl FnOnce(&mut Service)) {
    step(&mut shared.borrow_mut().service);
    flush(shared);
}

fn interfaces_of(
    value: Option<&Value>,
) -> Vec<(String, std::collections::BTreeMap<String, Value>)> {
    value
        .and_then(Value::as_dict)
        .unwrap_or_default()
        .iter()
        .filter_map(|(name, properties)| Some((name.as_str()?.to_string(), map_of(properties))))
        .collect()
}

/// The signals the service follows, for as long as the slots are kept.
fn follow(shared: &Shared) -> nova_sd::Result<Vec<Slot>> {
    let (system, session) = {
        let glue = shared.borrow();
        (glue.system.clone(), glue.session.clone())
    };
    let mut slots = Vec::new();
    let s = shared.clone();
    slots.push(system.match_signal(
        Some(BLUEZ),
        None,
        Some(OBJECT_MANAGER),
        Some("InterfacesAdded"),
        move |message: &Message| {
            let Ok(args) = message.args() else { return };
            let Some(path) = args.first().and_then(Value::as_str) else {
                return;
            };
            let interfaces = interfaces_of(args.get(1));
            with(&s, |service| service.interfaces_added(path, &interfaces));
        },
    )?);
    let s = shared.clone();
    slots.push(system.match_signal(
        Some(BLUEZ),
        None,
        Some(OBJECT_MANAGER),
        Some("InterfacesRemoved"),
        move |message: &Message| {
            let Ok(args) = message.args() else { return };
            let Some(path) = args.first().and_then(Value::as_str) else {
                return;
            };
            let interfaces = args.get(1).map(strings_of).unwrap_or_default();
            with(&s, |service| service.interfaces_removed(path, &interfaces));
        },
    )?);
    let s = shared.clone();
    slots.push(system.match_signal(
        Some(BLUEZ),
        None,
        Some(PROPERTIES),
        Some("PropertiesChanged"),
        move |message: &Message| {
            let (Some(path), Ok(args)) = (message.path(), message.args()) else {
                return;
            };
            let interface = args.first().and_then(Value::as_str).unwrap_or("");
            let changed = args.get(1).map(map_of).unwrap_or_default();
            let invalidated = args.get(2).map(strings_of).unwrap_or_default();
            with(&s, |service| {
                service.properties_changed(path, interface, &changed, &invalidated)
            });
        },
    )?);
    let s = shared.clone();
    slots.push(system.match_signal(
        Some(LOGIN),
        None,
        Some("org.freedesktop.login1.Manager"),
        Some("PrepareForSleep"),
        move |message: &Message| {
            let start = message
                .args()
                .ok()
                .and_then(|a| a.first().and_then(Value::as_bool))
                .unwrap_or(false);
            with(&s, |service| service.sleeping(start));
        },
    )?);
    let s = shared.clone();
    slots.push(session.match_signal(
        Some(NOTIFICATIONS),
        None,
        Some(NOTIFICATIONS),
        Some("NotificationClosed"),
        move |message: &Message| {
            let Ok(args) = message.args() else { return };
            let number = |at: usize| args.get(at).and_then(Value::as_u64).unwrap_or(0) as u32;
            let (note, reason) = (number(0), number(1));
            with(&s, |service| service.notification_closed(note, reason));
        },
    )?);
    let s = shared.clone();
    let (slot, bluez) = system.watch_name(BLUEZ, move |owner: Option<&str>| {
        let owner = owner.unwrap_or("").to_string();
        with(&s, |service| service.bluez_owner(&owner));
    })?;
    slots.push(slot);
    let s = shared.clone();
    let (slot, _) = session.watch_name(NOTIFICATIONS, move |_: Option<&str>| {
        with(&s, |service| service.notifications_owner());
    })?;
    slots.push(slot);
    // Who has the names as the watches begin, as a change would say.
    with(shared, |service| {
        service.notifications_owner();
        service.bluez_owner(bluez.as_deref().unwrap_or(""));
    });
    Ok(slots)
}

/// The advertisement BlueZ reads, the pairing agent BlueZ asks, and the
/// service's own object for `nova notification iphone`.
fn objects(shared: &Shared) -> nova_sd::Result<Vec<Slot>> {
    let (system, session) = {
        let glue = shared.borrow();
        (glue.system.clone(), glue.session.clone())
    };
    let mut slots = Vec::new();

    struct Advertisement(Shared);
    impl nova_sd::Handler for Advertisement {
        fn call(&mut self, call: &Message, _: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
            let sender = call.sender().unwrap_or("").to_string();
            with(&self.0, |service| service.advertisement_released(&sender));
            Ok(vec![])
        }

        fn get(&mut self, interface: &str, property: &str) -> Option<Value> {
            let glue = self.0.borrow();
            let properties = glue.service.advertisement(interface).ok()?;
            properties
                .into_iter()
                .find(|(name, _)| *name == property)
                .map(|(_, value)| value)
        }
    }
    slots.push(system.export(
        ADVERTISEMENT_PATH,
        vec![Interface::new(ADVERTISEMENT)
            .method("Release", "", "")
            .property("Type", "s")
            .property("SolicitUUIDs", "as")
            .property("Discoverable", "b")
            .property("MinInterval", "u")
            .property("MaxInterval", "u")
            .property("LocalName", "s")],
        Advertisement(shared.clone()),
    )?);

    let s = shared.clone();
    slots.push(system.export(
        AGENT_PATH,
        vec![Interface::new(AGENT)
            .method("Release", "", "")
            .method("RequestPinCode", "o", "s")
            .method("DisplayPinCode", "os", "")
            .method("RequestPasskey", "o", "u")
            .method("DisplayPasskey", "ouq", "")
            .method("RequestConfirmation", "ou", "")
            .method("RequestAuthorization", "o", "")
            .method("AuthorizeService", "os", "")
            .method("Cancel", "", "")],
        move |call: &Message, args: Vec<Value>| -> nova_sd::Result<Vec<Value>> {
            let sender = call.sender().unwrap_or("").to_string();
            let method = call.member().unwrap_or("").to_string();
            let (reply, id) = {
                let mut glue = s.borrow_mut();
                glue.calls += 1;
                let id = glue.calls;
                (glue.service.agent(&sender, &method, &args, id), id)
            };
            let answer = match reply {
                Reply::Empty => Ok(vec![]),
                Reply::Error(error) => Err(Error::bus(&error.name, error.message)),
                Reply::Later => {
                    let deferred = call.defer()?;
                    s.borrow_mut().deferred.insert(id, deferred);
                    Ok(vec![])
                }
            };
            flush(&s);
            answer
        },
    )?);

    let s = shared.clone();
    slots.push(session.export(
        NAME_PATH,
        vec![Interface::new(NAME)
            .method("Pair", "b", "b")
            .method("Answer", "b", "")],
        move |call: &Message, args: Vec<Value>| -> nova_sd::Result<Vec<Value>> {
            let yes = args.first().and_then(Value::as_bool).unwrap_or(false);
            let mut answer = vec![];
            match call.member() {
                // Opens the pairing window; with true, only when no iPhone
                // is paired already (switching it on). Whether it opened.
                Some("Pair") => with(&s, |service| {
                    answer = vec![Value::Bool(service.open_pairing(yes))]
                }),
                Some("Answer") => with(&s, |service| service.answer(yes)),
                _ => {}
            }
            Ok(answer)
        },
    )?);
    Ok(slots)
}

// SIGINT and SIGTERM, as a descriptor the main loop polls: held back from
// the process and read from the descriptor instead, so that one that comes
// just before it sleeps still wakes it.
extern "C" {
    fn sigemptyset(set: *mut SigSet) -> i32;
    fn sigaddset(set: *mut SigSet, signal: i32) -> i32;
    fn sigprocmask(how: i32, set: *const SigSet, old: *mut SigSet) -> i32;
    fn signalfd(fd: i32, set: *const SigSet, flags: i32) -> i32;
}
/// glibc's sigset_t: 1024 bits.
#[repr(C)]
struct SigSet([u64; 16]);
const SIG_BLOCK: i32 = 0;
const SFD_CLOEXEC: i32 = 0o2000000;
const SFD_NONBLOCK: i32 = 0o4000;

fn signal_fd() -> i32 {
    let mut set = SigSet([0; 16]);
    // SAFETY: a sigset_t of glibc's size, filled in and handed over by pointer.
    unsafe {
        sigemptyset(&mut set);
        sigaddset(&mut set, 2);
        sigaddset(&mut set, 15);
        sigprocmask(SIG_BLOCK, &set, std::ptr::null_mut());
        signalfd(-1, &set, SFD_CLOEXEC | SFD_NONBLOCK)
    }
}

fn run() -> Result<i32, Error> {
    let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR").filter(|r| !r.is_empty()) else {
        log("XDG_RUNTIME_DIR is not set");
        return Ok(1);
    };
    let runtime = PathBuf::from(runtime);
    let folder = runtime.join("nova");
    if std::fs::create_dir_all(&folder).is_ok() {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o700));
    }
    let session = Bus::user()?;
    match session.request_name(NAME, 0) {
        Ok(true) => {}
        Ok(false) | Err(Error::Os { errno: 17, .. }) => {
            log(&format!("{NAME} is another program's already"));
            return Ok(NAME_TAKEN);
        }
        Err(error) => return Err(error),
    }
    // What a run before left, if it ended without a word (a crash, a kill):
    // its state is not this one's.
    let _ = std::fs::remove_file(folder.join("iphone-notifications.json"));
    let system = if std::env::var("NOVA_IPHONE_BUS").as_deref() == Ok("session") {
        session.clone()
    } else {
        Bus::system()?
    };
    let conf = std::env::var_os("NOVA_BLUETOOTH_CONF")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/etc/bluetooth/main.conf".into());
    let shared: Shared = Rc::new(RefCell::new(Glue {
        service: Service::new(&runtime, &conf, Tunables::from_env()),
        system: system.clone(),
        session: session.clone(),
        deferred: HashMap::new(),
        calls: 0,
    }));
    let _objects = objects(&shared)?;
    let _signals = follow(&shared)?;
    let stop = signal_fd();
    log("started");
    let same = std::env::var("NOVA_IPHONE_BUS").as_deref() == Ok("session");
    loop {
        session.dispatch()?;
        if !same {
            system.dispatch()?;
        }
        shared.borrow_mut().service.run_timers();
        flush(&shared);
        let mut fds = vec![PollFd::new(stop, POLLIN), session.poll_fd()];
        if !same {
            fds.push(system.poll_fd());
        }
        let due = shared
            .borrow()
            .service
            .core
            .timers
            .next_due()
            .map(|at| at.saturating_duration_since(Instant::now()));
        let mut wait = sooner(session.timeout(), due);
        if !same {
            wait = sooner(wait, system.timeout());
        }
        let _ = poll(&mut fds, wait);
        if fds[0].ready() {
            break;
        }
    }
    // BlueZ drops what a program registered once it leaves the bus, so this
    // is only to be tidy: the question withdrawn, the state gone.
    let calls = shared.borrow_mut().service.stop();
    flush(&shared);
    for call in calls {
        let bus = if call.bus == Which::System {
            &system
        } else {
            &session
        };
        let _ = bus.call_timeout(
            call.destination,
            &call.path,
            call.interface,
            call.method,
            &call.args,
            Some(call.timeout),
        );
    }
    let _ = session.flush();
    let _ = system.flush();
    Ok(0)
}

fn main() {
    let status = match run() {
        Ok(status) => status,
        Err(error) => {
            log(&error.to_string());
            1
        }
    };
    std::process::exit(status);
}
