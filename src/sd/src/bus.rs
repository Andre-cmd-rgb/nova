//! A D-Bus connection, through sd-bus.
//!
//! A `Bus` belongs to the thread that opened it, as sd-bus's connections do:
//! the type is neither Send nor Sync. Its callbacks (a signal's match, an
//! exported object) run inside `dispatch`, on that thread, and may call out
//! on the bus themselves through `Message::bus`: sd-bus waits for a call's
//! reply without running other callbacks meanwhile.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::marker::PhantomData;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::ptr;
use std::sync::Arc;
use std::time::Duration;

use crate::error::{check, Error, Result};
use crate::ffi::{self, sd_bus, sd_bus_error, sd_bus_message, sd_bus_slot};
use crate::poll::{self, PollFd, POLLIN};
use crate::value::{split_signature, Value};

/// sd_bus_request_name's flags.
pub const NAME_REPLACE_EXISTING: u64 = 1;
pub const NAME_ALLOW_REPLACEMENT: u64 = 2;
pub const NAME_QUEUE: u64 = 4;

pub const ERROR_FAILED: &str = "org.freedesktop.DBus.Error.Failed";
pub const ERROR_INVALID_ARGS: &str = "org.freedesktop.DBus.Error.InvalidArgs";
pub const ERROR_UNKNOWN_PROPERTY: &str = "org.freedesktop.DBus.Error.UnknownProperty";
pub const ERROR_UNKNOWN_INTERFACE: &str = "org.freedesktop.DBus.Error.UnknownInterface";
pub const ERROR_PROPERTY_READ_ONLY: &str = "org.freedesktop.DBus.Error.PropertyReadOnly";
pub const ERROR_NAME_HAS_NO_OWNER: &str = "org.freedesktop.DBus.Error.NameHasNoOwner";

const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
const INTROSPECTABLE: &str = "org.freedesktop.DBus.Introspectable";

fn c(text: &str, what: &'static str) -> Result<CString> {
    CString::new(text).map_err(|_| Error::Os {
        errno: 22,
        doing: what,
    })
}

/// A connection to a bus.
pub struct Bus {
    raw: *mut sd_bus,
}

impl Clone for Bus {
    fn clone(&self) -> Bus {
        // SAFETY: a live bus, whose count of references this raises.
        Bus {
            raw: unsafe { ffi::sd_bus_ref(self.raw) },
        }
    }
}

impl Drop for Bus {
    fn drop(&mut self) {
        // SAFETY: one reference of ours, given back once. The connection
        // closes with its last, which matches and objects hold too.
        unsafe { ffi::sd_bus_unref(self.raw) };
    }
}

impl Bus {
    fn opened(
        open: unsafe extern "C" fn(*mut *mut sd_bus) -> c_int,
        doing: &'static str,
    ) -> Result<Bus> {
        let mut raw = ptr::null_mut();
        // SAFETY: a valid pointer for the new connection.
        check(unsafe { open(&mut raw) }, doing)?;
        Ok(Bus { raw })
    }

    /// The user's session bus ($DBUS_SESSION_BUS_ADDRESS, or the one in
    /// $XDG_RUNTIME_DIR).
    pub fn user() -> Result<Bus> {
        Bus::opened(ffi::sd_bus_open_user, "connecting to the session bus")
    }

    /// The system bus ($DBUS_SYSTEM_BUS_ADDRESS, or the usual one).
    pub fn system() -> Result<Bus> {
        Bus::opened(ffi::sd_bus_open_system, "connecting to the system bus")
    }

    /// The bus at <address> (unix:path=…), as a client: a private bus, for tests.
    pub fn connect(address: &str) -> Result<Bus> {
        let address = c(address, "a bus address")?;
        let mut raw = ptr::null_mut();
        // SAFETY: a valid pointer for the new connection.
        check(unsafe { ffi::sd_bus_new(&mut raw) }, "making a connection")?;
        let bus = Bus { raw };
        // SAFETY: a new connection of ours, not started yet, and a NUL-terminated address.
        check(
            unsafe { ffi::sd_bus_set_address(bus.raw, address.as_ptr()) },
            "setting the bus address",
        )?;
        // SAFETY: as above.
        check(
            unsafe { ffi::sd_bus_set_bus_client(bus.raw, 1) },
            "connecting as a client",
        )?;
        // SAFETY: as above.
        check(
            unsafe { ffi::sd_bus_start(bus.raw) },
            "connecting to the bus",
        )?;
        Ok(bus)
    }

    /// This connection's own name on the bus (":1.42").
    pub fn unique_name(&self) -> Result<String> {
        let mut name = ptr::null();
        // SAFETY: a live bus; the name stays the bus's.
        check(
            unsafe { ffi::sd_bus_get_unique_name(self.raw, &mut name) },
            "asking the bus for this connection's name",
        )?;
        // SAFETY: NUL-terminated by sd-bus.
        Ok(unsafe { CStr::from_ptr(name) }
            .to_string_lossy()
            .into_owned())
    }

    /// Whether the connection is still up.
    pub fn is_open(&self) -> bool {
        // SAFETY: a live bus.
        unsafe { ffi::sd_bus_is_open(self.raw) > 0 }
    }

