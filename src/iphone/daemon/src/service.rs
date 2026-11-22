//! The service: BlueZ's objects as it last said they were, the iPhones
//! among them, the advertisement, the pairing window and its agent, and what
//! Settings reads. It speaks no D-Bus itself: what it asks of the buses goes
//! into `out` (calls) and `answers` (replies to a pairing question that
//! waited), and the bus glue hands it back each reply, signal and method
//! call, so that every step here can be followed in a test without a bus.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::ancs::{self, Answer, Event, Found};
use crate::value::{bytes, json_string, map_of, strings_of, truthy, BusError, Value};

// ------------------------------------------------------------- tunables

/// One of the waits, in seconds, which NOVA_IPHONE_<NAME>_SECONDS shortens for
/// the tests.
pub fn seconds(name: &str, default: f64) -> f64 {
    std::env::var(format!("NOVA_IPHONE_{name}_SECONDS"))
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .unwrap_or(default)
}

/// How the computer advertises. Apple's accessory guidelines: 20 ms for the
/// first 30 s, then a longer interval from their list; 1285 ms is the
/// longest, and a whole number of milliseconds, which is what BlueZ takes.
/// The pairing window advertises as the kernel does for a discoverable
/// controller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Pairing,
    Fast,
    Slow,
}

impl Mode {
    fn intervals(self) -> (u32, u32) {
        match self {
            Mode::Pairing => (100, 150),
            Mode::Fast => (20, 30),
            Mode::Slow => (1285, 1285),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Mode::Pairing => "pairing",
            Mode::Fast => "fast",
            Mode::Slow => "slow",
        }
    }
}

pub struct Tunables {
    pub fast: f64,
    pub pair: f64,
    /// How long an answer on the Data Source may take.
    pub reply: f64,
    /// A connection back within this long counts as a blip (a reset of the
    /// card, a sleep of a minute): notifications that came meanwhile are
    /// shown, a few.
    pub missed: f64,
}

impl Tunables {
    pub fn from_env() -> Tunables {
        Tunables {
            fast: seconds("FAST", 30.0),
            pair: seconds("PAIR", 180.0),
            reply: seconds("REPLY", 5.0),
            missed: seconds("MISSED", 300.0),
        }
    }
}

const MISSED_MOST: u32 = 5;
/// Those it had then and not before the drop whose dates are looked at.
const MISSED_ASKED_MOST: u32 = 20;
pub const CALL_TIMEOUT: f64 = 10.0;
// A flood of events (an iPhone gone wrong, or anything else on the link) is
// not followed past these: the notifications waiting to be asked about and
// shown, the commands waiting, and the notifications the iPhone is known to
// have (it may well have hundreds; this many integers are nothing).
const PENDING_MOST: usize = 50;
const QUEUE_MOST: usize = 2 * PENDING_MOST;
const KNOWN_MOST: usize = 1000;
/// The shell's notifications remembered, to tell the iPhone of a dismissal.
const NOTES_MOST: usize = 500;

pub const BLUEZ: &str = "org.bluez";
pub const ADAPTER: &str = "org.bluez.Adapter1";
pub const DEVICE: &str = "org.bluez.Device1";
pub const LE_BEARER: &str = "org.bluez.Bearer.LE1";
pub const GATT_SERVICE: &str = "org.bluez.GattService1";
pub const GATT_CHARACTERISTIC: &str = "org.bluez.GattCharacteristic1";
pub const ADVERTISING_MANAGER: &str = "org.bluez.LEAdvertisingManager1";
pub const ADVERTISEMENT: &str = "org.bluez.LEAdvertisement1";
pub const AGENT_MANAGER: &str = "org.bluez.AgentManager1";
pub const AGENT: &str = "org.bluez.Agent1";
pub const OBJECT_MANAGER: &str = "org.freedesktop.DBus.ObjectManager";
pub const NOTIFICATIONS: &str = "org.freedesktop.Notifications";
pub const NOTIFICATIONS_PATH: &str = "/org/freedesktop/Notifications";
pub const NAME: &str = "org.nova.iPhoneNotifications";
pub const NAME_PATH: &str = "/org/nova/iPhoneNotifications";
pub const ADVERTISEMENT_PATH: &str = "/org/nova/iphone/advertisement0";
pub const AGENT_PATH: &str = "/org/nova/iphone/agent";
pub const REJECTED: &str = "org.bluez.Error.Rejected";

// NotificationClosed's reasons
const DISMISSED: u32 = 2;

pub fn log(message: &str) {
    eprintln!("nova-iphone-notifications: {message}");
}

#[repr(C)]
struct Timespec {
    sec: i64,
    nsec: i64,
}
extern "C" {
    fn clock_gettime(clock: i32, time: *mut Timespec) -> i32;
}
const CLOCK_MONOTONIC: i32 = 1;
const CLOCK_BOOTTIME: i32 = 7;

fn clock(id: i32) -> f64 {
    let mut time = Timespec { sec: 0, nsec: 0 };
    // SAFETY: a timespec as the C library lays it out on this target; std
    // has no CLOCK_BOOTTIME.
    unsafe { clock_gettime(id, &mut time) };
    time.sec as f64 + time.nsec as f64 / 1e9
}

/// A clock that counts through sleep, unlike the timers'.
pub fn now_boot() -> f64 {
    clock(CLOCK_BOOTTIME)
}

fn monotonic() -> f64 {
    clock(CLOCK_MONOTONIC)
}

fn wall() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Whether BlueZ runs Bluetooth LE: ControllerMode in main.conf's [General]
/// is not bredr (Settings → Bluetooth → Bluetooth Low Energy).
pub fn le_enabled(path: &Path) -> bool {
    let Ok(raw) = std::fs::read(path) else {
        return true;
    };
    let conf = String::from_utf8_lossy(&raw);
    let mut mode = "dual".to_string();
    let mut general = false;
    for line in conf.lines() {
        let stripped = line.trim();
        if stripped.starts_with('[') {
            general = stripped == "[General]";
        } else if general && !stripped.starts_with('#') {
            if let Some((key, value)) = stripped.split_once('=') {
                if key.trim() == "ControllerMode" {
                    mode = value.split('#').next().unwrap_or("").trim().to_string();
                }
            }
        }
    }
    mode != "bredr"
}

// ------------------------------------------------------------- the effects

/// Which bus a call goes on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bus {
    System,
    Session,
}

