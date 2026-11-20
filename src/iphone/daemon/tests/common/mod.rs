//! A fake BlueZ, with a fake iPhone behind it, and a fake notification server,
//! on a private bus; and what a scenario needs to drive nova-iphone-notifications
//! through them. The service is the real program, started once the fake's names
//! are on the bus. Every thing it does to the fake is a line of the transcript,
//! and each check says "ok" or "FAIL" there.
//!
//! The iPhone speaks ANCS as Apple's specification has it: the service's
//! commands are checked byte for byte, and the answers go out in 20-byte
//! fragments, as over a link with the smallest MTU.

#![allow(dead_code)]

pub mod json;

use std::cell::{Ref, RefCell, RefMut};
use std::collections::{BTreeMap, VecDeque};
use std::ffi::{c_char, c_int, c_long};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::rc::{Rc, Weak};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use nova_sd::poll::{poll, PollFd};
use nova_sd::testing::{scratch, PrivateBus};
use nova_sd::{Bus, Deferred, Error, Handler, Interface, Message, Slot, Value};

pub use json::Json;

pub const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
pub const OBJECT_MANAGER: &str = "org.freedesktop.DBus.ObjectManager";
pub const ADAPTER: &str = "org.bluez.Adapter1";
pub const DEVICE: &str = "org.bluez.Device1";
pub const LE_BEARER: &str = "org.bluez.Bearer.LE1";
pub const GATT_SERVICE: &str = "org.bluez.GattService1";
pub const GATT_CHARACTERISTIC: &str = "org.bluez.GattCharacteristic1";
pub const ADVERTISING_MANAGER: &str = "org.bluez.LEAdvertisingManager1";
pub const ADVERTISEMENT: &str = "org.bluez.LEAdvertisement1";
pub const AGENT_MANAGER: &str = "org.bluez.AgentManager1";
pub const AGENT: &str = "org.bluez.Agent1";
pub const NOTIFICATIONS: &str = "org.freedesktop.Notifications";
pub const NOTIFICATIONS_PATH: &str = "/org/freedesktop/Notifications";
pub const NAME: &str = "org.nova.iPhoneNotifications";
pub const NAME_PATH: &str = "/org/nova/iPhoneNotifications";
pub const ANCS: &str = "7905f431-b5ce-4e99-a40f-4b1e122d00d0";
pub const NS: &str = "9fbf120d-6301-42d9-8c58-25e699a21dbd";
pub const CP: &str = "69d1d8f3-45e1-49a8-9821-9bbdfdaad9d9";
pub const DS: &str = "22eac6e9-24d6-4bb5-be44-b36ace7c7bfb";
pub const ADAPTER_PATH: &str = "/org/bluez/hci0";
pub const PHONE: &str = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01";
pub const STRANGER: &str = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_02";

pub type Shared = Rc<RefCell<Fake>>;
pub type Props = BTreeMap<String, Value>;

fn flag(value: bool) -> Value {
    Value::Bool(value)
}

fn text(value: &str) -> Value {
    Value::str(value)
}

fn bytes(data: &[u8]) -> Value {
    Value::Array("y".into(), data.iter().map(|b| Value::Byte(*b)).collect())
}

fn props(entries: Vec<(&str, Value)>) -> Props {
    entries.into_iter().map(|(k, v)| (k.into(), v)).collect()
}

fn props_value(properties: &Props) -> Value {
    Value::options(
        properties
            .iter()
            .map(|(k, v)| (k.as_str(), v.clone()))
            .collect(),
    )
}

fn interfaces_value(interfaces: &BTreeMap<String, Props>) -> Value {
    Value::Dict(
        "s".into(),
        "a{sv}".into(),
        interfaces
            .iter()
            .map(|(name, properties)| (Value::str(name), props_value(properties)))
            .collect(),
    )
}

/// The hex of some bytes with a space between, as the tests have always
/// written a command.
pub fn hex(data: &[u8]) -> String {
    data.iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}

#[repr(C)]
struct Tm {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: *const c_char,
}

extern "C" {
    fn time(at: *mut i64) -> i64;
    fn localtime_r(at: *const i64, out: *mut Tm) -> *mut Tm;
    fn strftime(out: *mut c_char, max: usize, format: *const c_char, tm: *const Tm) -> usize;
    fn kill(pid: c_int, signal: c_int) -> c_int;
}

/// Now, as an iPhone writes a notification's date: local time, 20240101T120000.
fn ancs_now() -> Vec<u8> {
    let mut tm = Tm {
        sec: 0,
        min: 0,
        hour: 0,
        mday: 0,
        mon: 0,
        year: 0,
        wday: 0,
        yday: 0,
        isdst: 0,
        gmtoff: 0,
        zone: std::ptr::null(),
    };
    let mut out = [0 as c_char; 32];
    // SAFETY: valid pointers throughout: a time_t, a struct tm laid out as
    // glibc's, and a buffer of the size said.
    let length = unsafe {
        let now = time(std::ptr::null_mut());
        localtime_r(&now, &mut tm);
        strftime(out.as_mut_ptr(), out.len(), c"%Y%m%dT%H%M%S".as_ptr(), &tm)
    };
    out[..length].iter().map(|c| *c as u8).collect()
}