    fn new_call(
        &self,
        destination: &str,
        path: &str,
        interface: &str,
        member: &str,
    ) -> Result<OwnedMessage> {
        let (d, p, i, m) = (
            c(destination, "a destination")?,
            c(path, "an object path")?,
            c(interface, "an interface")?,
            c(member, "a method")?,
        );
        let mut raw = ptr::null_mut();
        // SAFETY: a live bus and NUL-terminated names; an empty interface is none.
        check(
            unsafe {
                ffi::sd_bus_message_new_method_call(
                    self.raw,
                    &mut raw,
                    d.as_ptr(),
                    p.as_ptr(),
                    if interface.is_empty() {
                        ptr::null()
                    } else {
                        i.as_ptr()
                    },
                    m.as_ptr(),
                )
            },
            "making a method call",
        )?;
        Ok(OwnedMessage(raw))
    }

    /// Calls <member> of <interface> on the object at <path> of <destination>,
    /// and waits for its answer, as long as sd-bus waits by default (25 s).
    pub fn call(
        &self,
        destination: &str,
        path: &str,
        interface: &str,
        member: &str,
        args: &[Value],
    ) -> Result<Vec<Value>> {
        self.call_timeout(destination, path, interface, member, args, None)
    }

    /// As `call`, waiting at most <timeout> for the answer.
    pub fn call_timeout(
        &self,
        destination: &str,
        path: &str,
        interface: &str,
        member: &str,
        args: &[Value],
        timeout: Option<Duration>,
    ) -> Result<Vec<Value>> {
        let call = self.new_call(destination, path, interface, member)?;
        call.append_all(args)?;
        let usec = timeout.map_or(0, |t| (t.as_micros() as u64).max(1));
        let mut error = sd_bus_error::NULL;
        let mut reply = ptr::null_mut();
        // SAFETY: a live bus, a sealed-on-send call of ours, and valid out-pointers.
        let r = unsafe { ffi::sd_bus_call(self.raw, call.0, usec, &mut error, &mut reply) };
        if r < 0 {
            return Err(Error::from_bus_error(&mut error, -r, "calling a method"));
        }
        let reply = OwnedMessage(reply);
        Message::borrowed(reply.0).args()
    }

    /// Sends a method call and does not wait for, or want, an answer.
    pub fn call_no_reply(
        &self,
        destination: &str,
        path: &str,
        interface: &str,
        member: &str,
        args: &[Value],
    ) -> Result<()> {
        let call = self.new_call(destination, path, interface, member)?;
        call.append_all(args)?;
        // SAFETY: a call of ours, not sent yet.
        check(
            unsafe { ffi::sd_bus_message_set_expect_reply(call.0, 0) },
            "making a call that wants no answer",
        )?;
        self.send(&call)
    }

    fn send(&self, message: &OwnedMessage) -> Result<()> {
        // SAFETY: a live bus and a message of ours; sd-bus takes its own reference.
        check(
            unsafe { ffi::sd_bus_send(self.raw, message.0, ptr::null_mut()) },
            "sending a message",
        )?;
        Ok(())
    }

    /// A property's value, out of its variant.
    pub fn get_property(
        &self,
        destination: &str,
        path: &str,
        interface: &str,
        name: &str,
    ) -> Result<Value> {
        let answer = self.call(
            destination,
            path,
            PROPERTIES,
            "Get",
            &[Value::str(interface), Value::str(name)],
        )?;
        match answer.into_iter().next() {
            Some(Value::Variant(value)) => Ok(*value),
            _ => Err(Error::bus(
                ERROR_INVALID_ARGS,
                "Get answered without a variant",
            )),
        }
    }

    /// Every property of <interface> on the object, as an a{sv} dictionary.
    pub fn get_all_properties(
        &self,
        destination: &str,
        path: &str,
        interface: &str,
    ) -> Result<Value> {
        let answer = self.call(
            destination,
            path,
            PROPERTIES,
            "GetAll",
            &[Value::str(interface)],
        )?;
        answer
            .into_iter()
            .next()
            .filter(|v| v.as_dict().is_some())
            .ok_or_else(|| Error::bus(ERROR_INVALID_ARGS, "GetAll answered without a dictionary"))
    }

    /// Sets a property (the value is put in its variant here).
    pub fn set_property(
        &self,
        destination: &str,
        path: &str,
        interface: &str,
        name: &str,
        value: Value,
    ) -> Result<()> {
        self.call(
            destination,
            path,
            PROPERTIES,
            "Set",
            &[
                Value::str(interface),
                Value::str(name),
                Value::variant(value),
            ],
        )?;
        Ok(())
    }

    /// Sends a signal from the object at <path>.
    pub fn emit_signal(
        &self,
        path: &str,
        interface: &str,
        member: &str,
        args: &[Value],
    ) -> Result<()> {
        let (p, i, m) = (
            c(path, "an object path")?,
            c(interface, "an interface")?,
            c(member, "a signal")?,
        );
        let mut raw = ptr::null_mut();
        // SAFETY: a live bus and NUL-terminated names.
        check(
            unsafe {
                ffi::sd_bus_message_new_signal(
                    self.raw,
                    &mut raw,
                    p.as_ptr(),
                    i.as_ptr(),
                    m.as_ptr(),
                )
            },
            "making a signal",
        )?;
        let signal = OwnedMessage(raw);
        signal.append_all(args)?;
        self.send(&signal)
    }