/// What a reply is for, handed back with it.
#[derive(Debug, Clone, PartialEq)]
pub enum Then {
    Nothing,
    Managed {
        generation: u64,
    },
    Subscribed {
        phone: u64,
        number: u64,
        role: Role,
        path: String,
    },
    Written {
        phone: u64,
        serial: u64,
    },
    Shown {
        phone: u64,
        number: u64,
        uid: u32,
        replaces: u32,
        flags: u8,
    },
    Asked {
        question: u64,
        /// The name of the file of commands written for its buttons, which
        /// goes again if the notification is not shown.
        commands: Option<String>,
    },
    Unregistered {
        generation: u64,
    },
    Registered {
        generation: u64,
        mode: Mode,
    },
    AgentGone {
        generation: u64,
    },
    AgentRegistered {
        generation: u64,
    },
    AgentDefault {
        generation: u64,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Call {
    pub bus: Bus,
    pub destination: &'static str,
    pub path: String,
    pub interface: &'static str,
    pub method: &'static str,
    pub args: Vec<Value>,
    pub timeout: Duration,
    pub then: Then,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Timer {
    Retry { phone: u64 },
    Reply { phone: u64 },
    Fast,
    PairingOver,
    PairingDone,
    Unblock,
    Grace { question: u64 },
}

/// The timers waiting, each by its number.
#[derive(Default)]
pub struct Timers {
    next: u64,
    waiting: BTreeMap<u64, (Instant, Timer)>,
}

impl Timers {
    fn add(&mut self, seconds: f64, timer: Timer) -> u64 {
        self.next += 1;
        let at = Instant::now() + Duration::from_secs_f64(seconds.max(0.0));
        self.waiting.insert(self.next, (at, timer));
        self.next
    }

    fn remove(&mut self, id: Option<u64>) {
        if let Some(id) = id {
            self.waiting.remove(&id);
        }
    }

    /// When the next one is due.
    pub fn next_due(&self) -> Option<Instant> {
        self.waiting.values().map(|(at, _)| *at).min()
    }

    /// The one due first, if it is due, taken out.
    fn take_due(&mut self, now: Instant) -> Option<(u64, Timer)> {
        let (&id, &(at, timer)) = self
            .waiting
            .iter()
            .min_by_key(|(id, (at, _))| (*at, **id))?;
        if at > now {
            return None;
        }
        self.waiting.remove(&id);
        Some((id, timer))
    }
}

// ------------------------------------------------------------- BlueZ's objects

type Properties = BTreeMap<String, Value>;

/// BlueZ's objects as it last said they were: path → interface → properties.
#[derive(Default)]
pub struct Objects {
    pub tree: BTreeMap<String, BTreeMap<String, Properties>>,
}

impl Objects {
    /// From GetManagedObjects' a{oa{sa{sv}}}.
    fn load(&mut self, managed: &Value) {
        self.tree.clear();
        if let Value::Dict(_, _, objects) = managed.unvariant() {
            for (path, interfaces) in objects {
                let Some(path) = path.as_str() else { continue };
                let entry = self.tree.entry(path.to_string()).or_default();
                if let Value::Dict(_, _, interfaces) = interfaces.unvariant() {
                    for (interface, properties) in interfaces {
                        if let Some(interface) = interface.as_str() {
                            entry.insert(interface.to_string(), map_of(properties));
                        }
                    }
                }
            }
        }
    }

    fn added(&mut self, path: &str, interfaces: &[(String, Properties)]) {
        let entry = self.tree.entry(path.to_string()).or_default();
        for (interface, properties) in interfaces {
            entry.insert(interface.clone(), properties.clone());
        }
    }

    fn removed(&mut self, path: &str, interfaces: &[String]) {
        if let Some(entry) = self.tree.get_mut(path) {
            for interface in interfaces {
                entry.remove(interface);
            }
            if entry.is_empty() {
                self.tree.remove(path);
            }
        }
    }

    fn changed(
        &mut self,
        path: &str,
        interface: &str,
        changed: &Properties,
        invalidated: &[String],
    ) -> bool {
        let Some(properties) = self.tree.get_mut(path).and_then(|e| e.get_mut(interface)) else {
            return false;
        };
        for (name, value) in changed {
            properties.insert(name.clone(), value.clone());
        }
        for name in invalidated {
            properties.remove(name);
        }
        true
    }

    pub fn get(&self, path: &str, interface: &str, name: &str) -> Option<&Value> {
        self.tree.get(path)?.get(interface)?.get(name)
    }

    fn truthy(&self, path: &str, interface: &str, name: &str) -> bool {
        self.get(path, interface, name).is_some_and(truthy)
    }

    fn string(&self, path: &str, interface: &str, name: &str) -> String {
        self.get(path, interface, name)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    }

    fn having(&self, interface: &str) -> Vec<String> {
        self.tree
            .iter()
            .filter(|(_, entry)| entry.contains_key(interface))
            .map(|(path, _)| path.clone())
            .collect()
    }
}

// ------------------------------------------------------------- an iPhone

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Role {
    NotificationSource,
    ControlPoint,
    DataSource,
}

impl Role {
    fn name(self) -> &'static str {
        match self {
            Role::NotificationSource => "ns",
            Role::ControlPoint => "cp",
            Role::DataSource => "ds",
        }
    }
}

/// A command for the Control Point, waiting its turn.
#[derive(Debug, Clone, PartialEq)]
enum Job {
    Note(u32),
    App(Vec<u8>),
    Clear(u32),
}

/// The command the iPhone was asked and has not answered yet.
struct Current {
    serial: u64,
    job: Job,
    answer: Option<Answer>,
    timer: Option<u64>,
}

/// What is known of a notification to show.
#[derive(Default)]
struct Pending {
    flags: u8,
    category: u8,
    replace: bool,
    missed: bool,
    app: Vec<u8>,
    title: String,
    subtitle: String,
    message: String,
}

/// The uids the iPhone has, oldest first: a set in the order they came.
#[derive(Default)]
struct Known {
    next: u64,
    order: BTreeMap<u64, u32>,
    at: HashMap<u32, u64>,
}

impl Known {
    fn insert(&mut self, uid: u32) {
        if self.at.contains_key(&uid) {
            return;
        }
        self.next += 1;
        self.order.insert(self.next, uid);
        self.at.insert(uid, self.next);
    }

    fn remove(&mut self, uid: u32) {
        if let Some(at) = self.at.remove(&uid) {
            self.order.remove(&at);
        }
    }

    fn drop_oldest(&mut self) {
        if let Some((_, uid)) = self.order.pop_first() {
            self.at.remove(&uid);
        }
    }

    fn contains(&self, uid: u32) -> bool {
        self.at.contains_key(&uid)
    }

    fn len(&self) -> usize {
        self.at.len()
    }

    fn clear(&mut self) {
        self.order.clear();
        self.at.clear();
    }

    fn set(&self) -> HashSet<u32> {
        self.at.keys().copied().collect()
    }
}

/// One iPhone (a BlueZ device with ANCS): its link, its subscriptions, the
/// commands it is asked one at a time, and the notifications shown.
pub struct Phone {
    id: u64,
    pub path: String,
    characteristics: BTreeMap<Role, String>,
    pub connected: bool,
    queue: VecDeque<Job>,
    current: Option<Current>,
    serial: u64,
    pending: HashMap<u32, Pending>,
    /// uid → (the shell's notification, the event's flags)
    shown: HashMap<u32, (u32, u8)>,
    known: Known,
    flooded: bool,
    before: Option<HashSet<u32>>,
    dropped_at: f64,
    dropped_wall: f64,
    missed_left: u32,
    missed_asked: u32,
    /// app identifier → its name
    apps: HashMap<Vec<u8>, String>,
    /// app identifier → the uids waiting for its name
    waiting: HashMap<Vec<u8>, Vec<u32>>,
    subscribing: bool,
    /// The characteristics subscribed to on this link.
    asked: HashSet<String>,
    /// Counts the links, so that an answer from an old one is told apart.
    link_number: u64,
    /// Its pairing failed on this link.
    turned_down: bool,
    refused: bool,
    retry: Option<u64>,
    tries: u32,
}

/// The parameters of a link, as the iPhone chose them.
#[derive(Debug, Clone, PartialEq)]
pub struct Link {
    interval: f64,
    latency: Option<i64>,
    timeout: Option<i64>,
}

impl Phone {
    fn new(id: u64, path: &str) -> Phone {
        Phone {
            id,
            path: path.to_string(),
            characteristics: BTreeMap::new(),
            connected: false,
            queue: VecDeque::new(),
            current: None,
            serial: 0,
            pending: HashMap::new(),
            shown: HashMap::new(),
            known: Known::default(),
            flooded: false,
            before: None,
            dropped_at: 0.0,
            dropped_wall: 0.0,
            missed_left: MISSED_MOST,
            missed_asked: 0,
            apps: HashMap::new(),
            waiting: HashMap::new(),
            subscribing: false,
            asked: HashSet::new(),
            link_number: 0,
            turned_down: false,
            refused: false,
            retry: None,
            tries: 0,
        }
    }

    // -- what BlueZ says

    fn bonded(&self, core: &Core) -> bool {
        core.objects.truthy(&self.path, DEVICE, "Bonded")
            || core.objects.truthy(&self.path, DEVICE, "Paired")
    }

    fn name(&self, core: &Core) -> String {
        // The iPhone's own name: what it sends is shown as plain text.
        let mut raw = core.objects.string(&self.path, DEVICE, "Alias");
        if raw.is_empty() {
            raw = core.objects.string(&self.path, DEVICE, "Name");
        }
        let name = ancs::name_text(raw.as_bytes());
        if name.is_empty() {
            "iPhone".into()
        } else {
            name
        }
    }

    fn le_connected(&self, core: &Core) -> bool {
        // The LE link itself: a dual-mode iPhone may be connected over
        // classic Bluetooth alone, which is no use here.
        let le = core
            .objects
            .tree
            .get(&self.path)
            .is_some_and(|e| e.contains_key(LE_BEARER));
        if le {
            core.objects.truthy(&self.path, LE_BEARER, "Connected")
        } else {
            core.objects.truthy(&self.path, DEVICE, "Connected")
        }
    }

    fn notifying(&self, core: &Core, role: Role) -> bool {
        self.characteristics
            .get(&role)
            .is_some_and(|path| core.objects.truthy(path, GATT_CHARACTERISTIC, "Notifying"))
    }

    fn ready(&self, core: &Core) -> bool {
        self.connected
            && self.notifying(core, Role::DataSource)
            && self.notifying(core, Role::NotificationSource)
    }

    fn link(&self, core: &Core) -> Option<Link> {
        if !self.connected {
            return None;
        }
        let interval = core.objects.get(&self.path, LE_BEARER, "Interval")?;
        Some(Link {
            interval: interval.as_i64().unwrap_or(0) as f64 / 1000.0,
            latency: core
                .objects
                .get(&self.path, LE_BEARER, "Latency")
                .and_then(Value::as_i64),
            timeout: core
                .objects
                .get(&self.path, LE_BEARER, "SupervisionTimeout")
                .and_then(Value::as_i64),
        })
    }

    fn state(&self, core: &Core) -> &'static str {
        if !self.connected {
            "waiting"
        } else if self.ready(core) {
            "connected"
        } else if self.refused {
            "not-shared"
        } else {
            "connecting"
        }
    }

    /// Brought in line with BlueZ's objects, after any change.
    fn refresh(&mut self, core: &mut Core) {
        let mut found = BTreeMap::new();
        let prefix = format!("{}/", self.path);
        for (path, entry) in &core.objects.tree {
            if !path.starts_with(&prefix) {
                continue;
            }
            let uuid = entry
                .get(GATT_CHARACTERISTIC)
                .and_then(|p| p.get("UUID"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_lowercase();
            let role = match uuid.as_str() {
                ancs::NOTIFICATION_SOURCE => Role::NotificationSource,
                ancs::CONTROL_POINT => Role::ControlPoint,
                ancs::DATA_SOURCE => Role::DataSource,
                _ => continue,
            };
            found.insert(role, path.clone());
        }
        self.characteristics = found;
        let connected = self.le_connected(core);
        if connected && !self.connected {
            self.connected = true;
            self.connect(core);
        } else if !connected && self.connected {
            self.connected = false;
            self.disconnect(core);
        }
        if self.connected && self.characteristics.len() == 3 && !self.ready(core) {
            self.subscribe(core);
        }
        self.pump(core);
    }

    fn connect(&mut self, core: &mut Core) {
        let name = self.name(core);
        match self.link(core) {
            Some(link) => log(&format!(
                "{name} connected: interval {} ms, latency {}, supervision timeout {} ms",
                link.interval,
                link.latency.map_or("None".into(), |v| v.to_string()),
                link.timeout.map_or("None".into(), |v| v.to_string()),
            )),
            None => log(&format!("{name} connected")),
        }
        self.missed_left = MISSED_MOST;
        self.missed_asked = 0;
        self.refused = false;
        self.tries = 0;
        self.asked.clear();
        self.link_number += 1;
        self.turned_down = false;
        self.flooded = false;
        // Ids under which the shell showed notifications before: the iPhone
        // may number them anew, so a dismissal now clears nothing there.
        self.forget_shown(core);
    }

    fn forget_shown(&mut self, core: &mut Core) {
        self.shown.clear();
        core.forget_notes(&self.path);
    }

    fn disconnect(&mut self, core: &mut Core) {
        log(&format!("{} went away", self.name(core)));
        self.before = Some(self.known.set());
        self.dropped_at = now_boot();
        self.dropped_wall = wall();
        self.known.clear();
        self.queue.clear();
        self.pending.clear();
        self.waiting.clear();
        self.give_up_current(core);
        self.subscribing = false;
        // What the link before had in flight is answered for no link now.
        self.link_number += 1;
        core.timers.remove(self.retry.take());
        core.schedule_fast();
    }

    /// Its device is no more (forgotten, or BlueZ ended).
    fn gone(&mut self, core: &mut Core) {
        self.connected = false;
        self.link_number += 1;
        self.queue.clear();
        self.pending.clear();
        self.waiting.clear();
        self.give_up_current(core);
        self.forget_shown(core);
        core.timers.remove(self.retry.take());
    }

    // -- subscribing

    /// The Data Source first, then the Notification Source: the iPhone lists
    /// what it has the moment the second is subscribed, and an answer needs
    /// the first. Not for an iPhone that is not paired, outside the pairing
    /// window: subscribing is what makes it ask to pair.
    fn subscribe(&mut self, core: &mut Core) {
        if self.subscribing || self.retry.is_some() || self.characteristics.len() < 3 {
            return;
        }
        if !self.bonded(core) && (self.turned_down || !core.pairing_open()) {
            return;
        }
        let Some(role) = [Role::DataSource, Role::NotificationSource]
            .into_iter()
            .find(|r| !self.asked.contains(&self.characteristics[r]))
        else {
            return;
        };
        self.subscribing = true;
        let path = self.characteristics[&role].clone();
        core.call_bluez(
            &path,
            GATT_CHARACTERISTIC,
            "StartNotify",
            vec![],
            40.0,
            Then::Subscribed {
                phone: self.id,
                number: self.link_number,
                role,
                path: path.clone(),
            },
        );
    }

    /// The answer to a StartNotify; whether the service is to look again.
    fn subscribed(
        &mut self,
        core: &mut Core,
        number: u64,
        role: Role,
        path: String,
        error: Option<BusError>,
    ) -> bool {
        if number != self.link_number {
            return false;
        }
        self.subscribing = false;
        if !self.connected {
            return false;
        }
        // BlueZ keeps a subscription across reconnections, and answers
        // InProgress while it is putting it back.
        if let Some(error) = error.filter(|e| !e.name.ends_with(".InProgress")) {
            let why = format!("{}: {}", error.name, error.message);
            if !self.bonded(core) {
                // Turned down at the pairing: not asked again on this link,
                // unless it pairs after all.
                log(&format!("{} did not pair ({why})", self.name(core)));
                self.turned_down = true;
                return true;
            }
            self.tries += 1;
            self.refused = true;
            let delay = (5.0 * 2f64.powi(self.tries.saturating_sub(1).min(4) as i32)).min(60.0);
            log(&format!(
                "could not subscribe to {}'s {} ({why}); again in {delay} s",
                self.name(core),
                role.name()
            ));
            self.retry = Some(core.timers.add(delay, Timer::Retry { phone: self.id }));
            return true;
        }
        self.refused = false;
        self.asked.insert(path);
        self.subscribe(core);
        true
    }

    fn try_again(&mut self, core: &mut Core) {
        self.retry = None;
        if self.connected && !self.ready(core) {
            self.subscribe(core);
        }
    }

    // -- the iPhone's events

    fn event(&mut self, core: &mut Core, value: &[u8]) {
        let Some(event) = ancs::parse_event(value) else {
            log("a malformed event, passed over");
            return;
        };
        let uid = event.uid;
        if event.kind == ancs::REMOVED {
            self.known.remove(uid);
            if self.pending.remove(&uid).is_some() {
                if let Some(at) = self.queue.iter().position(|j| *j == Job::Note(uid)) {
                    self.queue.remove(at);
                }
            }
            if let Some((note, _)) = self.shown.remove(&uid) {
                core.close(note);
            }
            return;
        }
        self.known.insert(uid);
        if self.known.len() > KNOWN_MOST {
            self.known.drop_oldest();
        }
        // Calls stay on the iPhone.
        if event.category == ancs::INCOMING_CALL {
            return;
        }
        if event.kind == ancs::MODIFIED {
            // Only one still on screen is drawn again.
            if self.shown.contains_key(&uid) && !self.pending.contains_key(&uid) {
                self.fetch(core, event, true, false);
            }
            return;
        }
        if event.flags & ancs::PRE_EXISTING != 0 {
            if self.missed(uid, core) {
                self.fetch(core, event, false, true);
            }
            return;
        }
        self.fetch(core, event, false, false);
    }

    /// A notification the iPhone had when the link came back, which it did
    /// not have when the link dropped a moment before: it may have come in
    /// the gap, which its date tells (noted). Not after a longer absence (a
    /// night asleep): those are old. A few are looked at; one older than the
    /// drop (the iPhone numbered them anew, or more than KNOWN_MOST were
    /// listed) does not count against the few shown.
    fn missed(&mut self, uid: u32, core: &Core) -> bool {
        let Some(before) = &self.before else {
            return false;
        };
        if before.contains(&uid) || self.missed_left == 0 {
            return false;
        }
        if self.missed_asked >= MISSED_ASKED_MOST
            || now_boot() - self.dropped_at > core.tunables.missed
        {
            return false;
        }
        self.missed_asked += 1;
        true
    }

    fn fetch(&mut self, core: &mut Core, event: Event, replace: bool, missed: bool) {
        // Asked about already: once is enough.
        if self.pending.contains_key(&event.uid) {
            return;
        }
        if self.pending.is_empty() {
            self.flooded = false;
        }
        if self.pending.len() >= PENDING_MOST || self.queue.len() >= QUEUE_MOST {
            if !self.flooded {
                log(&format!(
                    "more than {PENDING_MOST} notifications at once from {}: the rest passed over",
                    self.name(core)
                ));
                self.flooded = true;
            }
            return;
        }
        self.pending.insert(
            event.uid,
            Pending {
                flags: event.flags,
                category: event.category,
                replace,
                missed,
                ..Pending::default()
            },
        );
        self.queue.push_back(Job::Note(event.uid));
        self.pump(core);
    }

    // -- the Control Point, one command at a time

    fn writable(&self, core: &Core) -> bool {
        self.connected
            && self.characteristics.contains_key(&Role::ControlPoint)
            && self.notifying(core, Role::DataSource)
    }

    fn pump(&mut self, core: &mut Core) {
        while self.current.is_none() && !self.queue.is_empty() && self.writable(core) {
            let job = self.queue.pop_front().unwrap();
            let (command, answer) = match &job {
                Job::Note(uid) => {
                    let Some(pending) = self.pending.get(uid) else {
                        continue;
                    };
                    let mut attributes = vec![
                        ancs::APP_IDENTIFIER,
                        ancs::TITLE,
                        ancs::SUBTITLE,
                        ancs::MESSAGE,
                    ];
                    if pending.missed {
                        attributes.push(ancs::DATE);
                    }
                    let command = ancs::notification_attributes_command(*uid, &attributes);
                    let answer = Answer::new(&command[..5], &attributes);
                    (command, Some(answer))
                }
                Job::App(app) => {
                    let command = ancs::app_attributes_command(app);
                    let answer = Answer::new(&command[..command.len() - 1], &[ancs::DISPLAY_NAME]);
                    (command, Some(answer))
                }
                Job::Clear(uid) => (ancs::action_command(*uid, ancs::NEGATIVE), None),
            };
            let timer = core.timers.add(
                core.tunables.reply + CALL_TIMEOUT,
                Timer::Reply { phone: self.id },
            );
            self.serial += 1;
            self.current = Some(Current {
                serial: self.serial,
                job,
                answer,
                timer: Some(timer),
            });
            let path = self.characteristics[&Role::ControlPoint].clone();
            core.call_bluez(
                &path,
                GATT_CHARACTERISTIC,
                "WriteValue",
                vec![
                    bytes(&command),
                    Value::options(vec![("type", Value::str("request"))]),
                ],
                CALL_TIMEOUT,
                Then::Written {
                    phone: self.id,
                    serial: self.serial,
                },
            );
        }
    }

    fn written(&mut self, core: &mut Core, serial: u64, error: Option<BusError>) {
        if self.current.as_ref().map(|c| c.serial) != Some(serial) {
            return;
        }
        if let Some(error) = error {
            // 0xA2 is a notification the iPhone no longer has.
            log(&format!("the iPhone refused a command ({})", error.message));
            self.finish(core, None);
            return;
        }
        let current = self.current.as_mut().unwrap();
        if current.answer.is_none() {
            self.finish(core, None);
            return;
        }
        // The answer has REPLY seconds from now.
        core.timers.remove(current.timer.take());
        current.timer = Some(
            core.timers
                .add(core.tunables.reply, Timer::Reply { phone: self.id }),
        );
    }

    fn timed_out(&mut self, core: &mut Core, timer: u64) {
        if self
            .current
            .as_ref()
            .is_some_and(|c| c.timer == Some(timer))
        {
            log(&format!("no answer from {} in time", self.name(core)));
            if let Some(current) = self.current.as_mut() {
                current.timer = None;
            }
            self.finish(core, None);
        }
    }

    fn give_up_current(&mut self, core: &mut Core) {
        if let Some(current) = self.current.take() {
            core.timers.remove(current.timer);
        }
    }

    fn data(&mut self, core: &mut Core, value: &[u8]) {
        let Some(answer) = self.current.as_mut().and_then(|c| c.answer.as_mut()) else {
            return;
        };
        match answer.feed(value) {
            Err(error) => {
                log(&format!("an answer that does not fit: {error}"));
                self.finish(core, None);
            }
            Ok(Some(found)) => self.finish(core, Some(found)),
            Ok(None) => {}
        }
    }

    fn finish(&mut self, core: &mut Core, found: Option<Found>) {
        let Some(current) = self.current.take() else {
            return;
        };
        core.timers.remove(current.timer);
        match current.job {
            Job::Note(uid) => self.noted(core, uid, found),
            Job::App(app) => self.named(core, app, found),
            Job::Clear(_) => {}
        }
        self.pump(core);
    }

    fn noted(&mut self, core: &mut Core, uid: u32, found: Option<Found>) {
        let Some(info) = self.pending.get_mut(&uid) else {
            return;
        };
        let Some(found) = found else {
            self.pending.remove(&uid);
            return;
        };
        if info.missed {
            if self.missed_left == 0
                || !ancs::arrived_while_away(
                    ancs::attribute(&found, ancs::DATE),
                    self.dropped_wall,
                    wall(),
                )
            {
                self.pending.remove(&uid);
                return;
            }
            self.missed_left -= 1;
        }
        let limited = |id: u8| ancs::text(ancs::attribute(&found, id), ancs::limit(id));
        info.app = ancs::attribute(&found, ancs::APP_IDENTIFIER).to_vec();
        info.title = limited(ancs::TITLE);
        info.subtitle = limited(ancs::SUBTITLE);
        info.message = limited(ancs::MESSAGE);
        let app = info.app.clone();
        if app.is_empty() || self.apps.contains_key(&app) {
            self.show(core, uid);
        } else if let Some(uids) = self.waiting.get_mut(&app) {
            uids.push(uid);
        } else {
            self.waiting.insert(app.clone(), vec![uid]);
            // Next, ahead of the notifications waiting.
            self.queue.push_front(Job::App(app));
        }
    }

    fn named(&mut self, core: &mut Core, app: Vec<u8>, found: Option<Found>) {
        let name = found
            .map(|found| ancs::name_text(ancs::attribute(&found, ancs::DISPLAY_NAME)))
            .unwrap_or_default();
        if self.apps.len() > 200 {
            self.apps.clear();
        }
        let name = if name.is_empty() {
            ancs::app_fallback(&app)
        } else {
            name
        };
        self.apps.insert(app.clone(), name);
        for uid in self.waiting.remove(&app).unwrap_or_default() {
            self.show(core, uid);
        }
    }

    fn show(&mut self, core: &mut Core, uid: u32) {
        let Some(info) = self.pending.remove(&uid) else {
            return;
        };
        if info.replace && !self.shown.contains_key(&uid) {
            return;
        }
        let app = match self.apps.get(&info.app) {
            Some(name) if !name.is_empty() => name.clone(),
            _ if !info.app.is_empty() => ancs::app_fallback(&info.app),
            _ => "iPhone".into(),
        };
        let (summary, body) = ancs::toast_text(&app, &info.title, &info.subtitle, &info.message);
        let replaces = if info.replace { self.shown[&uid].0 } else { 0 };
        let quiet = info.flags & ancs::SILENT != 0;
        // That it came, never what it says.
        log(&format!(
            "notification {uid} {}{}",
            if replaces != 0 { "changed" } else { "shown" },
            if quiet { " quietly" } else { "" }
        ));
        core.notify(Notice {
            app,
            summary,
            body,
            glyph: ancs::glyph(info.category),
            quiet,
            replaces,
            urgency: 1,
            buttons: None,
            iphone: true,
            then: Then::Shown {
                phone: self.id,
                number: self.link_number,
                uid,
                replaces,
                flags: info.flags,
            },
        });
    }

    /// The shell showed notification <note> for <uid>.
    fn shown(
        &mut self,
        core: &mut Core,
        number: u64,
        uid: u32,
        replaces: u32,
        flags: u8,
        note: u32,
    ) {
        // Shown for a link gone since: the iPhone may have given its uid to
        // another notification by now.
        if number != self.link_number {
            return;
        }
        // A change to one dismissed while it was on its way, which the shell
        // then showed anew: dismissed it stays.
        if replaces != 0 && self.shown.get(&uid).map(|s| s.0) != Some(replaces) {
            core.close(note);
            return;
        }
        // Removed on the iPhone while the shell was showing it.
        if self.connected && !self.known.contains(uid) {
            core.close(note);
            return;
        }
        self.shown.insert(uid, (note, flags));
        core.remember(note, &self.path, uid);
    }

    /// The shell's notification <note>, of <uid>, went: dismissed here, it is
    /// cleared on the iPhone too, as a watch does; run out, or silenced by Do
    /// Not Disturb, it stays there. Only the notification shown for <uid> now
    /// counts: an older one's uid may be another's.
    fn closed(&mut self, core: &mut Core, note: u32, uid: u32, reason: u32) {
        let Some(&(shown, flags)) = self.shown.get(&uid) else {
            return;
        };
        if shown != note {
            return;
        }
        self.shown.remove(&uid);
        if reason != DISMISSED || !self.known.contains(uid) || !self.connected {
            return;
        }
        if flags & ancs::NEGATIVE_ACTION != 0 && self.queue.len() < QUEUE_MOST {
            log(&format!(
                "notification {uid} dismissed here: cleared on the iPhone"
            ));
            self.queue.push_front(Job::Clear(uid));
            self.pump(core);
        }
    }
}

// ------------------------------------------------------------- the service

/// What a notification runs, `commands` as the shell takes it ({"buttons":
/// [...]}), in a file of its own in Nova's runtime folder, `folder`, under a
/// name of 128 random bits, which the notification's nova-command hint
/// carries. The shell runs only what such a file says: any program on the
/// session bus may send a notification's hints, a sandboxed app's too, and
/// none can reach the folder (the shell's
/// plugins/notifications/components/Commands.qml). The name, for the hint.
fn commands_file(folder: &Path, commands: &str) -> std::io::Result<String> {
    use std::io::{Read, Write};
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let mut random = [0u8; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut random)?;
    let name: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(folder)?;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(folder.join(&name))?
        .write_all(commands.as_bytes())?;
    Ok(name)
}

struct Notice {
    app: String,
    summary: String,
    body: String,
    glyph: &'static str,
    quiet: bool,
    replaces: u32,
    urgency: u8,
    buttons: Option<String>,
    iphone: bool,
    then: Then,
}

/// The pairing question: BlueZ's RequestConfirmation, waiting for the user.
struct Question {
    id: u64,
    /// The method call the answer goes to, the glue's.
    call: u64,
    note: Option<u32>,
    grace: Option<u64>,
}

/// Everything but the iPhones, which their methods reach.
pub struct Core {
    pub tunables: Tunables,
    pub objects: Objects,
    pub bluez: String,
    le: bool,
    conf: PathBuf,
    state_path: PathBuf,
    /// Nova's runtime folder for what notifications run (commands_file).
    commands: PathBuf,
    /// The shell's notification → (the iPhone's path, uid), oldest first.
    notes: Vec<(u32, String, u32)>,
    advertisement: Vec<(&'static str, Value)>,
    advertising: Option<Mode>,
    advertised_at: f64,
    agent_registered: bool,
    /// Counts BlueZ's starts.
    generation: u64,
    busy: bool,
    blocked_until: f64,
    failures: u32,
    unblock: Option<u64>,
    pairing_until: f64,
    pairing_timer: Option<u64>,
    pairing_done: Option<u64>,
    fast_until: f64,
    fast_timer: Option<u64>,
    question: Option<Question>,
    questions: u64,
    published: Option<String>,
    pub timers: Timers,
    /// The calls to make, in order.
    pub out: Vec<Call>,
    /// Answers to method calls that waited: the glue's number for the call,
    /// and the error it is answered with, or none.
    pub answers: Vec<(u64, Option<BusError>)>,
}

impl Core {
    fn call_bluez(
        &mut self,
        path: &str,
        interface: &'static str,
        method: &'static str,
        args: Vec<Value>,
        timeout: f64,
        then: Then,
    ) {
        self.out.push(Call {
            bus: Bus::System,
            destination: BLUEZ,
            path: path.to_string(),
            interface,
            method,
            args,
            timeout: Duration::from_secs_f64(timeout),
            then,
        });
    }

    /// A call to the shell's notification server.
    fn call_notifications(&mut self, method: &'static str, args: Vec<Value>, then: Then) {
        self.out.push(Call {
            bus: Bus::Session,
            destination: NOTIFICATIONS,
            path: NOTIFICATIONS_PATH.to_string(),
            interface: NOTIFICATIONS,
            method,
            args,
            timeout: Duration::from_secs_f64(CALL_TIMEOUT),
            then,
        });
    }

    fn pairing_open(&self) -> bool {
        wall() < self.pairing_until
    }

    /// The first controller that can advertise.
    fn adapter(&self) -> Option<String> {
        self.objects.having(ADVERTISING_MANAGER).into_iter().next()
    }

    /// Why nothing can be done now, or "".
    fn blocker(&self) -> &'static str {
        if self.bluez.is_empty() {
            return "no-bluetooth";
        }
        let Some(adapter) = self.adapter() else {
            return "no-bluetooth";
        };
        if !self.objects.truthy(&adapter, ADAPTER, "Powered") {
            return "bluetooth-off";
        }
        if !self.le {
            return "no-le";
        }
        ""
    }

    fn schedule_fast(&mut self) {
        self.fast_until = now_boot() + self.tunables.fast;
        self.timers.remove(self.fast_timer.take());
        self.fast_timer = Some(self.timers.add(self.tunables.fast + 0.05, Timer::Fast));
    }

    /// BlueZ or a controller back: a start anew, with no waiting left of
    /// failures before, and advertising fast.
    fn fresh_start(&mut self) {
        self.failures = 0;
        self.blocked_until = 0.0;
        self.timers.remove(self.unblock.take());
        self.schedule_fast();
    }

    fn notify(&mut self, notice: Notice) {
        let mut hints = vec![
            ("urgency", Value::Byte(notice.urgency)),
            ("nova-glyph", Value::str(notice.glyph)),
        ];
        if notice.quiet {
            hints.push(("nova-quiet", Value::Bool(true)));
        }
        let mut then = notice.then;
        if let Some(buttons) = notice.buttons {
            match commands_file(&self.commands, &format!("{{\"buttons\": {buttons}}}")) {
                Ok(name) => {
                    // Buttons come with a question alone, whose reply takes
                    // the file away if the notification is not shown.
                    if let Then::Asked { commands, .. } = &mut then {
                        *commands = Some(name.clone());
                    }
                    hints.push(("nova-command", Value::Str(name)));
                }
                Err(error) => log(&format!(
                    "could not give a notification its buttons: {error}"
                )),
            }
        }
        if notice.iphone {
            // The app is the iPhone's: a click on it, also in the history
            // after the notification is gone, does not bring forward an app
            // of this computer that has the same name.
            hints.push(("nova-iphone", Value::Bool(true)));
        }
        // A default action, so that a click is a dismissal: there is no
        // window here to bring forward for an iPhone's app.
        let actions: &[&str] = if notice.iphone {
            &["default", "Show"]
        } else {
            &[]
        };
        self.call_notifications(
            "Notify",
            vec![
                Value::Str(notice.app),
                Value::Uint32(notice.replaces),
                Value::str(""),
                Value::Str(notice.summary),
                Value::Str(notice.body),
                Value::strings(actions),
                Value::options(hints),
                Value::Int32(-1),
            ],
            then,
        );
    }

    fn close(&mut self, note: u32) {
        self.notes.retain(|(n, _, _)| *n != note);
        self.call_notifications(
            "CloseNotification",
            vec![Value::Uint32(note)],
            Then::Nothing,
        );
    }

    fn remember(&mut self, note: u32, path: &str, uid: u32) {
        match self.notes.iter_mut().find(|(n, _, _)| *n == note) {
            Some(entry) => *entry = (note, path.to_string(), uid),
            None => self.notes.push((note, path.to_string(), uid)),
        }
        if self.notes.len() > NOTES_MOST {
            self.notes.remove(0);
        }
    }

    /// Those of an iPhone's link gone: a dismissal of one clears nothing.
    fn forget_notes(&mut self, path: &str) {
        self.notes.retain(|(_, p, _)| p != path);
    }

    fn withdraw_question(&mut self, why: &str) {
        let Some(question) = self.question.take() else {
            return;
        };
        log(&format!("pairing question withdrawn: {why}"));
        self.timers.remove(question.grace);
        if let Some(note) = question.note {
            self.close(note);
        }
        self.answers
            .push((question.call, Some(BusError::new(REJECTED, why))));
    }

    /// What is advertised, for BlueZ's GetAll.
    fn set_advertisement(&mut self, mode: Mode, name: &str) {
        let (low, high) = mode.intervals();
        let mut properties = vec![
            ("Type", Value::str("peripheral")),
            // What gets a computer into an iPhone's Settings → Bluetooth.
            ("SolicitUUIDs", Value::strings(&[ancs::ANCS_SERVICE])),
            ("Discoverable", Value::Bool(mode == Mode::Pairing)),
            ("MinInterval", Value::Uint32(low)),
            ("MaxInterval", Value::Uint32(high)),
        ];
        if mode == Mode::Pairing && !name.is_empty() {
            properties.push(("LocalName", Value::str(name)));
        }
        self.advertisement = properties;
    }

    fn back_off(&mut self, why: &str) {
        let delay = (5u64 << self.failures.min(6)).min(300);
        self.failures += 1;
        log(&format!("{why}; again in {delay} s"));
        self.blocked_until = monotonic() + delay as f64;
        self.timers.remove(self.unblock.take());
        self.unblock = Some(self.timers.add(delay as f64, Timer::Unblock));
    }
}

/// What the agent answers a method call with.
#[derive(Debug, PartialEq)]
pub enum Reply {
    /// Answered now, with nothing.
    Empty,
    /// Answered now, with an error.
    Error(BusError),
    /// Answered later, through `answers`.
    Later,
}

pub struct Service {
    pub core: Core,
    pub phones: Vec<Phone>,
    phone_ids: u64,
}

impl Service {
    pub fn new(runtime: &Path, conf: &Path, tunables: Tunables) -> Service {
        let mut service = Service {
            core: Core {
                tunables,
                objects: Objects::default(),
                bluez: String::new(),
                le: le_enabled(conf),
                conf: conf.to_path_buf(),
                state_path: runtime.join("nova").join("iphone-notifications.json"),
                commands: runtime.join("nova").join("notifications"),
                notes: Vec::new(),
                advertisement: Vec::new(),
                advertising: None,
                advertised_at: 0.0,
                agent_registered: false,
                generation: 0,
                busy: false,
                blocked_until: 0.0,
                failures: 0,
                unblock: None,
                pairing_until: 0.0,
                pairing_timer: None,
                pairing_done: None,
                fast_until: 0.0,
                fast_timer: None,
                question: None,
                questions: 0,
                published: None,
                timers: Timers::default(),
                out: Vec::new(),
                answers: Vec::new(),
            },
            phones: Vec::new(),
            phone_ids: 0,
        };
        service.core.schedule_fast();
        service
    }

    // -- BlueZ coming and going

    pub fn bluez_owner(&mut self, owner: &str) {
        // A pairing question was the BlueZ before's to answer, and its toast
        // goes: the new one asks anew.
        self.core.withdraw_question("BlueZ restarted");
        self.core.bluez = owner.to_string();
        // A reply from the BlueZ before, come late, says nothing of this one.
        self.core.generation += 1;
        // Bluetooth LE is switched by restarting BlueZ.
        self.core.le = le_enabled(&self.core.conf);
        self.core.objects = Objects::default();
        self.core.advertising = None;
        self.core.agent_registered = false;
        self.core.busy = false;
        for mut phone in std::mem::take(&mut self.phones) {
            phone.gone(&mut self.core);
        }
        if self.core.bluez.is_empty() {
            log("BlueZ is not running");
            self.update();
            return;
        }
        let generation = self.core.generation;
        self.core.call_bluez(
            "/",
            OBJECT_MANAGER,
            "GetManagedObjects",
            vec![],
            CALL_TIMEOUT,
            Then::Managed { generation },
        );
    }

    pub fn interfaces_added(&mut self, path: &str, interfaces: &[(String, Properties)]) {
        self.core.objects.added(path, interfaces);
        if interfaces.iter().any(|(i, _)| i == ADAPTER) {
            // A controller back, after a reset of its firmware.
            self.core.fresh_start();
        }
        self.update();
    }

    pub fn interfaces_removed(&mut self, path: &str, interfaces: &[String]) {
        self.core.objects.removed(path, interfaces);
        if interfaces.iter().any(|i| i == DEVICE) {
            if let Some(at) = self.phones.iter().position(|p| p.path == path) {
                let mut phone = self.phones.remove(at);
                phone.gone(&mut self.core);
            }
        }
        self.update();
    }

    pub fn properties_changed(
        &mut self,
        path: &str,
        interface: &str,
        changed: &Properties,
        invalidated: &[String],
    ) {
        if !self
            .core
            .objects
            .changed(path, interface, changed, invalidated)
        {
            return;
        }
        if interface == GATT_CHARACTERISTIC {
            if let Some(value) = changed.get("Value") {
                let bytes = value.as_bytes().unwrap_or_default();
                for phone in &mut self.phones {
                    let role = phone
                        .characteristics
                        .iter()
                        .find(|(_, p)| p.as_str() == path)
                        .map(|(r, _)| *r);
                    match role {
                        Some(Role::NotificationSource) => phone.event(&mut self.core, &bytes),
                        Some(Role::DataSource) => phone.data(&mut self.core, &bytes),
                        _ => {}
                    }
                }
                if changed.len() == 1 {
                    return;
                }
            }
        }
        if !self.relevant(path, interface, changed) {
            return;
        }
        if interface == ADAPTER && changed.get("Powered") == Some(&Value::Bool(true)) {
            self.core.fresh_start();
        }
        self.update();
    }

    pub fn sleeping(&mut self, start: bool) {
        // Awake again: the iPhone lost the link while the computer slept.
        if !start {
            log("awake: advertising fast again");
            self.core.schedule_fast();
            self.update();
        }
    }

    /// A Phone for each device with ANCS: listed among its services, or
    /// with the service among its objects.
    fn sync_phones(&mut self) {
        let mut with_service = HashSet::new();
        for (path, entry) in &self.core.objects.tree {
            let uuid = entry
                .get(GATT_SERVICE)
                .and_then(|p| p.get("UUID"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_lowercase();
            if uuid == ancs::ANCS_SERVICE {
                if let Some((device, _)) = path.rsplit_once('/') {
                    with_service.insert(device.to_string());
                }
            }
        }
        for path in self.core.objects.having(DEVICE) {
            let uuids: Vec<String> = self
                .core
                .objects
                .get(&path, DEVICE, "UUIDs")
                .map(strings_of)
                .unwrap_or_default()
                .into_iter()
                .map(|u| u.to_lowercase())
                .collect();
            let ancs =
                uuids.iter().any(|u| u == ancs::ANCS_SERVICE) || with_service.contains(&path);
            if ancs && !self.phones.iter().any(|p| p.path == path) {
                self.phone_ids += 1;
                self.phones.push(Phone::new(self.phone_ids, &path));
            }
        }
        for phone in &mut self.phones {
            phone.refresh(&mut self.core);
        }
    }

    /// Whether a change matters here: a scan nearby changes devices' signal
    /// strengths many times a second, which do not.
    fn relevant(&self, path: &str, interface: &str, changed: &Properties) -> bool {
        if [ADAPTER, LE_BEARER, GATT_CHARACTERISTIC, GATT_SERVICE].contains(&interface) {
            return true;
        }
        if self
            .phones
            .iter()
            .any(|p| path == p.path || path.starts_with(&format!("{}/", p.path)))
        {
            return true;
        }
        interface == DEVICE
            && ["UUIDs", "Paired", "Bonded", "Connected", "ServicesResolved"]
                .iter()
                .any(|name| changed.contains_key(*name))
    }

    // -- pairing

    /// Opens the pairing window; with <only_without_iphone>, only when no
    /// iPhone is paired already (switching it on). Whether it opened.
    pub fn open_pairing(&mut self, only_without_iphone: bool) -> bool {
        if only_without_iphone && self.phones.iter().any(|p| p.bonded(&self.core)) {
            return false;
        }
        log("pairing window open");
        self.core.pairing_until = wall() + self.core.tunables.pair;
        self.core.timers.remove(self.core.pairing_timer.take());
        self.core.pairing_timer = Some(
            self.core
                .timers
                .add(self.core.tunables.pair + 0.05, Timer::PairingOver),
        );
        self.update();
        true
    }

    fn close_pairing(&mut self) {
        if self.core.pairing_until != 0.0 {
            log("pairing window closed");
        }
        self.core.pairing_until = 0.0;
        self.core.timers.remove(self.core.pairing_timer.take());
        self.core.timers.remove(self.core.pairing_done.take());
        self.core.withdraw_question("the pairing window closed");
        self.core.schedule_fast();
        self.update();
    }

    /// BlueZ asks whether <device> may pair: the user answers on a
    /// notification, with the code to compare. One question at a time: a
    /// second device asking meanwhile is turned down, and the first one's
    /// question stands. The error it is turned down with at once, or none
    /// while the user is asked.
    fn ask(&mut self, call: u64, device: &str, passkey: u32) -> Option<BusError> {
        if !self.core.pairing_open() {
            return Some(BusError::new(REJECTED, "not pairing now"));
        }
        if self.core.question.is_some() {
            log(&format!(
                "turned down a second pairing while one is asked about ({device})"
            ));
            return Some(BusError::new(
                REJECTED,
                "another pairing is being asked about",
            ));
        }
        // The device's own name: what it sends is shown as plain text.
        let mut name =
            ancs::name_text(self.core.objects.string(device, DEVICE, "Alias").as_bytes());
        if name.is_empty() {
            name = "an iPhone".into();
        }
        self.core.questions += 1;
        let id = self.core.questions;
        self.core.question = Some(Question {
            id,
            call,
            note: None,
            grace: None,
        });
        let body = format!("Check that your iPhone shows {passkey:06}.");
        let buttons = r#"[{"says": "Cancel", "argv": ["nova-notification-iphone", "answer", "no"]}, {"says": "Pair", "argv": ["nova-notification-iphone", "answer", "yes"], "main": true}]"#;
        self.core.notify(Notice {
            app: "nova-action".into(),
            summary: format!("Pair with “{name}”?"),
            body: ancs::escape(&body),
            glyph: ancs::BLUETOOTH_GLYPH,
            quiet: false,
            replaces: 0,
            urgency: 2,
            buttons: Some(buttons.into()),
            iphone: false,
            then: Then::Asked {
                question: id,
                commands: None,
            },
        });
        None
    }

    /// The pairing notification's buttons.
    pub fn answer(&mut self, yes: bool) {
        let Some(question) = self.core.question.take() else {
            return;
        };
        log(if yes {
            "pairing agreed to"
        } else {
            "pairing turned down"
        });
        self.core.timers.remove(question.grace);
        if let Some(note) = question.note {
            self.core.close(note);
        }
        let error = (!yes).then(|| BusError::new(REJECTED, "turned down"));
        self.core.answers.push((question.call, error));
    }

    fn question_closed(&mut self) {
        // A button closes the notification as it runs its command, so the
        // command's Answer comes a moment after: it is waited for.
        if let Some(question) = self.core.question.as_mut() {
            if question.grace.is_none() {
                question.note = None;
                question.grace = Some(self.core.timers.add(
                    3.0,
                    Timer::Grace {
                        question: question.id,
                    },
                ));
            }
        }
    }

    /// A method of the pairing agent, called by <sender>. It answers nothing
    /// by itself: a code is compared and agreed to by the user, and a
    /// profile is never let in. It answers BlueZ alone: anyone on the system
    /// bus could call it.
    pub fn agent(&mut self, sender: &str, method: &str, args: &[Value], call: u64) -> Reply {
        let from_bluez = !self.core.bluez.is_empty() && sender == self.core.bluez;
        let device = args
            .first()
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let rejected = |why: &str| Reply::Error(BusError::new(REJECTED, why));
        match method {
            // An iPhone pairs with LE Secure Connections and a code to
            // compare (numeric comparison): both sides have a display and a
            // yes or no.
            "RequestConfirmation" => {
                if !from_bluez {
                    return rejected("only BlueZ asks this");
                }
                let passkey = args.get(1).and_then(Value::as_i64).unwrap_or(0) as u32;
                match self.ask(call, &device, passkey) {
                    Some(error) => Reply::Error(error),
                    None => Reply::Later,
                }
            }
            // Pairing with no code to compare (Just Works), which an iPhone
            // does not ask for: a device that does is not let pair unseen.
            "RequestAuthorization" => {
                if !from_bluez {
                    return rejected("only BlueZ asks this");
                }
                log(&format!(
                    "turned down a pairing with no code to compare ({device})"
                ));
                rejected("a pairing needs a code to compare")
            }
            // The iPhone's audio and calls stay on the iPhone.
            "AuthorizeService" => {
                if !from_bluez {
                    return rejected("only BlueZ asks this");
                }
                let uuid = args.get(1).and_then(Value::as_str).unwrap_or("");
                log(&format!("turned down a profile ({uuid}) of {device}"));
                rejected("iPhone notifications let no profile in")
            }
            "RequestPinCode" => rejected("no PIN codes"),
            "RequestPasskey" => rejected("no passkeys to type"),
            "DisplayPasskey" | "DisplayPinCode" => Reply::Empty,
            "Cancel" => {
                if !from_bluez {
                    return rejected("only BlueZ asks this");
                }
                self.core.withdraw_question("cancelled by BlueZ");
                Reply::Empty
            }
            "Release" => {
                if !from_bluez {
                    return rejected("only BlueZ asks this");
                }
                self.core.agent_registered = false;
                self.update();
                Reply::Empty
            }
            _ => Reply::Error(BusError::new(
                "org.freedesktop.DBus.Error.UnknownMethod",
                &format!("no method {method}"),
            )),
        }
    }

    /// The advertisement's properties, for BlueZ.
    pub fn advertisement(&self, interface: &str) -> Result<Vec<(&'static str, Value)>, BusError> {
        if interface != ADVERTISEMENT {
            return Err(BusError::new(
                "org.freedesktop.DBus.Error.InvalidArgs",
                "no such interface",
            ));
        }
        Ok(self.core.advertisement.clone())
    }

    /// BlueZ let the advertisement go: the controller went, or it could not
    /// keep it.
    pub fn advertisement_released(&mut self, sender: &str) {
        if self.core.bluez.is_empty() || sender != self.core.bluez {
            return;
        }
        log("BlueZ released the advertisement");
        self.core.advertising = None;
        if monotonic() - self.core.advertised_at < 10.0 {
            self.core.back_off("released at once");
        }
        self.update();
    }

    // -- notifications

    pub fn notification_closed(&mut self, note: u32, reason: u32) {
        if self
            .core
            .question
            .as_ref()
            .is_some_and(|q| q.note == Some(note))
        {
            self.question_closed();
            return;
        }
        let Some(at) = self.core.notes.iter().position(|(n, _, _)| *n == note) else {
            return;
        };
        let (_, path, uid) = self.core.notes.remove(at);
        if let Some(phone) = self.phones.iter_mut().find(|p| p.path == path) {
            phone.closed(&mut self.core, note, uid, reason);
        }
    }

    pub fn notifications_owner(&mut self) {
        // Another server counts its ids from 1 again: the old ones mean
        // nothing now.
        self.core.notes.clear();
        for phone in &mut self.phones {
            phone.shown.clear();
        }
    }

    // -- replies and timers

    pub fn reply(&mut self, then: Then, result: Result<Vec<Value>, BusError>) {
        match then {
            Then::Nothing => {}
            Then::Managed { generation } => match result {
                Ok(values) if generation == self.core.generation => {
                    if let Some(managed) = values.first() {
                        self.core.objects.load(managed);
                    }
                    self.core.fresh_start();
                    self.update();
                }
                Ok(_) => {}
                Err(error) => log(&format!(
                    "could not read BlueZ's objects: {}",
                    error.message
                )),
            },
            Then::Subscribed {
                phone,
                number,
                role,
                path,
            } => {
                let error = result.err();
                if let Some(at) = self.phones.iter().position(|p| p.id == phone) {
                    let (core, phones) = (&mut self.core, &mut self.phones);
                    if phones[at].subscribed(core, number, role, path, error) {
                        self.update();
                    }
                }
            }
            Then::Written { phone, serial } => {
                let error = result.err();
                if let Some(at) = self.phones.iter().position(|p| p.id == phone) {
                    let (core, phones) = (&mut self.core, &mut self.phones);
                    phones[at].written(core, serial, error);
                }
            }
            Then::Shown {
                phone,
                number,
                uid,
                replaces,
                flags,
            } => match result {
                Ok(values) => {
                    let note = values.first().and_then(Value::as_i64).unwrap_or(0) as u32;
                    if let Some(at) = self.phones.iter().position(|p| p.id == phone) {
                        let (core, phones) = (&mut self.core, &mut self.phones);
                        phones[at].shown(core, number, uid, replaces, flags, note);
                    }
                }
                Err(error) => log(&format!("could not show a notification: {}", error.message)),
            },
            Then::Asked { question, commands } => match result {
                Ok(values) => {
                    let note = values.first().and_then(Value::as_i64).unwrap_or(0) as u32;
                    match self.core.question.as_mut() {
                        Some(q) if q.id == question => q.note = Some(note),
                        _ => self.core.close(note),
                    }
                }
                Err(error) => {
                    log(&format!("could not show a notification: {}", error.message));
                    // Not shown, or not known to be: its commands go, which
                    // no notification will claim now.
                    if let Some(name) = commands {
                        let _ = std::fs::remove_file(self.core.commands.join(name));
                    }
                }
            },
            Then::Unregistered { generation } => {
                if generation == self.core.generation {
                    self.core.advertising = None;
                    self.settle();
                }
            }
            Then::Registered { generation, mode } => {
                if generation != self.core.generation {
                    return;
                }
                match result {
                    Ok(_) => {
                        self.core.advertising = Some(mode);
                        self.core.advertised_at = monotonic();
                        self.core.failures = 0;
                        let (low, high) = mode.intervals();
                        log(&format!(
                            "advertising ({}, every {low}-{high} ms)",
                            mode.name()
                        ));
                    }
                    Err(error) => self.core.back_off(&format!(
                        "could not advertise: {}: {}",
                        error.name, error.message
                    )),
                }
                self.settle();
            }
            Then::AgentGone { generation } => {
                if generation == self.core.generation {
                    self.core.agent_registered = false;
                    log("pairing agent gone");
                    self.settle();
                }
            }
            // Failed at either step, the window closes; registered, the
            // agent is then unregistered by the reconciling that follows.
            Then::AgentRegistered { generation } | Then::AgentDefault { generation }
                if generation != self.core.generation => {}
            Then::AgentRegistered { generation } => match result {
                Ok(_) => {
                    self.core.agent_registered = true;
                    self.core.call_bluez(
                        "/org/bluez",
                        AGENT_MANAGER,
                        "RequestDefaultAgent",
                        vec![Value::path(AGENT_PATH)],
                        CALL_TIMEOUT,
                        Then::AgentDefault { generation },
                    );
                }
                Err(error) => self.agent_failed(error),
            },
            Then::AgentDefault { .. } => match result {
                Ok(_) => {
                    log("pairing agent ready");
                    self.settle();
                }
                Err(error) => self.agent_failed(error),
            },
        }
    }

    fn agent_failed(&mut self, error: BusError) {
        log(&format!(
            "could not make the pairing agent BlueZ's: {}",
            error.message
        ));
        self.close_pairing();
        self.settle();
    }

    /// Runs the timers that are due.
    pub fn run_timers(&mut self) {
        while let Some((id, timer)) = self.core.timers.take_due(Instant::now()) {
            self.fire(id, timer);
        }
    }

    fn fire(&mut self, id: u64, timer: Timer) {
        match timer {
            Timer::Retry { phone } => {
                if let Some(at) = self.phones.iter().position(|p| p.id == phone) {
                    let (core, phones) = (&mut self.core, &mut self.phones);
                    if phones[at].retry == Some(id) {
                        phones[at].try_again(core);
                    }
                }
            }
            Timer::Reply { phone } => {
                if let Some(at) = self.phones.iter().position(|p| p.id == phone) {
                    let (core, phones) = (&mut self.core, &mut self.phones);
                    phones[at].timed_out(core, id);
                }
            }
            Timer::Fast => {
                self.core.fast_timer = None;
                self.update();
            }
            Timer::PairingOver => {
                self.core.pairing_timer = None;
                self.close_pairing();
            }
            Timer::PairingDone => {
                self.core.pairing_done = None;
                self.close_pairing();
            }
            Timer::Unblock => {
                self.core.unblock = None;
                self.reconcile();
            }
            Timer::Grace { question } => {
                if self
                    .core
                    .question
                    .as_ref()
                    .is_some_and(|q| q.id == question)
                {
                    if let Some(q) = self.core.question.as_mut() {
                        q.grace = None;
                    }
                    self.core.withdraw_question("its notification was closed");
                }
            }
        }
    }

    // -- keeping BlueZ in line

    /// What the computer should advertise now, or None.
    fn wanted(&self) -> Option<Mode> {
        if !self.core.blocker().is_empty() {
            return None;
        }
        let connected = self.phones.iter().any(|p| p.connected);
        if self.core.pairing_open() {
            return (!connected).then_some(Mode::Pairing);
        }
        if self
            .phones
            .iter()
            .any(|p| p.bonded(&self.core) && !p.connected)
        {
            return Some(if now_boot() < self.core.fast_until {
                Mode::Fast
            } else {
                Mode::Slow
            });
        }
        None
    }

    pub fn update(&mut self) {
        self.sync_phones();
        self.finish_pairing();
        self.reconcile();
        self.publish();
    }

    fn finish_pairing(&mut self) {
        // Paired and subscribed: the window closes a little later, so that
        // BlueZ is not told to stop pairing while it is still storing keys.
        if self.core.pairing_open()
            && self.core.pairing_done.is_none()
            && self
                .phones
                .iter()
                .any(|p| p.bonded(&self.core) && p.ready(&self.core))
        {
            self.core.pairing_done = Some(self.core.timers.add(2.0, Timer::PairingDone));
        }
    }

    fn reconcile(&mut self) {
        if self.core.busy {
            return;
        }
        let want_agent = self.core.pairing_open() && self.core.blocker().is_empty();
        if want_agent != self.core.agent_registered && !self.core.bluez.is_empty() {
            self.step_agent(want_agent);
            return;
        }
        let want = self.wanted();
        if want == self.core.advertising {
            return;
        }
        let adapter = self.core.adapter();
        let generation = self.core.generation;
        if self.core.advertising.is_some() {
            self.core.busy = true;
            self.core.call_bluez(
                adapter.as_deref().unwrap_or("/org/bluez/hci0"),
                ADVERTISING_MANAGER,
                "UnregisterAdvertisement",
                vec![Value::path(ADVERTISEMENT_PATH)],
                CALL_TIMEOUT,
                Then::Unregistered { generation },
            );
            return;
        }
        let (Some(adapter), Some(want)) = (adapter, want) else {
            return;
        };
        if monotonic() < self.core.blocked_until {
            return;
        }
        let alias = self.core.objects.string(&adapter, ADAPTER, "Alias");
        self.core.set_advertisement(want, &alias);
        self.core.busy = true;
        self.core.call_bluez(
            &adapter,
            ADVERTISING_MANAGER,
            "RegisterAdvertisement",
            vec![
                Value::path(ADVERTISEMENT_PATH),
                Value::options::<&str>(vec![]),
            ],
            CALL_TIMEOUT,
            Then::Registered {
                generation,
                mode: want,
            },
        );
    }

    fn settle(&mut self) {
        self.core.busy = false;
        self.update();
    }

    fn step_agent(&mut self, register: bool) {
        self.core.busy = true;
        let generation = self.core.generation;
        if register {
            self.core.call_bluez(
                "/org/bluez",
                AGENT_MANAGER,
                "RegisterAgent",
                vec![Value::path(AGENT_PATH), Value::str("DisplayYesNo")],
                CALL_TIMEOUT,
                Then::AgentRegistered { generation },
            );
        } else {
            self.core.call_bluez(
                "/org/bluez",
                AGENT_MANAGER,
                "UnregisterAgent",
                vec![Value::path(AGENT_PATH)],
                CALL_TIMEOUT,
                Then::AgentGone { generation },
            );
        }
    }

    // -- what Settings reads

    fn state(&self) -> &'static str {
        let blocker = self.core.blocker();
        if !blocker.is_empty() {
            return blocker;
        }
        if self.core.pairing_open() {
            return "pairing";
        }
        let states: Vec<&str> = self
            .phones
            .iter()
            .filter(|p| p.bonded(&self.core) || p.connected)
            .map(|p| p.state(&self.core))
            .collect();
        ["connected", "not-shared", "connecting", "waiting"]
            .into_iter()
            .find(|s| states.contains(s))
            .unwrap_or("no-iphone")
    }

    /// The state as Settings and `nova notification iphone` read it, its
    /// keys in order.
    pub fn state_json(&self) -> String {
        let core = &self.core;
        let adapter = core.adapter();
        let mut out = String::from("{\"advertising\": ");
        json_string(core.advertising.map_or("", Mode::name), &mut out);
        out.push_str(", \"link\": ");
        match self.phones.iter().find_map(|p| p.link(core)) {
            Some(link) => {
                let number = |v: Option<i64>| v.map_or("null".into(), |v| v.to_string());
                out.push_str(&format!(
                    "{{\"interval\": {:?}, \"latency\": {}, \"timeout\": {}}}",
                    link.interval,
                    number(link.latency),
                    number(link.timeout)
                ));
            }
            None => out.push_str("null"),
        }
        out.push_str(", \"name\": ");
        let name = adapter.map_or(String::new(), |a| core.objects.string(&a, ADAPTER, "Alias"));
        json_string(&name, &mut out);
        let until = if core.pairing_open() {
            core.pairing_until as i64
        } else {
            0
        };
        out.push_str(&format!(", \"pairingUntil\": {until}, \"phones\": ["));
        let mut first = true;
        for phone in self.phones.iter().filter(|p| p.bonded(core) || p.connected) {
            if !first {
                out.push_str(", ");
            }
            first = false;
            out.push_str("{\"address\": ");
            json_string(
                &core.objects.string(&phone.path, DEVICE, "Address"),
                &mut out,
            );
            out.push_str(&format!(", \"connected\": {}, \"name\": ", phone.connected));
            json_string(&phone.name(core), &mut out);
            out.push_str(", \"state\": ");
            json_string(phone.state(core), &mut out);
            out.push('}');
        }
        out.push_str("], \"state\": ");
        json_string(self.state(), &mut out);
        out.push('}');
        out
    }

    fn publish(&mut self) {
        let text = self.state_json();
        if self.core.published.as_ref() == Some(&text) {
            return;
        }
        let path = &self.core.state_path;
        let temporary = PathBuf::from(format!("{}.{}", path.display(), std::process::id()));
        let written = std::fs::write(&temporary, format!("{text}\n"))
            .and_then(|_| std::fs::rename(&temporary, path));
        if let Err(error) = written {
            log(&format!("could not write {}: {error}", path.display()));
        }
        self.core.published = Some(text);
    }

    /// BlueZ drops what a program registered once it leaves the bus, so this
    /// is only to be tidy: the question withdrawn, the state gone. The calls
    /// it returns are made and waited for, briefly.
    pub fn stop(&mut self) -> Vec<Call> {
        self.core
            .withdraw_question("iPhone notifications are switched off");
        let mut calls = Vec::new();
        if !self.core.bluez.is_empty() {
            if let Some(adapter) = self.core.adapter() {
                calls.push(Call {
                    bus: Bus::System,
                    destination: BLUEZ,
                    path: adapter,
                    interface: ADVERTISING_MANAGER,
                    method: "UnregisterAdvertisement",
                    args: vec![Value::path(ADVERTISEMENT_PATH)],
                    timeout: Duration::from_secs(2),
                    then: Then::Nothing,
                });
            }
            calls.push(Call {
                bus: Bus::System,
                destination: BLUEZ,
                path: "/org/bluez".into(),
                interface: AGENT_MANAGER,
                method: "UnregisterAgent",
                args: vec![Value::path(AGENT_PATH)],
                timeout: Duration::from_secs(2),
                then: Then::Nothing,
            });
        }
        let _ = std::fs::remove_file(&self.core.state_path);
        calls
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("nova-iphone-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("nova")).unwrap();
        dir
    }

    fn conf(dir: &Path, text: &str) -> PathBuf {
        let path = dir.join("main.conf");
        std::fs::write(&path, text).unwrap();
        path
    }

    #[test]
    fn low_energy_as_bluez_reads_controller_mode() {
        let dir = scratch("le");
        assert!(le_enabled(&conf(
            &dir,
            "[General]\n#ControllerMode = bredr\n"
        )));
        assert!(!le_enabled(&conf(
            &dir,
            "[General]\nControllerMode = bredr # classic only\n"
        )));
        assert!(le_enabled(&conf(
            &dir,
            "[General]\nControllerMode = dual\n[LE]\nControllerMode = bredr\n"
        )));
        assert!(le_enabled(Path::new("/nonexistent/main.conf")));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_uids_known_keep_their_order_and_the_oldest_goes() {
        let mut known = Known::default();
        for uid in [5, 6, 7] {
            known.insert(uid);
        }
        // Listed again, it stays where it was first.
        known.insert(5);
        known.drop_oldest();
        assert!(!known.contains(5) && known.contains(6) && known.contains(7));
        known.remove(6);
        assert_eq!(known.set(), HashSet::from([7]));
        assert_eq!(known.len(), 1);
    }

    #[test]
    fn a_timer_taken_out_never_fires() {
        let mut timers = Timers::default();
        let first = timers.add(0.0, Timer::Fast);
        timers.add(0.0, Timer::Unblock);
        timers.remove(Some(first));
        let now = Instant::now() + Duration::from_millis(1);
        assert_eq!(timers.take_due(now).map(|(_, t)| t), Some(Timer::Unblock));
        assert_eq!(timers.take_due(now), None);
        assert_eq!(timers.next_due(), None);
    }

    #[test]
    fn with_no_bluez_it_says_so_and_asks_nothing_of_it() {
        let dir = scratch("nobluez");
        let mut service = Service::new(&dir, &conf(&dir, ""), Tunables::from_env());
        service.bluez_owner("");
        assert!(service.core.out.is_empty());
        let state = std::fs::read_to_string(dir.join("nova/iphone-notifications.json")).unwrap();
        assert_eq!(
            state,
            "{\"advertising\": \"\", \"link\": null, \"name\": \"\", \"pairingUntil\": 0, \"phones\": [], \"state\": \"no-bluetooth\"}\n"
        );
        // Stopped, it takes its state with it.
        assert!(service.stop().is_empty());
        assert!(!dir.join("nova/iphone-notifications.json").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn bluez_back_is_asked_for_its_objects_and_an_old_answer_is_passed_over() {
        let dir = scratch("generation");
        let mut service = Service::new(&dir, &conf(&dir, ""), Tunables::from_env());
        service.bluez_owner(":1.5");
        let asked = std::mem::take(&mut service.core.out);
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0].method, "GetManagedObjects");
        // BlueZ restarts before it answers: the first answer counts for nothing.
        service.bluez_owner(":1.6");
        let managed = Value::Dict(
            "o".into(),
            "a{sa{sv}}".into(),
            vec![(
                Value::path("/org/bluez/hci0"),
                Value::Dict(
                    "s".into(),
                    "a{sv}".into(),
                    vec![(
                        Value::str(ADVERTISING_MANAGER),
                        Value::options::<&str>(vec![]),
                    )],
                ),
            )],
        );
        service.reply(asked[0].then.clone(), Ok(vec![managed]));
        assert!(service.core.objects.tree.is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_question_not_shown_takes_its_file_of_commands_away() {
        let dir = scratch("unshown");
        let mut service = Service::new(&dir, &conf(&dir, ""), Tunables::from_env());
        let ask = |service: &mut Service, question| {
            service.core.notify(Notice {
                app: "nova-action".into(),
                summary: "Pair?".into(),
                body: String::new(),
                glyph: "",
                quiet: false,
                replaces: 0,
                urgency: 2,
                buttons: Some(r#"[{"says": "Pair", "argv": ["true"], "main": true}]"#.into()),
                iphone: false,
                then: Then::Asked {
                    question,
                    commands: None,
                },
            });
            let call = std::mem::take(&mut service.core.out).pop().unwrap();
            let Then::Asked {
                commands: Some(name),
                ..
            } = call.then.clone()
            else {
                panic!("the question's reply names no file: {:?}", call.then);
            };
            (call, dir.join("nova/notifications").join(name))
        };
        // The call failed, or ran out of time: the file goes.
        let (call, file) = ask(&mut service, 1);
        assert!(file.exists());
        service.reply(
            call.then,
            Err(BusError::new("org.freedesktop.DBus.Error.NoReply", "timed out")),
        );
        assert!(!file.exists());
        // Shown: it stays, for the shell to claim.
        let (call, file) = ask(&mut service, 2);
        service.reply(call.then, Ok(vec![Value::Uint32(7)]));
        assert!(file.exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_pairing_agent_answers_bluez_alone() {
        let dir = scratch("agent");
        let mut service = Service::new(&dir, &conf(&dir, ""), Tunables::from_env());
        service.bluez_owner(":1.5");
        let args = [Value::path("/org/bluez/hci0/dev_1"), Value::Uint32(123456)];
        assert_eq!(
            service.agent(":1.9", "RequestConfirmation", &args, 1),
            Reply::Error(BusError::new(REJECTED, "only BlueZ asks this"))
        );
        // From BlueZ, outside the window: turned down at once.
        assert_eq!(
            service.agent(":1.5", "RequestConfirmation", &args, 2),
            Reply::Error(BusError::new(REJECTED, "not pairing now"))
        );
        assert_eq!(
            service.agent(":1.5", "RequestAuthorization", &args[..1], 3),
            Reply::Error(BusError::new(REJECTED, "a pairing needs a code to compare"))
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