/// A notification the fake shell server was asked to show.
#[derive(Debug, Clone)]
pub struct Note {
    pub id: u32,
    pub app: String,
    pub replaces: u32,
    pub summary: String,
    pub body: String,
    pub actions: Vec<String>,
    pub glyph: String,
    pub urgency: u64,
    pub quiet: bool,
    pub buttons: Vec<Json>,
}

impl Note {
    pub fn json(&self) -> Json {
        Json::obj(vec![
            (
                "actions",
                Json::Arr(self.actions.iter().map(|a| Json::str(a)).collect()),
            ),
            ("app", Json::str(&self.app)),
            ("body", Json::str(&self.body)),
            ("buttons", Json::Arr(self.buttons.clone())),
            ("glyph", Json::str(&self.glyph)),
            ("id", Json::num(self.id)),
            ("quiet", Json::Bool(self.quiet)),
            ("replaces", Json::num(self.replaces)),
            ("summary", Json::str(&self.summary)),
            ("urgency", Json::num(self.urgency as f64)),
        ])
    }

    /// Each button's command line.
    pub fn argvs(&self) -> Vec<Vec<String>> {
        self.buttons
            .iter()
            .map(|b| {
                b.get("argv")
                    .map(|a| {
                        a.as_list()
                            .iter()
                            .filter_map(|s| s.as_str().map(str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default()
            })
            .collect()
    }

    /// Whether button <at> is the main one.
    pub fn main_button(&self, at: usize) -> bool {
        self.buttons
            .get(at)
            .and_then(|b| b.get("main"))
            .and_then(Json::as_bool)
            == Some(true)
    }
}

/// One of BlueZ's objects.
struct Node {
    interfaces: BTreeMap<String, Props>,
    slot: Option<Slot>,
}

type Then = Box<dyn FnOnce(&mut Fake, bool)>;
type Job = Box<dyn FnOnce(&mut Fake)>;

pub struct Fake {
    me: Weak<RefCell<Fake>>,
    pub bus: Bus,
    extra: Vec<Bus>,
    nodes: BTreeMap<String, Node>,
    root: Option<Slot>,
    server: Option<Slot>,
    pub adverts: Vec<Json>,
    /// Who registered the advertisement now, its path, and its properties.
    pub advertising: Option<(String, String, Json)>,
    /// Registrations left unanswered, for a reply that comes late.
    pub hold: bool,
    pub held: Vec<Option<Deferred>>,
    /// The agent registered: its sender and path.
    pub agent: Option<(String, String)>,
    pub registrations: u32,
    pub fail_default: bool,
    /// Each pairing a device began, and how it ended.
    pub pairings: Vec<(String, String)>,
    pub env: Vec<(String, String)>,
    pub notes: Vec<Note>,
    pub closed: Vec<u32>,
    pub hold_notify: bool,
    pub held_notes: Vec<(Deferred, u32)>,
    /// Each command written, as hex.
    pub writes: Vec<String>,
    pub subscriptions: Vec<&'static str>,
    pub notifications: BTreeMap<u32, BTreeMap<u8, Vec<u8>>>,
    pub apps: BTreeMap<Vec<u8>, Vec<u8>>,
    next_note: u32,
    idle: VecDeque<Job>,
    pub scratch: PathBuf,
    pub transcript: Vec<String>,
    pub failures: Vec<String>,
    daemon_binary: &'static str,
    unit: PathBuf,
}

impl Fake {
    pub fn say(&mut self, line: impl Into<String>) {
        let line = line.into();
        println!("{line}");
        self.transcript.push(line);
    }

    pub fn check(&mut self, ok: bool, what: &str) {
        self.say(format!("{}{what}", if ok { "ok   " } else { "FAIL " }));
        if !ok {
            self.failures.push(what.to_owned());
        }
    }

    fn shared(&self) -> Shared {
        self.me.upgrade().expect("the fake is alive")
    }

    // -- BlueZ's objects

    fn interface_for(name: &str, properties: &Props) -> Interface {
        let mut interface = Interface::new(name);
        match name {
            ADVERTISING_MANAGER => {
                interface = interface
                    .method("RegisterAdvertisement", "oa{sv}", "")
                    .method("UnregisterAdvertisement", "o", "");
            }
            AGENT_MANAGER => {
                interface = interface
                    .method("RegisterAgent", "os", "")
                    .method("RequestDefaultAgent", "o", "")
                    .method("UnregisterAgent", "o", "");
            }
            GATT_CHARACTERISTIC => {
                interface =
                    interface
                        .method("StartNotify", "", "")
                        .method("WriteValue", "aya{sv}", "");
            }
            _ => {}
        }
        for (property, value) in properties {
            interface = interface.property(property, &value.signature());
        }
        interface
    }

    pub fn add(&mut self, path: &str, interfaces: BTreeMap<String, Props>) {
        let declared = interfaces
            .iter()
            .map(|(name, properties)| Fake::interface_for(name, properties))
            .collect();
        let slot = self
            .bus
            .export(
                path,
                declared,
                NodeHandler {
                    fake: self.me.clone(),
                    path: path.to_owned(),
                },
            )
            .expect("an object on the bus");
        self.bus
            .emit_signal(
                "/",
                OBJECT_MANAGER,
                "InterfacesAdded",
                &[Value::path(path), interfaces_value(&interfaces)],
            )
            .expect("InterfacesAdded");
        self.nodes.insert(
            path.to_owned(),
            Node {
                interfaces,
                slot: Some(slot),
            },
        );
    }

    pub fn remove(&mut self, path: &str) {
        let node = self.nodes.remove(path).expect("a node to remove");
        let names: Vec<&String> = node.interfaces.keys().collect();
        self.bus
            .emit_signal(
                "/",
                OBJECT_MANAGER,
                "InterfacesRemoved",
                &[Value::path(path), Value::strings(&names)],
            )
            .expect("InterfacesRemoved");
    }

    pub fn update(&mut self, path: &str, interface: &str, changes: Vec<(&str, Value)>) {
        let node = self.nodes.get_mut(path).expect("a node to update");
        let properties = node.interfaces.get_mut(interface).expect("an interface");
        for (name, value) in &changes {
            properties.insert((*name).into(), value.clone());
        }
        self.bus
            .emit_properties_changed(path, interface, changes)
            .expect("PropertiesChanged");
    }

    pub fn property(&self, path: &str, interface: &str, name: &str) -> Option<Value> {
        self.nodes
            .get(path)?
            .interfaces
            .get(interface)?
            .get(name)
            .cloned()
    }

    /// A node's interfaces and their properties, to put it back as it was.
    pub fn node_interfaces(&self, path: &str) -> BTreeMap<String, Props> {
        self.nodes[path].interfaces.clone()
    }

    fn managed_objects(&self) -> Value {
        Value::Dict(
            "o".into(),
            "a{sa{sv}}".into(),
            self.nodes
                .iter()
                .map(|(path, node)| (Value::path(path), interfaces_value(&node.interfaces)))
                .collect(),
        )
    }

    // -- the iPhone

    pub fn add_phone(&mut self, paired: bool, connected: bool) {
        let uuids: &[&str] = if paired { &[ANCS] } else { &[] };
        self.add(
            PHONE,
            BTreeMap::from([
                (
                    DEVICE.to_owned(),
                    props(vec![
                        ("Address", text("AA:BB:CC:DD:EE:01")),
                        ("Alias", text("Test iPhone")),
                        ("Paired", flag(paired)),
                        ("Bonded", flag(paired)),
                        ("Trusted", flag(false)),
                        ("Connected", flag(connected)),
                        ("UUIDs", Value::strings(uuids)),
                    ]),
                ),
                (
                    LE_BEARER.to_owned(),
                    props(vec![
                        ("Connected", flag(connected)),
                        ("Paired", flag(paired)),
                        ("Bonded", flag(paired)),
                        ("Interval", Value::Uint32(30000)),
                        ("Latency", Value::Uint16(0)),
                        ("SupervisionTimeout", Value::Uint16(720)),
                    ]),
                ),
            ]),
        );
        let service = format!("{PHONE}/service0010");
        self.add(
            &service,
            BTreeMap::from([(
                GATT_SERVICE.to_owned(),
                props(vec![
                    ("UUID", text(ANCS)),
                    ("Primary", flag(true)),
                    ("Device", Value::path(PHONE)),
                ]),
            )]),
        );
        for (number, uuid, flags) in [
            ("0011", NS, "notify"),
            ("0014", CP, "write"),
            ("0017", DS, "notify"),
        ] {
            self.add(
                &format!("{service}/char{number}"),
                BTreeMap::from([(
                    GATT_CHARACTERISTIC.to_owned(),
                    props(vec![
                        ("UUID", text(uuid)),
                        ("Service", Value::path(&service)),
                        ("Notifying", flag(false)),
                        ("Flags", Value::strings(&[flags])),
                        ("Value", bytes(b"")),
                    ]),
                )]),
            );
        }
    }

    pub fn char_path(uuid: &str) -> String {
        let number = match uuid {
            NS => "0011",
            CP => "0014",
            _ => "0017",
        };
        format!("{PHONE}/service0010/char{number}")
    }

    pub fn connect(&mut self, connected: bool) {
        if !connected {
            for uuid in [NS, DS] {
                self.update(
                    &Fake::char_path(uuid),
                    GATT_CHARACTERISTIC,
                    vec![("Notifying", flag(false))],
                );
            }
        }
        self.update(PHONE, LE_BEARER, vec![("Connected", flag(connected))]);
        self.update(PHONE, DEVICE, vec![("Connected", flag(connected))]);
    }

    /// A Notification Source event: what happened, its flags and category, and the uid.
    pub fn event(&mut self, kind: u8, flags: u8, category: u8, uid: u32) {
        let mut data = vec![kind, flags, category, 1];
        data.extend_from_slice(&uid.to_le_bytes());
        self.update(
            &Fake::char_path(NS),
            GATT_CHARACTERISTIC,
            vec![("Value", bytes(&data))],
        );
    }

    /// The iPhone's notification <uid>, as its Data Source will tell of it.
    pub fn note(&mut self, uid: u32, app: &[u8], title: &[u8], message: &[u8]) {
        self.note_with(uid, app, title, message, b"", None);
    }

    /// The same, with a subtitle, and a date other than now.
    pub fn note_with(
        &mut self,
        uid: u32,
        app: &[u8],
        title: &[u8],
        message: &[u8],
        subtitle: &[u8],
        date: Option<&[u8]>,
    ) {
        self.notifications.insert(
            uid,
            BTreeMap::from([
                (0, app.to_vec()),
                (1, title.to_vec()),
                (2, subtitle.to_vec()),
                (3, message.to_vec()),
                (5, date.map_or_else(ancs_now, <[u8]>::to_vec)),
            ]),
        );
    }

    /// A device that is not an iPhone Nova knows: not paired, no services,
    /// under a name of its own choosing.
    pub fn add_stranger(&mut self, alias: &str) {
        self.add(
            STRANGER,
            BTreeMap::from([(
                DEVICE.to_owned(),
                props(vec![
                    ("Address", text("AA:BB:CC:DD:EE:02")),
                    ("Alias", text(alias)),
                    ("Paired", flag(false)),
                    ("Bonded", flag(false)),
                    ("Trusted", flag(false)),
                    ("Connected", flag(true)),
                    ("UUIDs", Value::strings::<&str>(&[])),
                ]),
            )]),
        );
    }

    fn start_notify(&mut self, path: &str, answer: Deferred) {
        let uuid = self
            .property(path, GATT_CHARACTERISTIC, "UUID")
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        let role = if uuid == NS { "ns" } else { "ds" };
        self.subscriptions.push(role);
        self.say(format!("subscribe: {role}"));
        let paired = self
            .property(PHONE, DEVICE, "Paired")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let path = path.to_owned();
        if paired {
            self.update(&path, GATT_CHARACTERISTIC, vec![("Notifying", flag(true))]);
            let _ = answer.reply(Ok(vec![]));
            return;
        }
        // Not paired: the iPhone answers Insufficient Authentication, and
        // pairs, BlueZ asking an agent.
        self.pair(
            PHONE,
            "confirm",
            Some(Box::new(move |fake, agreed| {
                if agreed {
                    fake.update(
                        PHONE,
                        DEVICE,
                        vec![
                            ("Paired", flag(true)),
                            ("Bonded", flag(true)),
                            ("UUIDs", Value::strings(&[ANCS])),
                        ],
                    );
                    fake.update(&path, GATT_CHARACTERISTIC, vec![("Notifying", flag(true))]);
                    let _ = answer.reply(Ok(vec![]));
                } else {
                    let _ = answer.reply(Err(Error::bus("org.bluez.Error.Failed", "Not paired")));
                }
            })),
        );
    }

    /// A pairing <device> begins, as BlueZ answers it: with no agent
    /// registered BlueZ clears the controller's bondable setting (unless
    /// main.conf's AlwaysPairable, which Nova leaves off), and the kernel
    /// turns the pairing down; with one, a code to compare is asked with
    /// RequestConfirmation, and a pairing with none (Just Works) with
    /// RequestAuthorization.
    pub fn pair(&mut self, device: &str, how: &str, then: Option<Then>) {
        let Some((sender, path)) = self.agent.clone() else {
            self.ended(device, "refused, not bondable: no agent".into(), then);
            return;
        };
        let (method, args) = if how == "confirm" {
            (
                "RequestConfirmation",
                vec![Value::path(device), Value::Uint32(123456)],
            )
        } else {
            ("RequestAuthorization", vec![Value::path(device)])
        };
        let shared = self.shared();
        let device = device.to_owned();
        self.bus
            .call_async(
                &sender,
                &path,
                AGENT,
                method,
                &args,
                Some(Duration::from_secs(30)),
                move |result| {
                    let result = match result {
                        Ok(_) => "agreed".to_owned(),
                        Err(error) => format!("refused, {}", error.name().unwrap_or("")),
                    };
                    shared.borrow_mut().ended(&device, result, then);
                },
            )
            .expect("a call to the agent");
    }

    fn ended(&mut self, device: &str, result: String, then: Option<Then>) {
        self.say(format!("pairing: {result}"));
        let agreed = result == "agreed";
        self.pairings.push((device.to_owned(), result));
        if let Some(then) = then {
            then(self, agreed);
        }
    }

    fn write(&mut self, value: &[u8], options: &Value) -> nova_sd::Result<Vec<Value>> {
        self.writes.push(hex(value));
        let kind = options.get("type").and_then(Value::as_str).unwrap_or("");
        self.say(format!("write: {} {kind}", hex(value)));
        let answer = match value.first() {
            Some(0) => {
                let uid = u32::from_le_bytes(value[1..5].try_into().expect("a uid"));
                let Some(attributes) = self.notifications.get(&uid) else {
                    return Err(Error::bus(
                        "org.bluez.Error.Failed",
                        "Operation failed with ATT error: 0xa2",
                    ));
                };
                let mut answer = value[..5].to_vec();
                let mut at = 5;
                while at < value.len() {
                    let id = value[at];
                    at += if matches!(id, 1..=3) { 3 } else { 1 };
                    let data = &attributes[&id];
                    answer.push(id);
                    answer.extend_from_slice(&(data.len() as u16).to_le_bytes());
                    answer.extend_from_slice(data);
                }
                answer
            }
            Some(1) => {
                let end = value[1..]
                    .iter()
                    .position(|b| *b == 0)
                    .expect("an app identifier")
                    + 1;
                let name = self.apps.get(&value[1..end]).cloned().unwrap_or_default();
                let mut answer = value[..value.len() - 1].to_vec();
                answer.push(0);
                answer.extend_from_slice(&(name.len() as u16).to_le_bytes());
                answer.extend_from_slice(&name);
                answer
            }
            _ => return Ok(vec![]),
        };
        // The answer follows the write's response, in 20-byte notifications.
        self.idle.push_back(Box::new(move |fake| {
            for fragment in answer.chunks(20) {
                fake.update(
                    &Fake::char_path(DS),
                    GATT_CHARACTERISTIC,
                    vec![("Value", bytes(fragment))],
                );
            }
        }));
        Ok(vec![])
    }

    // -- advertising

    fn register(&mut self, sender: &str, path: &str, answer: Deferred) {
        if self.hold {
            self.held.push(Some(answer));
            self.say("advertise: held, unanswered");
            return;
        }
        let shared = self.shared();
        let (sender_copy, path_copy) = (sender.to_owned(), path.to_owned());
        let sent = self.bus.call_async(
            sender,
            path,
            PROPERTIES,
            "GetAll",
            &[Value::str(ADVERTISEMENT)],
            Some(Duration::from_secs(10)),
            move |result| match result {
                Ok(values) => {
                    let mut advert = BTreeMap::new();
                    for (key, value) in values.first().and_then(Value::as_dict).unwrap_or_default()
                    {
                        let json = match value.unvariant() {
                            Value::Array(_, items) => Json::Arr(
                                items
                                    .iter()
                                    .filter_map(|i| i.as_str().map(Json::str))
                                    .collect(),
                            ),
                            Value::Bool(b) => Json::Bool(*b),
                            Value::Str(s) => Json::str(s),
                            other => Json::Num(other.as_i64().unwrap_or(0) as f64),
                        };
                        advert.insert(key.as_str().unwrap_or("").to_owned(), json);
                    }
                    let advert = Json::Obj(advert);
                    let mut fake = shared.borrow_mut();
                    fake.adverts.push(advert.clone());
                    fake.say(format!("advertise: {advert}"));
                    fake.advertising = Some((sender_copy, path_copy, advert));
                    let _ = answer.reply(Ok(vec![]));
                }
                Err(error) => {
                    let _ = answer.reply(Err(error));
                }
            },
        );
        sent.expect("a call for the advertisement");
    }

    fn unregister(&mut self) {
        self.advertising = None;
        self.say("advertise: stopped");
    }

    /// BlueZ lets the advertisement go.
    pub fn release(&mut self) {
        let (sender, path, _) = self
            .advertising
            .take()
            .expect("an advertisement to release");
        self.say("advertise: released by BlueZ");
        let _ = self
            .bus
            .call_async(&sender, &path, ADVERTISEMENT, "Release", &[], None, |_| {});
    }

    // -- the service and its state

    pub fn state(&self) -> Json {
        std::fs::read_to_string(self.scratch.join("run/nova/iphone-notifications.json"))
            .ok()
            .and_then(|text| Json::parse(&text))
            .unwrap_or(Json::Obj(BTreeMap::new()))
    }

    /// The state's text under <key>, or an empty one.
    pub fn state_of(&self, key: &str) -> String {
        self.state()
            .get(key)
            .and_then(Json::as_str)
            .unwrap_or("")
            .to_owned()
    }

    pub fn call_daemon(&mut self, method: &str, args: Vec<Value>) {
        let shared = self.shared();
        self.bus
            .call_async(NAME, NAME_PATH, NAME, method, &args, None, move |result| {
                if let Err(error) = result {
                    shared
                        .borrow_mut()
                        .say(format!("daemon call failed: {error}"));
                }
            })
            .expect("a call to the service");
    }

    /// The shell's server tells the service a toast is closed.
    pub fn close_note(&mut self, note: u32, reason: u32) {
        self.say(format!("closed by the shell: {note} {reason}"));
        self.bus
            .emit_signal(
                NOTIFICATIONS_PATH,
                NOTIFICATIONS,
                "NotificationClosed",
                &[Value::Uint32(note), Value::Uint32(reason)],
            )
            .expect("NotificationClosed");
    }

    pub fn note_for(&self, summary: &str) -> Option<Note> {
        self.notes.iter().find(|n| n.summary == summary).cloned()
    }

    /// The notes that are a question to answer.
    pub fn questions(&self) -> Vec<Note> {
        self.notes
            .iter()
            .filter(|n| !n.buttons.is_empty())
            .cloned()
            .collect()
    }

    pub fn release_bluez(&mut self) {
        self.bus
            .release_name("org.bluez")
            .expect("giving up org.bluez");
    }

    pub fn own_bluez(&mut self) {
        self.bus
            .request_name("org.bluez", 0)
            .expect("taking org.bluez");
    }

    /// The transcript's lines as one text.
    pub fn said(&self) -> String {
        self.transcript.join("\n")
    }

    /// Whether the transcript holds each of <parts>, one after the other.
    pub fn said_in_order(&self, parts: &[&str]) -> bool {
        let said = self.said();
        let mut rest = said.as_str();
        for part in parts {
            match rest.find(part) {
                Some(at) => rest = &rest[at + part.len()..],
                None => return false,
            }
        }
        true
    }
}

/// What answers calls to one of BlueZ's objects.
struct NodeHandler {
    fake: Weak<RefCell<Fake>>,
    path: String,
}

impl Handler for NodeHandler {
    fn call(&mut self, call: &Message, args: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
        let shared = self.fake.upgrade().expect("the fake is alive");
        let sender = call.sender().unwrap_or("").to_owned();
        match (call.interface().unwrap_or(""), call.member().unwrap_or("")) {
            (ADVERTISING_MANAGER, "RegisterAdvertisement") => {
                let answer = call.defer()?;
                let path = args
                    .first()
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                shared.borrow_mut().register(&sender, &path, answer);
                Ok(vec![])
            }
            (ADVERTISING_MANAGER, "UnregisterAdvertisement") => {
                shared.borrow_mut().unregister();
                Ok(vec![])
            }
            // As BlueZ has it, an agent registered is one pairing may ask
            // (the default, or after it), whether or not it was made the
            // default.
            (AGENT_MANAGER, "RegisterAgent") => {
                let mut fake = shared.borrow_mut();
                let path = args
                    .first()
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                fake.agent = Some((sender, path));
                fake.registrations += 1;
                let capability = args.get(1).and_then(Value::as_str).unwrap_or("");
                fake.say(format!("agent registered: {capability}"));
                Ok(vec![])
            }
            (AGENT_MANAGER, "RequestDefaultAgent") => {
                let mut fake = shared.borrow_mut();
                if fake.fail_default {
                    fake.say("agent not made the default");
                    return Err(Error::bus("org.bluez.Error.DoesNotExist", "Does Not Exist"));
                }
                fake.say("agent made the default");
                Ok(vec![])
            }
            (AGENT_MANAGER, "UnregisterAgent") => {
                let mut fake = shared.borrow_mut();
                fake.agent = None;
                fake.say("agent unregistered");
                Ok(vec![])
            }
            (GATT_CHARACTERISTIC, "StartNotify") => {
                let answer = call.defer()?;
                shared.borrow_mut().start_notify(&self.path, answer);
                Ok(vec![])
            }
            (GATT_CHARACTERISTIC, "WriteValue") => {
                let data = args.first().and_then(Value::as_bytes).unwrap_or_default();
                let options = args
                    .get(1)
                    .cloned()
                    .unwrap_or(Value::options::<&str>(vec![]));
                let result = shared.borrow_mut().write(&data, &options);
                result
            }
            _ => Err(Error::bus(
                nova_sd::ERROR_FAILED,
                "not something the fake does",
            )),
        }
    }

    fn get(&mut self, interface: &str, property: &str) -> Option<Value> {
        self.fake
            .upgrade()?
            .borrow()
            .property(&self.path, interface, property)
    }
}

/// The object manager at the root, as BlueZ has it.
struct Root(Weak<RefCell<Fake>>);

impl Handler for Root {
    fn call(&mut self, _: &Message, _: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
        let shared = self.0.upgrade().expect("the fake is alive");
        let objects = shared.borrow().managed_objects();
        Ok(vec![objects])
    }
}

/// The shell's notification server, as far as the service sees it.
struct Server(Weak<RefCell<Fake>>);

impl Handler for Server {
    fn call(&mut self, call: &Message, args: Vec<Value>) -> nova_sd::Result<Vec<Value>> {
        let shared = self.0.upgrade().expect("the fake is alive");
        match call.member().unwrap_or("") {
            // A new id each time, as for a replacement of one closed already.
            // With the fake's hold_notify, the reply waits in held_notes.
            "Notify" => {
                let hints = &args[6];
                let hint = |name: &str| hints.get(name);
                let note_id;
                {
                    let mut fake = shared.borrow_mut();
                    fake.next_note += 1;
                    note_id = fake.next_note;
                    let glyph = hint("nova-glyph").and_then(Value::as_str).unwrap_or(" ");
                    let note = Note {
                        id: note_id,
                        app: args[0].as_str().unwrap_or("").into(),
                        replaces: args[1].as_u64().unwrap_or(0) as u32,
                        summary: args[3].as_str().unwrap_or("").into(),
                        body: args[4].as_str().unwrap_or("").into(),
                        actions: args[5]
                            .as_list()
                            .unwrap_or_default()
                            .iter()
                            .filter_map(|a| a.as_str().map(str::to_owned))
                            .collect(),
                        glyph: format!("U+{:X}", glyph.chars().next().map_or(0x20, |c| c as u32)),
                        urgency: hint("urgency").and_then(Value::as_u64).unwrap_or(1),
                        quiet: hint("nova-quiet").and_then(Value::as_bool).unwrap_or(false),
                        buttons: Json::parse(
                            hint("nova-buttons").and_then(Value::as_str).unwrap_or("[]"),
                        )
                        .map(|j| j.as_list().to_vec())
                        .unwrap_or_default(),
                    };
                    fake.say(format!("notify: {}", note.json()));
                    fake.notes.push(note);
                    if fake.hold_notify {
                        let answer = call.defer()?;
                        fake.held_notes.push((answer, note_id));
                        return Ok(vec![]);
                    }
                }
                Ok(vec![Value::Uint32(note_id)])
            }
            "CloseNotification" => {
                let note = args[0].as_u64().unwrap_or(0) as u32;
                let mut fake = shared.borrow_mut();
                fake.closed.push(note);
                fake.say(format!("close: {note}"));
                fake.bus
                    .emit_signal(
                        NOTIFICATIONS_PATH,
                        NOTIFICATIONS,
                        "NotificationClosed",
                        &[Value::Uint32(note), Value::Uint32(3)],
                    )
                    .map(|_| vec![])
            }
            "GetCapabilities" => Ok(vec![Value::strings(&["body", "actions"])]),
            _ => Err(Error::bus(
                nova_sd::ERROR_FAILED,
                "not something the fake does",
            )),
        }
    }
}

/// A scenario's handle on the fake and the service it drives: straight-line
/// code that waits on the bus where the service has to answer.
pub struct Sim {
    fake: Shared,
    daemon: Option<Child>,
    lines: mpsc::Receiver<String>,
    started: Instant,
    env: Vec<(String, String)>,
    binary: &'static str,
    bus: PrivateBus,
}

impl Sim {
    /// The fake, its bus and the service running on them; none where there
    /// is no dbus-daemon to make a bus with, for the test to skip.
    pub fn start(binary: &'static str, unit: &str, extra_env: &[(&str, &str)]) -> Option<Sim> {
        let bus = PrivateBus::start()?;
        let dir = scratch("iphone");
        let client = Bus::connect(&bus.address).expect("a connection to the private bus");
        let fake = Rc::new_cyclic(|me| {
            RefCell::new(Fake {
                me: me.clone(),
                bus: client.clone(),
                extra: Vec::new(),
                nodes: BTreeMap::new(),
                root: None,
                server: None,
                adverts: Vec::new(),
                advertising: None,
                hold: false,
                held: Vec::new(),
                agent: None,
                registrations: 0,
                fail_default: false,
                pairings: Vec::new(),
                env: Vec::new(),
                notes: Vec::new(),
                closed: Vec::new(),
                hold_notify: false,
                held_notes: Vec::new(),
                writes: Vec::new(),
                subscriptions: Vec::new(),
                notifications: BTreeMap::new(),
                apps: BTreeMap::from([
                    (b"net.whatsapp.WhatsApp".to_vec(), b"WhatsApp".to_vec()),
                    (b"com.apple.MobileSMS".to_vec(), b"Messages".to_vec()),
                ]),
                next_note: 0,
                idle: VecDeque::new(),
                scratch: dir.clone(),
                transcript: Vec::new(),
                failures: Vec::new(),
                daemon_binary: binary,
                unit: PathBuf::from(unit),
            })
        });
        {
            let mut f = fake.borrow_mut();
            let weak = f.me.clone();
            f.root = Some(
                client
                    .export(
                        "/",
                        vec![Interface::new(OBJECT_MANAGER)
                            .method("GetManagedObjects", "", "a{oa{sa{sv}}}")
                            .signal("InterfacesAdded", "oa{sa{sv}}")
                            .signal("InterfacesRemoved", "oas")],
                        Root(weak.clone()),
                    )
                    .expect("the object manager"),
            );
            f.server = Some(
                client
                    .export(
                        NOTIFICATIONS_PATH,
                        vec![Interface::new(NOTIFICATIONS)
                            .method("Notify", "susssasa{sv}i", "u")
                            .method("CloseNotification", "u", "")
                            .method("GetCapabilities", "", "as")
                            .signal("NotificationClosed", "uu")],
                        Server(weak),
                    )
                    .expect("the notification server"),
            );
            f.add(
                ADAPTER_PATH,
                BTreeMap::from([
                    (
                        ADAPTER.to_owned(),
                        props(vec![
                            ("Address", text("00:11:22:33:44:55")),
                            ("Alias", text("Test Laptop")),
                            ("Powered", flag(true)),
                        ]),
                    ),
                    (
                        ADVERTISING_MANAGER.to_owned(),
                        props(vec![("ActiveInstances", Value::Byte(0))]),
                    ),
                ]),
            );
            f.add(
                "/org/bluez",
                BTreeMap::from([(AGENT_MANAGER.to_owned(), Props::new())]),
            );
        }
        client
            .request_name("org.bluez", 0)
            .expect("taking org.bluez");
        client
            .request_name(NOTIFICATIONS, 0)
            .expect("taking the notification name");
        std::fs::create_dir_all(dir.join("run/nova")).expect("a runtime folder");
        std::fs::write(dir.join("main.conf"), "[General]\n#ControllerMode = dual\n")
            .expect("main.conf");
        // A state file a run before left behind, which this one is not to believe.
        std::fs::write(
            dir.join("run/nova/iphone-notifications.json"),
            "{\"state\": \"stale\"}\n",
        )
        .expect("a stale state file");
        let run = dir.join("run");
        let mut env: Vec<(String, String)> = vec![
            ("DBUS_SESSION_BUS_ADDRESS".into(), bus.address.clone()),
            ("NOVA_IPHONE_BUS".into(), "session".into()),
            ("NOVA_IPHONE_FAST_SECONDS".into(), "1".into()),
            ("NOVA_IPHONE_PAIR_SECONDS".into(), "30".into()),
            ("NOVA_IPHONE_REPLY_SECONDS".into(), "1".into()),
            (
                "NOVA_BLUETOOTH_CONF".into(),
                dir.join("main.conf").display().to_string(),
            ),
            ("XDG_RUNTIME_DIR".into(), run.display().to_string()),
        ];
        for (key, value) in extra_env {
            env.retain(|(k, _)| k != key);
            env.push(((*key).into(), (*value).into()));
        }
        fake.borrow_mut().env = env.clone();
        let (send, lines) = mpsc::channel();
        let mut sim = Sim {
            fake,
            daemon: None,
            lines,
            started: Instant::now(),
            env,
            binary,
            bus,
        };
        sim.daemon = Some(sim.spawn_daemon(send));
        Some(sim)
    }

    fn spawn_daemon(&self, send: mpsc::Sender<String>) -> Child {
        let mut child = Command::new(self.binary)
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("the service to start");
        let out = child.stdout.take().expect("its output");
        let err = child.stderr.take().expect("its errors");
        for stream in [
            Box::new(out) as Box<dyn std::io::Read + Send>,
            Box::new(err),
        ] {
            let send = send.clone();
            thread::spawn(move || {
                for line in BufReader::new(stream).lines().map_while(Result::ok) {
                    if send.send(line).is_err() {
                        break;
                    }
                }
            });
        }
        child
    }

    pub fn s(&self) -> Ref<'_, Fake> {
        self.fake.borrow()
    }

    pub fn m(&self) -> RefMut<'_, Fake> {
        self.fake.borrow_mut()
    }

    pub fn address(&self) -> &str {
        &self.bus.address
    }

    /// The unit file of the service, as its text.
    pub fn unit(&self) -> String {
        std::fs::read_to_string(&self.s().unit).expect("the unit file")
    }

    pub fn binary(&self) -> &'static str {
        self.s().daemon_binary
    }

    /// A second connection to the bus, kept going with the fake's.
    pub fn connect_another(&self) -> Bus {
        let other = Bus::connect(self.address()).expect("another connection");
        self.m().extra.push(other.clone());
        other
    }

    /// Runs the bus for up to <most>: what comes is handled, the fake's own
    /// follow-ups run, and the service's output is added to the transcript.
    pub fn pump(&self, most: Duration) {
        let buses: Vec<Bus> = {
            let fake = self.s();
            std::iter::once(fake.bus.clone())
                .chain(fake.extra.iter().cloned())
                .collect()
        };
        for bus in &buses {
            let _ = bus.flush();
        }
        let mut fds: Vec<PollFd> = buses.iter().map(Bus::poll_fd).collect();
        let timeout = buses
            .iter()
            .filter_map(Bus::timeout)
            .fold(most, Duration::min);
        let _ = poll(&mut fds, Some(timeout));
        for bus in &buses {
            bus.dispatch().expect("the bus");
        }
        loop {
            let job = self.m().idle.pop_front();
            match job {
                Some(job) => job(&mut self.m()),
                None => break,
            }
        }
        for bus in &buses {
            let _ = bus.dispatch();
            let _ = bus.flush();
        }
        while let Ok(line) = self.lines.try_recv() {
            self.m().say(line);
        }
    }

    /// Waits, running the bus, for <seconds>.
    pub fn pause(&self, seconds: f64) {
        let until = Instant::now() + Duration::from_secs_f64(seconds);
        while Instant::now() < until {
            self.pump(Duration::from_millis(20));
        }
    }

    /// Waits until <test> holds, for up to <seconds>: a wait that runs out
    /// fails the run, as does a scenario that takes more than 90 seconds.
    pub fn until_within(&self, seconds: u64, what: &str, test: impl Fn(&Fake) -> bool) {
        let until = Instant::now() + Duration::from_secs(seconds);
        loop {
            if test(&self.s()) {
                return;
            }
            if Instant::now() > until || self.started.elapsed() > Duration::from_secs(90) {
                self.m().check(false, &format!("in time: {what}"));
                panic!("not in time: {what}");
            }
            self.pump(Duration::from_millis(20));
        }
    }

    pub fn until(&self, what: &str, test: impl Fn(&Fake) -> bool) {
        self.until_within(8, what, test);
    }

    pub fn check(&self, ok: bool, what: &str) {
        self.m().check(ok, what);
    }

    /// A check on the fake's state.
    pub fn check_that(&self, what: &str, test: impl Fn(&Fake) -> bool) {
        let ok = test(&self.s());
        self.check(ok, what);
    }

    /// Stops the service as the system does, with SIGTERM, and checks how it
    /// ended; fails the test if any check failed.
    pub fn finish(mut self) {
        let mut daemon = self.daemon.take().expect("the service");
        // SAFETY: the pid of a child of ours, which is still ours until waited for.
        unsafe { kill(daemon.id() as c_int, 15) };
        let until = Instant::now() + Duration::from_secs(5);
        let status = loop {
            if let Some(status) = daemon.try_wait().expect("waiting for the service") {
                break status
                    .code()
                    .map_or("a signal".to_owned(), |c| c.to_string());
            }
            if Instant::now() > until {
                let _ = daemon.kill();
                let _ = daemon.wait();
                break "killed".to_owned();
            }
            self.pump(Duration::from_millis(20));
        };
        self.pump(Duration::from_millis(50));
        self.check(
            status == "0",
            &format!("the service stops cleanly on SIGTERM ({status})"),
        );
        let state = self.s().scratch.join("run/nova/iphone-notifications.json");
        self.check(!state.exists(), "and takes its state file with it");
        self.m().say("DONE");
        let failures = self.s().failures.clone();
        assert!(failures.is_empty(), "failed: {failures:?}");
    }
}

impl Drop for Sim {
    fn drop(&mut self) {
        if let Some(mut daemon) = self.daemon.take() {
            let _ = daemon.kill();
            let _ = daemon.wait();
        }
        // The fake's objects hold it, and it holds them: let them go.
        if let Ok(mut fake) = self.fake.try_borrow_mut() {
            for node in fake.nodes.values_mut() {
                node.slot = None;
            }
            fake.root = None;
            fake.server = None;
            fake.extra.clear();
        }
        let _ = std::fs::remove_dir_all(
            self.fake
                .try_borrow()
                .map(|f| f.scratch.clone())
                .unwrap_or_default(),
        );
    }
}

/// The time now, as the state file's pairingUntil is: seconds since the epoch.
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}