    /// Says that properties of <interface> on the object at <path> changed, with their new values.
    pub fn emit_properties_changed(
        &self,
        path: &str,
        interface: &str,
        changed: Vec<(&str, Value)>,
    ) -> Result<()> {
        self.emit_signal(
            path,
            PROPERTIES,
            "PropertiesChanged",
            &[
                Value::str(interface),
                Value::options(changed),
                Value::Array("s".into(), vec![]),
            ],
        )
    }

    /// Runs <callback> for every message that matches <rule>, a D-Bus match
    /// rule (see `rule`), for as long as the slot is kept.
    pub fn add_match<F: FnMut(&Message) + 'static>(&self, rule: &str, callback: F) -> Result<Slot> {
        let rule = c(rule, "a match rule")?;
        let userdata = Box::into_raw(Box::new(Box::new(callback) as MatchCallback)) as *mut c_void;
        let mut slot = ptr::null_mut();
        // SAFETY: a live bus, a NUL-terminated rule, and userdata the trampoline knows the type of.
        let r = unsafe {
            ffi::sd_bus_add_match(
                self.raw,
                &mut slot,
                rule.as_ptr(),
                match_trampoline,
                userdata,
            )
        };
        if r < 0 {
            // SAFETY: the box made above, which sd-bus did not take.
            drop(unsafe { Box::from_raw(userdata as *mut MatchCallback) });
            return Err(Error::Os {
                errno: -r,
                doing: "adding a match",
            });
        }
        // SAFETY: the slot just made; the box goes with it.
        unsafe { ffi::sd_bus_slot_set_destroy_callback(slot, destroy::<MatchCallback>) };
        Ok(Slot { raw: slot })
    }

    /// Runs <callback> for each signal <member> of <interface> from <sender>
    /// at <path>; any of the three may be left out (None).
    pub fn match_signal<F: FnMut(&Message) + 'static>(
        &self,
        sender: Option<&str>,
        path: Option<&str>,
        interface: Option<&str>,
        member: Option<&str>,
        callback: F,
    ) -> Result<Slot> {
        let mut parts = vec![("type", "signal")];
        parts.extend(sender.map(|s| ("sender", s)));
        parts.extend(path.map(|s| ("path", s)));
        parts.extend(interface.map(|s| ("interface", s)));
        parts.extend(member.map(|s| ("member", s)));
        self.add_match(&rule(&parts), callback)
    }

    /// Who owns <name> now: its unique name, or none.
    pub fn name_owner(&self, name: &str) -> Result<Option<String>> {
        match self.call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetNameOwner",
            &[Value::str(name)],
        ) {
            Ok(answer) => Ok(answer.first().and_then(Value::as_str).map(str::to_owned)),
            Err(e) if e.name() == Some(ERROR_NAME_HAS_NO_OWNER) => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Runs <callback> with <name>'s new owner (none when it has gone) each
    /// time it changes hands, and says who owns it as the watch begins. The
    /// watch is in place before the owner is asked for, so no change between
    /// the two is missed.
    pub fn watch_name<F: FnMut(Option<&str>) + 'static>(
        &self,
        name: &str,
        mut callback: F,
    ) -> Result<(Slot, Option<String>)> {
        let slot = self.add_match(
            &rule(&[
                ("type", "signal"),
                ("sender", "org.freedesktop.DBus"),
                ("path", "/org/freedesktop/DBus"),
                ("interface", "org.freedesktop.DBus"),
                ("member", "NameOwnerChanged"),
                ("arg0", name),
            ]),
            move |message| {
                if let Ok(args) = message.args() {
                    let owner = args
                        .get(2)
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty());
                    callback(owner);
                }
            },
        )?;
        let owner = self.name_owner(name)?;
        Ok((slot, owner))
    }

    /// Asks for <name> (NAME_* flags). True once it is this connection's;
    /// false when it waits in the queue for it (NAME_QUEUE). Without the
    /// queue, a name another connection holds is an error (EEXIST).
    pub fn request_name(&self, name: &str, flags: u64) -> Result<bool> {
        let name = c(name, "a bus name")?;
        // SAFETY: a live bus and a NUL-terminated name.
        let r = unsafe { ffi::sd_bus_request_name(self.raw, name.as_ptr(), flags) };
        if r == -114 {
            // EALREADY: it is ours already.
            return Ok(true);
        }
        Ok(check(r, "asking for a bus name")? > 0)
    }

    pub fn release_name(&self, name: &str) -> Result<()> {
        let name = c(name, "a bus name")?;
        // SAFETY: a live bus and a NUL-terminated name.
        check(
            unsafe { ffi::sd_bus_release_name(self.raw, name.as_ptr()) },
            "giving up a bus name",
        )?;
        Ok(())
    }

    /// Puts an object at <path> with <interfaces>, answered by <handler>, for
    /// as long as the slot is kept. Introspection and the Properties
    /// interface are answered from the interfaces' descriptions; calls that
    /// do not fit them are refused before the handler sees them.
    pub fn export<H: Handler>(
        &self,
        path: &str,
        interfaces: Vec<Interface>,
        handler: H,
    ) -> Result<Slot> {
        let path_c = c(path, "an object path")?;
        let state = Exported {
            path: path.to_owned(),
            interfaces,
            handler: Box::new(handler),
        };
        let userdata = Box::into_raw(Box::new(state)) as *mut c_void;
        let mut slot = ptr::null_mut();
        // SAFETY: a live bus, a NUL-terminated path, and userdata the trampoline knows the type of.
        let r = unsafe {
            ffi::sd_bus_add_object(
                self.raw,
                &mut slot,
                path_c.as_ptr(),
                object_trampoline,
                userdata,
            )
        };
        if r < 0 {
            // SAFETY: the box made above, which sd-bus did not take.
            drop(unsafe { Box::from_raw(userdata as *mut Exported) });
            return Err(Error::Os {
                errno: -r,
                doing: "putting an object on the bus",
            });
        }
        // SAFETY: the slot just made; the state goes with it.
        unsafe { ffi::sd_bus_slot_set_destroy_callback(slot, destroy::<Exported>) };
        Ok(Slot { raw: slot })
    }

    /// The connection's socket, for poll().
    pub fn fd(&self) -> RawFd {
        // SAFETY: a live bus.
        unsafe { ffi::sd_bus_get_fd(self.raw) }
    }

    /// What to poll the socket for now (more than POLLIN while something waits to be written).
    pub fn events(&self) -> i16 {
        // SAFETY: a live bus.
        let r = unsafe { ffi::sd_bus_get_events(self.raw) };
        if r > 0 {
            r as i16
        } else {
            POLLIN
        }
    }

    /// The socket and what to poll it for.
    pub fn poll_fd(&self) -> PollFd {
        PollFd::new(self.fd(), self.events())
    }

    /// How long poll() may wait before sd-bus has something to do of its own
    /// (a call's answer that is late); none for as long as it likes.
    pub fn timeout(&self) -> Option<Duration> {
        let mut usec = u64::MAX;
        // SAFETY: a live bus and a valid pointer.
        if unsafe { ffi::sd_bus_get_timeout(self.raw, &mut usec) } < 0 {
            return None;
        }
        poll::until(usec)
    }

    /// Handles every message that has come, running the callbacks they are
    /// for. An error is the connection's: once it is gone, only a new one will do.
    pub fn dispatch(&self) -> Result<()> {
        loop {
            // SAFETY: a live bus; no message is asked back.
            let r = unsafe { ffi::sd_bus_process(self.raw, ptr::null_mut()) };
            if check(r, "reading from the bus")? == 0 {
                return Ok(());
            }
        }
    }

    /// Waits for the bus to have something, at most <timeout> (none: forever).
    pub fn wait(&self, timeout: Option<Duration>) -> Result<()> {
        let usec = timeout.map_or(u64::MAX, |t| t.as_micros() as u64);
        // SAFETY: a live bus.
        check(
            unsafe { ffi::sd_bus_wait(self.raw, usec) },
            "waiting on the bus",
        )?;
        Ok(())
    }

    /// Writes out whatever is waiting to be sent.
    pub fn flush(&self) -> Result<()> {
        // SAFETY: a live bus.
        check(unsafe { ffi::sd_bus_flush(self.raw) }, "writing to the bus")?;
        Ok(())
    }
}

/// A match rule from its keys and values, each value quoted as the D-Bus
/// specification has it (a quote inside one ends the quoting, is escaped, and
/// starts it again).
pub fn rule(parts: &[(&str, &str)]) -> String {
    parts
        .iter()
        .map(|(key, value)| format!("{key}='{}'", value.replace('\'', "'\\''")))
        .collect::<Vec<_>>()
        .join(",")
}

/// A match or an object on the bus, there for as long as this is kept.
pub struct Slot {
    raw: *mut sd_bus_slot,
}

impl Drop for Slot {
    fn drop(&mut self) {
        // SAFETY: our reference, given back once. sd-bus keeps the slot, and
        // the callback's state with it, until a callback running now returns.
        unsafe { ffi::sd_bus_slot_unref(self.raw) };
    }
}

type MatchCallback = Box<dyn FnMut(&Message)>;

unsafe extern "C" fn destroy<T>(userdata: *mut c_void) {
    // SAFETY: the box put into the slot when it was made, freed once, by sd-bus, as the slot goes.
    drop(unsafe { Box::from_raw(userdata as *mut T) });
}

unsafe extern "C" fn match_trampoline(
    m: *mut sd_bus_message,
    userdata: *mut c_void,
    _: *mut sd_bus_error,
) -> c_int {
    // SAFETY: the userdata is the callback add_match put there, alive while its slot is.
    let callback = unsafe { &mut *(userdata as *mut MatchCallback) };
    callback(&Message::borrowed(m));
    0
}

/// A message sd-bus handed over: valid while the callback that got it runs,
/// or while the call's answer it is lives.
pub struct Message<'a> {
    raw: *mut sd_bus_message,
    _life: PhantomData<&'a sd_bus_message>,
}

impl<'a> Message<'a> {
    fn borrowed(raw: *mut sd_bus_message) -> Message<'a> {
        Message {
            raw,
            _life: PhantomData,
        }
    }

    fn text(&self, p: *const c_char) -> Option<&'a str> {
        if p.is_null() {
            None
        } else {
            // SAFETY: NUL-terminated by sd-bus, and the message's for as long as it lives.
            unsafe { CStr::from_ptr(p) }.to_str().ok()
        }
    }

    /// Who sent it: a unique name (":1.42").
    pub fn sender(&self) -> Option<&'a str> {
        // SAFETY: a live message.
        self.text(unsafe { ffi::sd_bus_message_get_sender(self.raw) })
    }

    pub fn destination(&self) -> Option<&'a str> {
        // SAFETY: a live message.
        self.text(unsafe { ffi::sd_bus_message_get_destination(self.raw) })
    }

    pub fn path(&self) -> Option<&'a str> {
        // SAFETY: a live message.
        self.text(unsafe { ffi::sd_bus_message_get_path(self.raw) })
    }

    pub fn interface(&self) -> Option<&'a str> {
        // SAFETY: a live message.
        self.text(unsafe { ffi::sd_bus_message_get_interface(self.raw) })
    }

    pub fn member(&self) -> Option<&'a str> {
        // SAFETY: a live message.
        self.text(unsafe { ffi::sd_bus_message_get_member(self.raw) })
    }

    /// The signature of what it carries.
    pub fn signature(&self) -> &'a str {
        // SAFETY: a live message.
        self.text(unsafe { ffi::sd_bus_message_get_signature(self.raw, 1) })
            .unwrap_or("")
    }

    fn kind(&self) -> u8 {
        let mut kind = 0;
        // SAFETY: a live message and a valid pointer.
        unsafe { ffi::sd_bus_message_get_type(self.raw, &mut kind) };
        kind
    }

    pub fn is_signal(&self, interface: &str, member: &str) -> bool {
        self.kind() == ffi::SD_BUS_MESSAGE_SIGNAL
            && self.interface() == Some(interface)
            && self.member() == Some(member)
    }

    pub fn is_method_call(&self) -> bool {
        self.kind() == ffi::SD_BUS_MESSAGE_METHOD_CALL
    }

    /// The connection it came on, to answer or call out through from a callback.
    pub fn bus(&self) -> Bus {
        // SAFETY: a live message, whose bus this takes a reference of its own to.
        Bus {
            raw: unsafe { ffi::sd_bus_ref(ffi::sd_bus_message_get_bus(self.raw)) },
        }
    }

    /// What it carries, from the start, however often it is asked.
    pub fn args(&self) -> Result<Vec<Value>> {
        // SAFETY: a live message, read again from its start.
        check(
            unsafe { ffi::sd_bus_message_rewind(self.raw, 1) },
            "reading a message",
        )?;
        let mut values = Vec::new();
        while let Some(value) = read_next(self.raw)? {
            values.push(value);
        }
        Ok(values)
    }
}

/// A message of ours, given back to sd-bus as it is dropped.
struct OwnedMessage(*mut sd_bus_message);

impl Drop for OwnedMessage {
    fn drop(&mut self) {
        // SAFETY: our reference, given back once.
        unsafe { ffi::sd_bus_message_unref(self.0) };
    }
}

impl OwnedMessage {
    fn append_all(&self, values: &[Value]) -> Result<()> {
        values.iter().try_for_each(|v| append(self.0, v))
    }
}

fn append(m: *mut sd_bus_message, value: &Value) -> Result<()> {
    let basic = |t: u8, p: *const c_void| {
        // SAFETY: <p> points at a value of the C type sd-bus has for <t>.
        check(
            unsafe { ffi::sd_bus_message_append_basic(m, t as c_char, p) },
            "writing a message",
        )
        .map(|_| ())
    };
    let text = |t: u8, s: &str| {
        let s = c(s, "a string with a NUL in it")?;
        basic(t, s.as_ptr() as *const c_void)
    };
    let open = |t: u8, contents: &str| {
        let contents = c(contents, "a signature")?;
        // SAFETY: a message being written and a NUL-terminated signature.
        check(
            unsafe { ffi::sd_bus_message_open_container(m, t as c_char, contents.as_ptr()) },
            "writing a message",
        )
        .map(|_| ())
    };
    let close = || {
        // SAFETY: a container this opened.
        check(
            unsafe { ffi::sd_bus_message_close_container(m) },
            "writing a message",
        )
        .map(|_| ())
    };
    match value {
        Value::Byte(v) => basic(b'y', v as *const u8 as *const c_void),
        Value::Bool(v) => {
            let v = c_int::from(*v);
            basic(b'b', &v as *const c_int as *const c_void)
        }
        Value::Int16(v) => basic(b'n', v as *const i16 as *const c_void),
        Value::Uint16(v) => basic(b'q', v as *const u16 as *const c_void),
        Value::Int32(v) => basic(b'i', v as *const i32 as *const c_void),
        Value::Uint32(v) => basic(b'u', v as *const u32 as *const c_void),
        Value::Int64(v) => basic(b'x', v as *const i64 as *const c_void),
        Value::Uint64(v) => basic(b't', v as *const u64 as *const c_void),
        Value::Double(v) => basic(b'd', v as *const f64 as *const c_void),
        Value::Str(s) => text(b's', s),
        Value::Path(s) => text(b'o', s),
        Value::Signature(s) => text(b'g', s),
        Value::Fd(fd) => {
            let raw: c_int = std::os::fd::AsRawFd::as_raw_fd(&**fd);
            basic(b'h', &raw as *const c_int as *const c_void)
        }
        Value::Array(element, items) => {
            open(b'a', element)?;
            items.iter().try_for_each(|v| append(m, v))?;
            close()
        }
        Value::Dict(key, val, entries) => {
            let entry = format!("{key}{val}");
            open(b'a', &format!("{{{entry}}}"))?;
            for (k, v) in entries {
                open(b'e', &entry)?;
                append(m, k)?;
                append(m, v)?;
                close()?;
            }
            close()
        }
        Value::Struct(fields) => {
            let inner: String = fields.iter().map(Value::signature).collect();
            open(b'r', &inner)?;
            fields.iter().try_for_each(|v| append(m, v))?;
            close()
        }
        Value::Variant(inner) => {
            open(b'v', &inner.signature())?;
            append(m, inner)?;
            close()
        }
    }
}

/// The next value of the container being read, or none at its end.
fn read_next(m: *mut sd_bus_message) -> Result<Option<Value>> {
    let mut kind: c_char = 0;
    let mut contents = ptr::null();
    // SAFETY: a message being read, and valid out-pointers.
    if check(
        unsafe { ffi::sd_bus_message_peek_type(m, &mut kind, &mut contents) },
        "reading a message",
    )? == 0
    {
        return Ok(None);
    }
    let contents = if contents.is_null() {
        String::new()
    } else {
        // SAFETY: NUL-terminated by sd-bus.
        unsafe { CStr::from_ptr(contents) }
            .to_string_lossy()
            .into_owned()
    };
    read_value(m, kind as u8, &contents).map(Some)
}

fn read_value(m: *mut sd_bus_message, kind: u8, contents: &str) -> Result<Value> {
    macro_rules! basic {
        ($t:ty, $wrap:expr) => {{
            let mut v: $t = Default::default();
            // SAFETY: <v> is the C type sd-bus reads this type into.
            check(
                unsafe {
                    ffi::sd_bus_message_read_basic(
                        m,
                        kind as c_char,
                        &mut v as *mut $t as *mut c_void,
                    )
                },
                "reading a message",
            )?;
            Ok($wrap(v))
        }};
    }
    let text = || -> Result<String> {
        let mut p: *const c_char = ptr::null();
        // SAFETY: strings are read as a pointer into the message.
        check(
            unsafe {
                ffi::sd_bus_message_read_basic(
                    m,
                    kind as c_char,
                    &mut p as *mut *const c_char as *mut c_void,
                )
            },
            "reading a message",
        )?;
        // SAFETY: NUL-terminated, and the message's.
        Ok(unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
    };
    let enter = |t: u8| {
        let contents = c(contents, "a signature")?;
        // SAFETY: the container peek_type just found, with its contents.
        check(
            unsafe { ffi::sd_bus_message_enter_container(m, t as c_char, contents.as_ptr()) },
            "reading a message",
        )
        .map(|_| ())
    };
    let exit = || {
        // SAFETY: the container entered.
        check(
            unsafe { ffi::sd_bus_message_exit_container(m) },
            "reading a message",
        )
        .map(|_| ())
    };
    match kind {
        b'y' => basic!(u8, Value::Byte),
        b'b' => basic!(c_int, |v: c_int| Value::Bool(v != 0)),
        b'n' => basic!(i16, Value::Int16),
        b'q' => basic!(u16, Value::Uint16),
        b'i' => basic!(i32, Value::Int32),
        b'u' => basic!(u32, Value::Uint32),
        b'x' => basic!(i64, Value::Int64),
        b't' => basic!(u64, Value::Uint64),
        b'd' => basic!(f64, Value::Double),
        b's' => text().map(Value::Str),
        b'o' => text().map(Value::Path),
        b'g' => text().map(Value::Signature),
        b'h' => {
            let mut fd: c_int = -1;
            // SAFETY: a descriptor is read as an int, which stays the message's.
            check(
                unsafe {
                    ffi::sd_bus_message_read_basic(
                        m,
                        b'h' as c_char,
                        &mut fd as *mut c_int as *mut c_void,
                    )
                },
                "reading a message",
            )?;
            // A copy of our own, closed on exec, so that no program run later holds it.
            // SAFETY: a descriptor the message holds open.
            let copy = unsafe { ffi::fcntl(fd, ffi::F_DUPFD_CLOEXEC, 3) };
            if copy < 0 {
                return Err(Error::Os {
                    errno: std::io::Error::last_os_error().raw_os_error().unwrap_or(9),
                    doing: "keeping a file descriptor",
                });
            }
            // SAFETY: a descriptor just made, and ours alone.
            Ok(Value::Fd(Arc::new(unsafe { OwnedFd::from_raw_fd(copy) })))
        }
        b'a' => {
            enter(b'a')?;
            let value = if let Some(entry) =
                contents.strip_prefix('{').and_then(|e| e.strip_suffix('}'))
            {
                let (key, val) = entry.split_at(1);
                let mut entries = Vec::new();
                loop {
                    let mut t: c_char = 0;
                    let mut inner = ptr::null();
                    // SAFETY: as in read_next.
                    if check(
                        unsafe { ffi::sd_bus_message_peek_type(m, &mut t, &mut inner) },
                        "reading a message",
                    )? == 0
                    {
                        break;
                    }
                    let entry_c = c(entry, "a signature")?;
                    // SAFETY: a dictionary entry of this signature.
                    check(
                        unsafe {
                            ffi::sd_bus_message_enter_container(m, b'e' as c_char, entry_c.as_ptr())
                        },
                        "reading a message",
                    )?;
                    let k = read_next(m)?;
                    let v = read_next(m)?;
                    exit()?;
                    if let (Some(k), Some(v)) = (k, v) {
                        entries.push((k, v));
                    }
                }
                Value::Dict(key.to_owned(), val.to_owned(), entries)
            } else {
                let mut items = Vec::new();
                while let Some(item) = read_next(m)? {
                    items.push(item);
                }
                Value::Array(contents.to_owned(), items)
            };
            exit()?;
            Ok(value)
        }
        b'v' => {
            enter(b'v')?;
            let inner = read_next(m)?;
            exit()?;
            inner
                .map(Value::variant)
                .ok_or_else(|| Error::bus(ERROR_INVALID_ARGS, "an empty variant"))
        }
        b'r' => {
            enter(b'r')?;
            let mut fields = Vec::new();
            while let Some(field) = read_next(m)? {
                fields.push(field);
            }
            exit()?;
            Ok(Value::Struct(fields))
        }
        other => Err(Error::bus(
            ERROR_INVALID_ARGS,
            format!("a type this cannot read: {}", other as char),
        )),
    }
}

/// An interface an exported object has: its methods, signals and properties,
/// as introspection shows them.
#[derive(Debug, Clone)]
pub struct Interface {
    name: String,
    methods: Vec<(String, String, String)>,
    signals: Vec<(String, String)>,
    properties: Vec<(String, String, bool)>,
}

impl Interface {
    pub fn new(name: &str) -> Interface {
        Interface {
            name: name.into(),
            methods: Vec::new(),
            signals: Vec::new(),
            properties: Vec::new(),
        }
    }

    /// A method taking <input> and answering <output> (signatures).
    pub fn method(mut self, name: &str, input: &str, output: &str) -> Interface {
        self.methods
            .push((name.into(), input.into(), output.into()));
        self
    }

    pub fn signal(mut self, name: &str, args: &str) -> Interface {
        self.signals.push((name.into(), args.into()));
        self
    }

    /// A property the handler's `get` answers.
    pub fn property(mut self, name: &str, signature: &str) -> Interface {
        self.properties.push((name.into(), signature.into(), false));
        self
    }

    /// A property the handler's `get` answers and its `set` changes.
    pub fn writable_property(mut self, name: &str, signature: &str) -> Interface {
        self.properties.push((name.into(), signature.into(), true));
        self
    }
}

/// What answers an exported object's calls.
pub trait Handler: 'static {
    /// A call to one of the object's methods, its arguments as declared:
    /// the answer, or the error to answer with.
    fn call(&mut self, call: &Message, args: Vec<Value>) -> Result<Vec<Value>>;

    /// A property's value; none for one it does not have now.
    fn get(&mut self, _interface: &str, _property: &str) -> Option<Value> {
        None
    }

    /// Changes a writable property.
    fn set(&mut self, _interface: &str, property: &str, _value: &Value) -> Result<()> {
        Err(Error::bus(
            ERROR_PROPERTY_READ_ONLY,
            format!("{property} cannot be changed"),
        ))
    }
}

impl<F: FnMut(&Message, Vec<Value>) -> Result<Vec<Value>> + 'static> Handler for F {
    fn call(&mut self, call: &Message, args: Vec<Value>) -> Result<Vec<Value>> {
        self(call, args)
    }
}

struct Exported {
    path: String,
    interfaces: Vec<Interface>,
    handler: Box<dyn Handler>,
}

impl Exported {
    /// The answer to a call to the object, or none for one that is not its,
    /// which sd-bus answers.
    fn answer(&mut self, call: &Message) -> Option<Result<Vec<Value>>> {
        if !call.is_method_call() {
            return None;
        }
        let member = call.member()?;
        let interface = call.interface();
        match (interface, member) {
            (Some(INTROSPECTABLE), "Introspect") => {
                return Some(Ok(vec![Value::Str(self.introspect())]))
            }
            (Some(PROPERTIES), "Get" | "GetAll" | "Set") => {
                return Some(self.properties(call, member))
            }
            _ => {}
        }
        let (_, input, _) = self
            .interfaces
            .iter()
            .filter(|i| interface.is_none_or(|name| name == i.name))
            .flat_map(|i| i.methods.iter())
            .find(|(name, _, _)| name == member)?;
        if call.signature() != input {
            return Some(Err(Error::bus(
                ERROR_INVALID_ARGS,
                format!("{member} takes ({input}), not ({})", call.signature()),
            )));
        }
        Some(call.args().and_then(|args| self.handler.call(call, args)))
    }

    fn properties(&mut self, call: &Message, member: &str) -> Result<Vec<Value>> {
        let args = call.args()?;
        let interface_name = args.first().and_then(Value::as_str).unwrap_or("");
        let interface = self
            .interfaces
            .iter()
            .find(|i| i.name == interface_name)
            .ok_or_else(|| {
                Error::bus(
                    ERROR_UNKNOWN_INTERFACE,
                    format!("no interface {interface_name} here"),
                )
            })?;
        let named = |name: &str| {
            interface
                .properties
                .iter()
                .find(|(n, _, _)| n == name)
                .cloned()
                .ok_or_else(|| {
                    Error::bus(ERROR_UNKNOWN_PROPERTY, format!("no property {name} here"))
                })
        };
        match (member, args.as_slice()) {
            ("GetAll", [_]) => {
                let properties = interface.properties.clone();
                let values = properties
                    .iter()
                    .filter_map(|(name, _, _)| {
                        self.handler
                            .get(interface_name, name)
                            .map(|v| (name.as_str(), v))
                    })
                    .collect();
                Ok(vec![Value::options(values)])
            }
            ("Get", [_, Value::Str(name)]) => {
                named(name)?;
                self.handler
                    .get(interface_name, name)
                    .map(|v| vec![Value::variant(v)])
                    .ok_or_else(|| {
                        Error::bus(ERROR_UNKNOWN_PROPERTY, format!("{name} has no value now"))
                    })
            }
            ("Set", [_, Value::Str(name), value]) => {
                let (_, signature, writable) = named(name)?;
                if !writable {
                    return Err(Error::bus(
                        ERROR_PROPERTY_READ_ONLY,
                        format!("{name} cannot be changed"),
                    ));
                }
                let value = value.unvariant();
                if value.signature() != signature {
                    return Err(Error::bus(
                        ERROR_INVALID_ARGS,
                        format!("{name} is {signature}"),
                    ));
                }
                self.handler.set(interface_name, name, value)?;
                Ok(vec![])
            }
            _ => Err(Error::bus(
                ERROR_INVALID_ARGS,
                format!("{member} with ({})", call.signature()),
            )),
        }
    }

    fn introspect(&self) -> String {
        let args = |signature: &str, direction: Option<&str>| -> String {
            split_signature(signature)
                .unwrap_or_default()
                .iter()
                .map(|t| match direction {
                    Some(d) => format!("<arg type=\"{t}\" direction=\"{d}\"/>"),
                    None => format!("<arg type=\"{t}\"/>"),
                })
                .collect()
        };
        let mut xml = String::from(
            "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n\
             \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n<node>\n\
             <interface name=\"org.freedesktop.DBus.Introspectable\"><method name=\"Introspect\"><arg type=\"s\" direction=\"out\"/></method></interface>\n\
             <interface name=\"org.freedesktop.DBus.Peer\"><method name=\"Ping\"/><method name=\"GetMachineId\"><arg type=\"s\" direction=\"out\"/></method></interface>\n\
             <interface name=\"org.freedesktop.DBus.Properties\">\
             <method name=\"Get\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/><arg type=\"v\" direction=\"out\"/></method>\
             <method name=\"GetAll\"><arg type=\"s\" direction=\"in\"/><arg type=\"a{sv}\" direction=\"out\"/></method>\
             <method name=\"Set\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/><arg type=\"v\" direction=\"in\"/></method>\
             <signal name=\"PropertiesChanged\"><arg type=\"s\"/><arg type=\"a{sv}\"/><arg type=\"as\"/></signal></interface>\n",
        );
        for interface in &self.interfaces {
            xml += &format!("<interface name=\"{}\">", interface.name);
            for (name, input, output) in &interface.methods {
                xml += &format!(
                    "<method name=\"{name}\">{}{}</method>",
                    args(input, Some("in")),
                    args(output, Some("out"))
                );
            }
            for (name, signature) in &interface.signals {
                xml += &format!("<signal name=\"{name}\">{}</signal>", args(signature, None));
            }
            for (name, signature, writable) in &interface.properties {
                let access = if *writable { "readwrite" } else { "read" };
                xml += &format!(
                    "<property name=\"{name}\" type=\"{signature}\" access=\"{access}\"/>"
                );
            }
            xml += "</interface>\n";
        }
        xml + "</node>\n"
    }
}

unsafe extern "C" fn object_trampoline(
    m: *mut sd_bus_message,
    userdata: *mut c_void,
    _: *mut sd_bus_error,
) -> c_int {
    // SAFETY: the userdata is the state export put there, alive while its slot is.
    let state = unsafe { &mut *(userdata as *mut Exported) };
    let call = Message::borrowed(m);
    if call.path() != Some(state.path.as_str()) {
        return 0;
    }
    let Some(answer) = state.answer(&call) else {
        return 0;
    };
    // SAFETY: a live message.
    if unsafe { ffi::sd_bus_message_get_expect_reply(m) } <= 0 {
        return 1;
    }
    let mut reply = ptr::null_mut();
    let made = match &answer {
        // SAFETY: a method call, and a valid out-pointer.
        Ok(_) => unsafe { ffi::sd_bus_message_new_method_return(m, &mut reply) },
        Err(error) => {
            let (name, text) = match error {
                Error::Bus { name, message } => (name.clone(), message.clone()),
                other => (ERROR_FAILED.to_owned(), other.to_string()),
            };
            let name = CString::new(name)
                .unwrap_or_else(|_| CString::from(c"org.freedesktop.DBus.Error.Failed"));
            let text = CString::new(text).unwrap_or_default();
            // SAFETY: a method call, NUL-terminated strings, and a format that takes one.
            unsafe {
                ffi::sd_bus_message_new_method_errorf(
                    m,
                    &mut reply,
                    name.as_ptr(),
                    c"%s".as_ptr(),
                    text.as_ptr(),
                )
            }
        }
    };
    if made < 0 {
        return made;
    }
    let reply = OwnedMessage(reply);
    if let Ok(values) = &answer {
        if let Err(Error::Os { errno, .. }) = reply.append_all(values) {
            return -errno;
        }
    }
    let bus = call.bus();
    match bus.send(&reply) {
        Ok(()) => 1,
        Err(Error::Os { errno, .. }) => -errno,
        Err(_) => -5,
    }
}
