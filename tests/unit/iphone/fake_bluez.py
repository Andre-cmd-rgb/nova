"""A fake BlueZ, with a fake iPhone behind it, and a fake notification
server, on the private session bus dbus-run-session gives; and the scenarios
that drive nova-iphone-notifications through them. The fake starts the
daemon itself, once its names are on the bus, and prints a line for each
thing the daemon does to it, "ok"/"FAIL" for each check, then DONE.

    dbus-run-session -- python3 -B -I fake_bluez.py <scenario> <daemon> <scratch>

The iPhone speaks ANCS as Apple's specification has it: the daemon's
commands are checked byte for byte, and the answers go out in 20-byte
fragments, as over a link with the smallest MTU.
"""
import json
import os
import struct
import subprocess
import sys
import time

import dbus
import dbus.bus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

SCENARIO, DAEMON, SCRATCH = sys.argv[1:4]

PROPERTIES = "org.freedesktop.DBus.Properties"
OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
ADAPTER = "org.bluez.Adapter1"
DEVICE = "org.bluez.Device1"
LE_BEARER = "org.bluez.Bearer.LE1"
GATT_SERVICE = "org.bluez.GattService1"
GATT_CHARACTERISTIC = "org.bluez.GattCharacteristic1"
ADVERTISING_MANAGER = "org.bluez.LEAdvertisingManager1"
AGENT_MANAGER = "org.bluez.AgentManager1"
NOTIFICATIONS = "org.freedesktop.Notifications"
NAME = "org.nova.iPhoneNotifications"
ANCS = "7905f431-b5ce-4e99-a40f-4b1e122d00d0"
NS = "9fbf120d-6301-42d9-8c58-25e699a21dbd"
CP = "69d1d8f3-45e1-49a8-9821-9bbdfdaad9d9"
DS = "22eac6e9-24d6-4bb5-be44-b36ace7c7bfb"
ADAPTER_PATH = "/org/bluez/hci0"
PHONE = ADAPTER_PATH + "/dev_AA_BB_CC_DD_EE_01"
STRANGER = ADAPTER_PATH + "/dev_AA_BB_CC_DD_EE_02"

DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
failures = []


def say(*words):
    print(*words, flush=True)


def check(ok, what):
    say(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


class Node(dbus.service.Object):
    """One of BlueZ's objects, with the methods of every interface the fake
    has: dbus-python dispatches by name."""

    def __init__(self, fake, path, interfaces):
        super().__init__(bus, path)
        self.fake = fake
        self.path = path
        self.interfaces = interfaces

    def update(self, interface, **changes):
        self.interfaces[interface].update(changes)
        self.PropertiesChanged(interface, changes, dbus.Array([], signature="s"))

    @dbus.service.signal(PROPERTIES, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    @dbus.service.method(PROPERTIES, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return dbus.Dictionary(self.interfaces.get(interface, {}), signature="sv")

    @dbus.service.method(PROPERTIES, in_signature="ss", out_signature="v")
    def Get(self, interface, name):
        return self.interfaces[interface][name]

    @dbus.service.method(ADVERTISING_MANAGER, in_signature="oa{sv}", out_signature="", sender_keyword="sender",
                         async_callbacks=("ok", "fail"))
    def RegisterAdvertisement(self, path, options, sender=None, ok=None, fail=None):
        self.fake.register(sender, str(path), ok, fail)

    @dbus.service.method(ADVERTISING_MANAGER, in_signature="o", out_signature="")
    def UnregisterAdvertisement(self, path):
        self.fake.unregister()

    # As BlueZ has it, an agent registered is one pairing may ask (the
    # default, or after it), whether or not it was made the default.
    @dbus.service.method(AGENT_MANAGER, in_signature="os", out_signature="", sender_keyword="sender")
    def RegisterAgent(self, path, capability, sender=None):
        self.fake.agent = (str(sender), str(path))
        self.fake.registrations += 1
        say("agent registered:", capability)

    @dbus.service.method(AGENT_MANAGER, in_signature="o", out_signature="")
    def RequestDefaultAgent(self, path):
        if self.fake.fail_default:
            say("agent not made the default")
            raise dbus.DBusException("Does Not Exist", name="org.bluez.Error.DoesNotExist")
        say("agent made the default")

    @dbus.service.method(AGENT_MANAGER, in_signature="o", out_signature="")
    def UnregisterAgent(self, path):
        self.fake.agent = None
        say("agent unregistered")

    @dbus.service.method(GATT_CHARACTERISTIC, in_signature="", out_signature="", async_callbacks=("ok", "fail"))
    def StartNotify(self, ok, fail):
        self.fake.start_notify(self, ok, fail)

    @dbus.service.method(GATT_CHARACTERISTIC, in_signature="aya{sv}", out_signature="")
    def WriteValue(self, value, options):
        self.fake.write(self, bytes(value), dict(options))


class Root(dbus.service.Object):
    def __init__(self, fake):
        super().__init__(bus, "/")
        self.fake = fake

    @dbus.service.method(OBJECT_MANAGER, in_signature="", out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        return dbus.Dictionary({path: dbus.Dictionary({i: dbus.Dictionary(p, signature="sv")
                                                      for i, p in node.interfaces.items()}, signature="sa{sv}")
                                for path, node in self.fake.nodes.items()}, signature="oa{sa{sv}}")

    @dbus.service.signal(OBJECT_MANAGER, signature="oa{sa{sv}}")
    def InterfacesAdded(self, path, interfaces):
        pass

    @dbus.service.signal(OBJECT_MANAGER, signature="oas")
    def InterfacesRemoved(self, path, interfaces):
        pass


class Notifications(dbus.service.Object):
    """The shell's notification server, as far as the daemon sees it."""

    def __init__(self, fake):
        super().__init__(bus, "/org/freedesktop/Notifications")
        self.fake = fake
        self.next = 0

    @dbus.service.method(NOTIFICATIONS, in_signature="susssasa{sv}i", out_signature="u")
    def Notify(self, app, replaces, icon, summary, body, actions, hints, timeout):
        self.next += 1
        note = {"id": self.next, "app": str(app), "replaces": int(replaces), "summary": str(summary),
                "body": str(body), "actions": [str(a) for a in actions],
                "glyph": "U+%X" % ord(str(hints.get("nova-glyph", " "))[0]),
                "urgency": int(hints.get("urgency", 1)), "quiet": bool(hints.get("nova-quiet", False)),
                "buttons": json.loads(str(hints.get("nova-buttons", "[]")))}
        self.fake.notes.append(note)
        say("notify:", json.dumps(note, ensure_ascii=False, sort_keys=True))
        return dbus.UInt32(self.next)

    @dbus.service.method(NOTIFICATIONS, in_signature="u", out_signature="")
    def CloseNotification(self, note):
        self.fake.closed.append(int(note))
        say("close:", int(note))
        self.NotificationClosed(note, dbus.UInt32(3))

    @dbus.service.signal(NOTIFICATIONS, signature="uu")
    def NotificationClosed(self, note, reason):
        pass

    @dbus.service.method(NOTIFICATIONS, in_signature="", out_signature="as")
    def GetCapabilities(self):
        return ["body", "actions"]


def b(value):
    return dbus.Boolean(value)


class Fake:
    def __init__(self):
        self.nodes = {}
        self.root = Root(self)
        self.server = Notifications(self)
        self.adverts = []  # each registration's properties
        self.advertising = None
        self.hold = False  # registrations left unanswered, for a reply that comes late
        self.held = []
        self.agent = None
        self.registrations = 0
        self.fail_default = False
        self.pairings = []  # (device, how it ended) for each pairing a device began
        self.env = {}
        self.notes = []
        self.closed = []
        self.writes = []  # each command written, hex
        self.subscriptions = []
        self.pair_answer = None
        self.notifications = {}  # uid → attributes
        self.apps = {b"net.whatsapp.WhatsApp": b"WhatsApp", b"com.apple.MobileSMS": b"Messages"}
        self.add(ADAPTER_PATH, {
            ADAPTER: {"Address": "00:11:22:33:44:55", "Alias": "Test Laptop", "Powered": b(True)},
            ADVERTISING_MANAGER: {"ActiveInstances": dbus.Byte(0)},
        })
        self.add("/org/bluez", {AGENT_MANAGER: {}})

    def add(self, path, interfaces):
        node = Node(self, path, interfaces)
        self.nodes[path] = node
        self.root.InterfacesAdded(path, dbus.Dictionary({i: dbus.Dictionary(p, signature="sv")
                                                        for i, p in interfaces.items()}, signature="sa{sv}"))
        return node

    def remove(self, path, interfaces=None):
        node = self.nodes[path]
        names = interfaces or list(node.interfaces)
        for name in names:
            node.interfaces.pop(name, None)
        self.root.InterfacesRemoved(path, dbus.Array(names, signature="s"))
        if not node.interfaces:
            del self.nodes[path]
            node.remove_from_connection()

    # -- the iPhone

    def add_phone(self, paired, connected):
        self.add(PHONE, {
            DEVICE: {"Address": "AA:BB:CC:DD:EE:01", "Alias": "Test iPhone", "Paired": b(paired),
                     "Bonded": b(paired), "Trusted": b(False), "Connected": b(connected),
                     "UUIDs": dbus.Array([ANCS] if paired else [], signature="s")},
            LE_BEARER: {"Connected": b(connected), "Paired": b(paired), "Bonded": b(paired),
                        "Interval": dbus.UInt32(30000), "Latency": dbus.UInt16(0),
                        "SupervisionTimeout": dbus.UInt16(720)},
        })
        self.add(PHONE + "/service0010", {GATT_SERVICE: {"UUID": ANCS, "Primary": b(True),
                                                         "Device": dbus.ObjectPath(PHONE)}})
        for number, uuid, flags in (("0011", NS, ["notify"]), ("0014", CP, ["write"]), ("0017", DS, ["notify"])):
            self.add(PHONE + "/service0010/char" + number, {GATT_CHARACTERISTIC: {
                "UUID": uuid, "Service": dbus.ObjectPath(PHONE + "/service0010"),
                "Notifying": b(False), "Flags": dbus.Array(flags, signature="s"),
                "Value": dbus.ByteArray(b"")}})

    def char(self, uuid):
        number = {NS: "0011", CP: "0014", DS: "0017"}[uuid]
        return self.nodes[PHONE + "/service0010/char" + number]

    def connect(self, connected):
        for char in (self.char(NS), self.char(DS)):
            if not connected:
                char.update(GATT_CHARACTERISTIC, Notifying=b(False))
        self.nodes[PHONE].update(LE_BEARER, Connected=b(connected))
        self.nodes[PHONE].update(DEVICE, Connected=b(connected))

    def event(self, kind, flags, category, uid):
        self.char(NS).update(GATT_CHARACTERISTIC, Value=dbus.ByteArray(struct.pack("<BBBBI", kind, flags, category, 1, uid)))

    def start_notify(self, node, ok, fail):
        role = {NS: "ns", DS: "ds"}[str(node.interfaces[GATT_CHARACTERISTIC]["UUID"])]
        self.subscriptions.append(role)
        say("subscribe:", role)
        phone = self.nodes[PHONE]
        if phone.interfaces[DEVICE]["Paired"]:
            node.update(GATT_CHARACTERISTIC, Notifying=b(True))
            ok()
            return
        # Not paired: the iPhone answers Insufficient Authentication, and
        # pairs, BlueZ asking an agent.

        def agreed():
            phone.update(DEVICE, Paired=b(True), Bonded=b(True), UUIDs=dbus.Array([ANCS], signature="s"))
            node.update(GATT_CHARACTERISTIC, Notifying=b(True))
            ok()

        self.pair(PHONE, "confirm", agreed, lambda: fail(dbus.DBusException("Not paired", name="org.bluez.Error.Failed")))

    def pair(self, device, how, agreed=None, refused=None):
        """A pairing <device> begins, as BlueZ answers it: with no agent
        registered BlueZ clears the controller's bondable setting (unless
        main.conf's AlwaysPairable, which Nova leaves off), and the kernel
        turns the pairing down; with one, a code to compare is asked with
        RequestConfirmation, and a pairing with none (Just Works) with
        RequestAuthorization."""
        def ended(result):
            say(f"pairing: {result}")
            self.pairings.append((device, result))
            if result == "agreed":
                (agreed or (lambda: None))()
            else:
                (refused or (lambda: None))()

        if self.agent is None:
            ended("refused, not bondable: no agent")
            return
        sender, path = self.agent
        if how == "confirm":
            method, signature, args = "RequestConfirmation", "ou", [dbus.ObjectPath(device), dbus.UInt32(123456)]
        else:
            method, signature, args = "RequestAuthorization", "o", [dbus.ObjectPath(device)]
        bus.call_async(sender, path, "org.bluez.Agent1", method, signature, args, lambda *_: ended("agreed"),
                       lambda error: ended("refused, " + error.get_dbus_name()), timeout=30)

    def write(self, node, value, options):
        self.writes.append(value.hex(" "))
        say("write:", value.hex(" "), options.get("type", ""))
        command = value[0]
        if command == 0:
            uid = struct.unpack_from("<I", value, 1)[0]
            if uid not in self.notifications:
                raise dbus.DBusException("Operation failed with ATT error: 0xa2", name="org.bluez.Error.Failed")
            attributes, at = [], 5
            while at < len(value):
                attributes.append(value[at])
                at += 3 if value[at] in (1, 2, 3) else 1
            answer = value[:5] + b"".join(bytes([a]) + struct.pack("<H", len(self.notifications[uid][a]))
                                          + self.notifications[uid][a] for a in attributes)
        elif command == 1:
            app = value[1:value.index(0, 1)]
            name = self.apps.get(app, b"")
            answer = value[:-1] + bytes([0]) + struct.pack("<H", len(name)) + name
        else:
            return
        # The answer follows the write's response, in 20-byte notifications.
        ds = self.char(DS)
        GLib.idle_add(lambda: [ds.update(GATT_CHARACTERISTIC, Value=dbus.ByteArray(answer[i:i + 20]))
                               for i in range(0, len(answer), 20)] and False)

    def note(self, uid, app, title, message, subtitle=b"", date=None):
        self.notifications[uid] = {0: app, 1: title, 2: subtitle, 3: message,
                                   5: date or time.strftime("%Y%m%dT%H%M%S").encode()}

    # -- advertising

    def register(self, sender, path, ok, fail):
        if self.hold:
            self.held.append((ok, fail))
            say("advertise: held, unanswered")
            return

        def got(properties):
            advert = {str(k): (list(map(str, v)) if isinstance(v, dbus.Array) else
                               bool(v) if isinstance(v, dbus.Boolean) else
                               int(v) if isinstance(v, int) else str(v)) for k, v in properties.items()}
            self.adverts.append(advert)
            self.advertising = (sender, path, advert)
            say("advertise:", json.dumps(advert, sort_keys=True))
            ok()

        bus.call_async(sender, path, PROPERTIES, "GetAll", "s", ["org.bluez.LEAdvertisement1"], got,
                       lambda error: fail(error))

    def unregister(self):
        self.advertising = None
        say("advertise: stopped")

    def release(self):
        sender, path, _ = self.advertising
        self.advertising = None
        say("advertise: released by BlueZ")
        bus.call_async(sender, path, "org.bluez.LEAdvertisement1", "Release", "", [], lambda *_: None, lambda *_: None)

    # -- the daemon and its state

    def state(self):
        try:
            with open(os.path.join(SCRATCH, "run", "nova", "iphone-notifications.json")) as state:
                return json.load(state)
        except (OSError, ValueError):
            return {}

    def call_daemon(self, method, signature, args):
        bus.call_async(NAME, "/org/nova/iPhoneNotifications", NAME, method, signature, args,
                       lambda *_: None, lambda error: say("daemon call failed:", error))

    def close_note(self, note, reason):
        say("closed by the shell:", note, reason)
        self.server.NotificationClosed(dbus.UInt32(note), dbus.UInt32(reason))


# ------------------------------------------------------------- scenarios
#
# Each is a generator: it yields a wait, (test, what, seconds), or a pause in
# seconds, and goes on once the test holds; a wait that runs out fails the
# run.

def until(test, what, seconds=8):
    return (test, what, seconds)


def advertising(f, mode):
    low = {"pairing": 100, "fast": 20, "slow": 1285}[mode]
    return lambda: f.advertising is not None and f.advertising[2].get("MinInterval") == low


def note_for(f, summary):
    return next((n for n in f.notes if n["summary"] == summary), None)


def pairing(f):
    yield until(lambda: f.state().get("state") == "no-iphone", "no iPhone at first")
    check(f.advertising is None and f.agent is None, "with no iPhone it neither advertises nor can pair")
    f.call_daemon("Pair", "b", [False])
    yield until(lambda: f.agent is not None and advertising(f, "pairing")(), "the pairing window opens")
    advert = f.advertising[2]
    check(advert == {"Type": "peripheral", "SolicitUUIDs": [ANCS], "Discoverable": True, "LocalName": "Test Laptop",
                     "MinInterval": 100, "MaxInterval": 150},
          "the pairing advertisement: discoverable, the computer's name, ANCS solicited, 100-150 ms")
    check(f.state().get("state") == "pairing" and f.state().get("pairingUntil", 0) > time.time(),
          "Settings is told the window is open, and until when")

    f.add_phone(paired=False, connected=True)
    yield until(lambda: f.advertising is None, "the advertisement stops once the iPhone has connected")
    yield until(lambda: any(n["buttons"] for n in f.notes), "the code is shown to compare")
    ask = next(n for n in f.notes if n["buttons"])
    check(ask["summary"] == "Pair with “Test iPhone”?" and ask["body"] == "Check that your iPhone shows 123456."
          and ask["app"] == "nova-action" and ask["urgency"] == 2,
          "the question names the iPhone and gives the code, and stays until answered")
    check([x["argv"] for x in ask["buttons"]] == [["nova-notification-iphone", "answer", "no"],
                                                   ["nova-notification-iphone", "answer", "yes"]]
          and ask["buttons"][1].get("main") is True, "Cancel and Pair, Pair the main one")
    # A button closes the notification as it runs its command: the answer
    # comes a moment after the close.
    f.close_note(ask["id"], 2)
    yield 0.5
    f.call_daemon("Answer", "b", [True])
    yield until(lambda: f.state().get("state") == "connected", "connected and subscribed after the pairing")
    check(f.subscriptions[:2] == ["ds", "ns"], "the Data Source subscribed first, then the Notification Source")
    yield until(lambda: f.agent is None, "the pairing agent goes once paired")
    check(f.advertising is None, "no advertising while the iPhone is connected")
    check(f.state().get("link") == {"interval": 30.0, "latency": 0, "timeout": 720},
          "the connection's parameters, as the iPhone chose them, for Settings and the journal")

    f.note(1, b"com.apple.MobileSMS", b"Anna", b"Hi")
    f.event(0, 16, 4, 1)
    yield until(lambda: note_for(f, "Messages · Anna"), "a message after pairing is shown")

    f.connect(False)
    yield until(advertising(f, "fast"), "the iPhone gone, it advertises fast")
    check(f.advertising[2] == {"Type": "peripheral", "SolicitUUIDs": [ANCS], "Discoverable": False,
                               "MinInterval": 20, "MaxInterval": 30},
          "for the iPhone to come back: not discoverable, no name, 20-30 ms")
    yield until(advertising(f, "slow"), "then slowly")
    check(f.advertising[2]["MaxInterval"] == 1285, "every 1285 ms")
    check(f.state().get("state") == "waiting", "Settings says the iPhone is not connected")


def declined(f):
    yield until(lambda: f.state().get("state") == "no-iphone", "no iPhone at first")
    f.call_daemon("Pair", "b", [False])
    yield until(lambda: f.agent is not None and advertising(f, "pairing")(), "the pairing window opens")
    f.add_phone(paired=False, connected=True)
    yield until(lambda: any(n["buttons"] for n in f.notes), "the code is shown to compare")
    f.call_daemon("Answer", "b", [False])
    yield until(lambda: f.subscriptions and "ds" in f.subscriptions, "the subscription that asked")
    yield 2
    check(len([n for n in f.notes if n["buttons"]]) == 1 and f.subscriptions == ["ds"],
          "turned down, it is not asked again on the same link")
    check(not f.nodes[PHONE].interfaces[DEVICE]["Paired"] and f.state().get("state") == "pairing",
          "not paired, and the window still open for another try")


def strangers(f):
    yield until(lambda: f.state().get("state") == "no-iphone", "no iPhone at first")
    # The pairing agent BlueZ will not make the default: registered, it would
    # still be asked, so it is unregistered, and the window closes.
    f.fail_default = True
    f.call_daemon("Pair", "b", [False])
    yield until(lambda: f.registrations == 1 and f.agent is None, "an agent not made the default is unregistered")
    yield until(lambda: f.state().get("state") == "no-iphone", "and the window closes")
    check(f.advertising is None, "with nothing advertised")
    f.fail_default = False

    # A device with a name of its choosing: bidirectional characters, too long.
    name = chr(0x202E) + "enohPi" + chr(0x2066) + " " + "x" * 80
    f.add(STRANGER, {DEVICE: {"Address": "AA:BB:CC:DD:EE:02", "Alias": name, "Paired": b(False), "Bonded": b(False),
                              "Trusted": b(False), "Connected": b(True), "UUIDs": dbus.Array([], signature="s")}})
    f.pair(STRANGER, "confirm")
    yield until(lambda: len(f.pairings) == 1, "a pairing it begins outside the window")
    check(f.pairings[-1][1] == "refused, not bondable: no agent" and not f.notes,
          "outside the window there is no agent: BlueZ turns the pairing down, and nothing is asked")

    f.call_daemon("Pair", "b", [False])
    yield until(lambda: f.agent is not None, "the window opens, with an agent")
    f.pair(STRANGER, "justworks")
    yield until(lambda: len(f.pairings) == 2, "a pairing with no code to compare")
    check(f.pairings[-1][1] == "refused, org.bluez.Error.Rejected" and not f.notes,
          "with no code to compare (Just Works): turned down, nothing asked")

    # Anyone on the bus may call the agent: only BlueZ is answered.
    other = dbus.bus.BusConnection(os.environ["DBUS_SESSION_BUS_ADDRESS"])
    answers = []
    other.call_async(f.agent[0], f.agent[1], "org.bluez.Agent1", "RequestConfirmation", "ou",
                     [dbus.ObjectPath(STRANGER), dbus.UInt32(111111)], lambda *_: answers.append("agreed"),
                     lambda error: answers.append(error.get_dbus_name()))
    yield until(lambda: answers, "an agent's question from another program")
    check(answers == ["org.bluez.Error.Rejected"] and not f.notes, "from another program than BlueZ: turned down, nothing asked")

    f.pair(STRANGER, "confirm")
    yield until(lambda: any(n["buttons"] for n in f.notes), "the code is shown to compare")
    ask = next(n for n in f.notes if n["buttons"])
    check(ask["summary"] == "Pair with “enohPi " + "x" * 51 + "…”?",
          "the device's name as plain text: no bidirectional characters, cut short")

    # An iPhone asking meanwhile is turned down; the first question stands.
    f.add_phone(paired=False, connected=True)
    yield until(lambda: len(f.pairings) == 3, "a second pairing while the first is asked about")
    check(f.pairings[-1] == (PHONE, "refused, org.bluez.Error.Rejected"), "the second one is turned down")
    check(ask["id"] not in f.closed and len([n for n in f.notes if n["buttons"]]) == 1,
          "the first question stays, and no second is asked")
    f.call_daemon("Answer", "b", [True])
    yield until(lambda: len(f.pairings) == 4, "the first question answered")
    check(f.pairings[-1] == (STRANGER, "agreed"), "the answer goes to the first one")

    # The window over, the agent goes, and BlueZ lets nothing pair.
    yield until(lambda: f.state().get("state") != "pairing" and f.agent is None, "the window closes", 20)
    f.pair(STRANGER, "confirm")
    yield until(lambda: len(f.pairings) == 5, "a pairing begun after the window")
    check(f.pairings[-1][1] == "refused, not bondable: no agent", "after the window: no agent, nothing pairs")


def notifications(f):
    f.note(1, b"net.whatsapp.WhatsApp", b"Old", b"Old message")
    f.add_phone(paired=True, connected=True)
    yield until(lambda: f.state().get("state") == "connected", "a paired iPhone connects without asking anything")
    check(f.agent is None and not f.notes, "no agent and no question for an iPhone paired before")

    f.event(0, 4 | 16, 4, 1)  # there before the connection
    yield 0.5
    check(not f.writes and not f.notes, "what the iPhone had before the connection is not shown")

    f.note(2, b"net.whatsapp.WhatsApp", b"Anna", b"Ciao <3")
    f.event(0, 16, 4, 2)
    yield until(lambda: note_for(f, "WhatsApp · Anna"), "a new message is shown")
    check(f.writes[0] == "00 02 00 00 00 00 01 80 00 02 80 00 03 40 01",
          "its attributes asked for: the app, the title, subtitle and message with their limits")
    check(f.writes[1] == bytes([1]).hex(" ") + " " + b"net.whatsapp.WhatsApp".hex(" ") + " 00 00",
          "then the app's name, once")
    shown = note_for(f, "WhatsApp · Anna")
    check(shown["app"] == "WhatsApp" and shown["body"] == "Ciao &lt;3" and shown["glyph"] == "U+F0369"
          and not shown["quiet"] and shown["actions"] == ["default", "Show"] and shown["urgency"] == 1,
          "as the app, its markup escaped, a message's glyph, a click a dismissal")

    f.note(3, b"net.whatsapp.WhatsApp", b"Group", b"Quiet one")
    f.event(0, 1 | 16, 4, 3)
    yield until(lambda: note_for(f, "WhatsApp · Group"), "a quiet one goes to the shell")
    check(note_for(f, "WhatsApp · Group")["quiet"], "marked quiet: to the history, no toast")
    check(len(f.writes) == 3, "the app's name is not asked again")

    f.note(4, b"com.apple.mobilephone", b"Mum", b"")
    f.event(0, 8 | 16, 1, 4)
    yield 0.5
    check(len(f.writes) == 3 and len(f.notes) == 2, "an incoming call is neither asked about nor shown")

    f.event(2, 0, 4, 2)
    yield until(lambda: shown["id"] in f.closed, "removed on the iPhone, taken down here")

    f.note(5, b"net.whatsapp.WhatsApp", b"Bea", b"Dismiss me")
    f.event(0, 16, 4, 5)
    yield until(lambda: note_for(f, "WhatsApp · Bea"), "another is shown")
    f.close_note(note_for(f, "WhatsApp · Bea")["id"], 2)
    yield until(lambda: "02 05 00 00 00 01" in f.writes, "dismissed here, it is cleared on the iPhone")

    f.note(6, b"net.whatsapp.WhatsApp", b"Cara", b"Let me run out")
    f.event(0, 16, 4, 6)
    yield until(lambda: note_for(f, "WhatsApp · Cara"), "another is shown")
    count = len(f.writes)
    f.close_note(note_for(f, "WhatsApp · Cara")["id"], 1)
    yield 0.5
    check(len(f.writes) == count, "one that ran out stays on the iPhone")
    f.event(1, 16, 4, 6)
    yield 0.5
    check(len(f.writes) == count and len(f.notes) == 4, "a change to one no longer shown shows nothing")

    f.note(7, b"com.apple.MobileSMS", b"Dan", b"No clearing")
    f.event(0, 0, 4, 7)
    yield until(lambda: note_for(f, "Messages · Dan"), "one the iPhone cannot clear is shown")
    count = len(f.writes)
    f.close_note(note_for(f, "Messages · Dan")["id"], 2)
    yield 0.5
    check(len(f.writes) == count, "dismissed, nothing is asked of the iPhone it has no action for")

    f.event(0, 16, 6, 9)  # the iPhone no longer has it (0xA2)
    f.note(10, b"com.apple.MobileSMS", b"Eve", b"After a refusal", subtitle=b"Re: plans")
    f.event(0, 16, 6, 10)
    yield until(lambda: note_for(f, "Messages · Eve"), "a refused command does not hold up the next")
    check(note_for(f, "Messages · Eve")["body"] == "Re: plans\nAfter a refusal"
          and note_for(f, "Messages · Eve")["glyph"] == "U+F01EE", "the subtitle above the message; mail's glyph")
    check(not note_for(f, "WhatsApp · ") and all("9" not in n["summary"] for n in f.notes), "nothing shown for the refused one")


def reused(f):
    f.add_phone(paired=True, connected=True)
    yield until(lambda: f.state().get("state") == "connected", "connected")
    f.note(5, b"net.whatsapp.WhatsApp", b"Anna", b"Before the drop")
    f.event(0, 16, 4, 5)
    yield until(lambda: note_for(f, "WhatsApp · Anna"), "a notification shown")
    old = note_for(f, "WhatsApp · Anna")
    f.connect(False)
    yield until(lambda: f.state().get("state") == "waiting", "the link drops, its toast still on screen")
    f.connect(True)
    yield until(lambda: f.state().get("state") == "connected", "back")
    # The iPhone numbers its notifications anew: uid 5 is another one now.
    f.note(5, b"net.whatsapp.WhatsApp", b"Bea", b"After the drop")
    f.event(0, 16, 4, 5)
    yield until(lambda: note_for(f, "WhatsApp · Bea"), "a new notification under the same uid")
    new = note_for(f, "WhatsApp · Bea")
    count = len(f.writes)
    f.close_note(old["id"], 2)
    yield 0.5
    check(len(f.writes) == count, "the old toast dismissed: nothing cleared on the iPhone, where its uid is another's")
    f.close_note(new["id"], 2)
    yield until(lambda: "02 05 00 00 00 01" in f.writes[count:], "the new one dismissed is cleared on the iPhone")


def hostile(f):
    # An iPhone, or what passes for one, that keeps to no limit.
    f.apps[b"com.example.loud"] = (chr(0x2066) + "Loud" + chr(0x2069) + "x" * 100).encode()
    f.add_phone(paired=True, connected=True)
    yield until(lambda: f.state().get("state") == "connected", "connected")
    f.note(1, b"com.example.loud", (chr(0x202E) + "A" * 1000).encode(), b"B" * 3000,
           subtitle=(chr(0x200B) + "Sub" + chr(0x200D) + "title").encode())
    f.event(0, 16, 4, 1)
    yield until(lambda: any(n["summary"].startswith("Loud") for n in f.notes), "the oversize one is shown")
    shown = next(n for n in f.notes if n["summary"].startswith("Loud"))
    check(shown["app"] == "Loud" + "x" * 54 + "…" and shown["summary"] == shown["app"] + " · " + "A" * 125 + "…",
          "the app's name and the title cut at their limits, the bidirectional characters gone")
    check(shown["body"] == "Sub" + chr(0x200D) + "title\n" + "B" * 320 + "…",
          "the message cut at its limit; format characters gone but the joiner")

    # An answer longer than any asked for is given up on, and the next one
    # is read past what is left of it.
    f.note(2, b"com.apple.MobileSMS", b"Big", b"C" * 9000)
    f.event(0, 16, 4, 2)
    f.note(3, b"com.apple.MobileSMS", b"After", b"the big one")
    f.event(0, 16, 4, 3)
    yield until(lambda: note_for(f, "Messages · After"), "the next one is shown")
    check(not note_for(f, "Messages · Big"), "the one with the long answer is not")

    # A flood: two hundred at once. Fifty are followed, the rest passed over.
    before = len(f.notes)
    for uid in range(100, 300):
        f.note(uid, b"com.apple.MobileSMS", f"Flood {uid}".encode(), b"x")
        f.event(0, 16, 4, uid)
    yield until(lambda: len(f.notes) - before >= 50, "the flood's first fifty shown", 20)
    yield 1
    flood = [n for n in f.notes[before:] if n["summary"].startswith("Messages · Flood")]
    check(len(flood) == 50 and flood[0]["summary"] == "Messages · Flood 100" and flood[-1]["summary"] == "Messages · Flood 149",
          "of a flood, the first fifty only")
    f.note(400, b"com.apple.MobileSMS", b"Later", b"after the flood")
    f.event(0, 16, 4, 400)
    yield until(lambda: note_for(f, "Messages · Later"), "after the flood, a new one is shown")


def late(f):
    # BlueZ restarts while a registration waits for its answer. The new BlueZ
    # refuses the registration asked of it; then the answer of the one
    # before comes, a yes, which is no longer true of anything.
    f.hold = True
    f.add_phone(paired=True, connected=False)
    yield until(lambda: len(f.held) == 1, "a registration BlueZ has not answered")
    bus.release_name("org.bluez")
    bus.request_name("org.bluez")
    yield until(lambda: len(f.held) == 2, "BlueZ back, and asked again")
    _, refuse = f.held[1]
    refuse(dbus.DBusException("Failed", name="org.bluez.Error.Failed"))
    yield 0.3
    ok, _ = f.held[0]
    ok()
    f.hold = False
    yield 0.5
    check(f.state().get("advertising") == "", "the answer of the BlueZ before counts for nothing")
    yield until(advertising(f, "fast"), "after its wait, it asks the new BlueZ again, as nothing is advertised", 10)


def taken(f):
    yield until(lambda: f.state().get("state") == "no-iphone", "the service runs")
    second = subprocess.run([sys.executable, "-B", "-I", DAEMON], env=f.env, capture_output=True, text=True, timeout=30)
    say(second.stderr.strip())
    check(second.returncode == 3, f"a second one, its name taken, ends with 3 ({second.returncode})")
    with open(DAEMON + ".service", encoding="utf-8") as unit:
        check("\nRestartPreventExitStatus=3\n" in unit.read(), "which its unit does not start again")
    check(f.state().get("state") == "no-iphone", "and the running one's state is left alone")


def reconnect(f):
    f.note(1, b"com.apple.MobileSMS", b"Ann", b"one")
    f.note(2, b"com.apple.MobileSMS", b"Ben", b"two")
    f.add_phone(paired=True, connected=True)
    yield until(lambda: f.state().get("state") == "connected", "connected")
    f.event(0, 4, 4, 1)
    f.event(0, 4, 4, 2)
    yield 0.3
    f.connect(False)
    yield until(lambda: f.state().get("state") == "waiting", "the link drops")
    # In the gap: one message came; and the iPhone has one from long ago
    # that it had not listed before (it numbers them afresh after a restart).
    f.note(7, b"com.apple.MobileSMS", b"Cat", b"in the gap")
    f.note(8, b"com.apple.MobileSMS", b"Old", b"long ago", date=b"20200101T000000")
    yield 0.3
    f.connect(True)
    yield until(lambda: f.state().get("state") == "connected", "back a moment later")
    count = len(f.writes)
    for uid in (1, 2, 7, 8):
        f.event(0, 4, 4, uid)
    yield until(lambda: note_for(f, "Messages · Cat"), "the message that came in the gap is shown")
    yield 0.5
    asked = f.writes[count:]
    check(asked[0] == "00 07 00 00 00 00 01 80 00 02 80 00 03 40 01 05",
          "for one not listed before the gap, its date is asked for too")
    check(not any(w.startswith("00 01 ") or w.startswith("00 02 ") for w in asked),
          "those listed before the gap are not asked about again")
    check(not note_for(f, "Messages · Old"), "one dated before the gap is not shown")


def restarts(f):
    f.add_phone(paired=True, connected=False)
    yield until(advertising(f, "fast"), "a paired iPhone away: advertising fast")
    yield until(advertising(f, "slow"), "then slowly")
    check(f.state().get("state") == "waiting", "waiting for the iPhone")

    bus.release_name("org.bluez")
    say("bluez: stopped")
    f.advertising = None
    yield until(lambda: f.state().get("state") == "no-bluetooth", "BlueZ gone: no Bluetooth")
    bus.request_name("org.bluez")
    say("bluez: started")
    yield until(advertising(f, "fast"), "BlueZ back: advertising fast again")

    # The card's firmware resets: BlueZ lets the advertisement go and the
    # controller with it, then the controller comes back.
    f.release()
    adapter = dict(f.nodes[ADAPTER_PATH].interfaces)
    f.remove(ADAPTER_PATH)
    yield until(lambda: f.state().get("state") == "no-bluetooth", "the controller gone")
    f.add(ADAPTER_PATH, adapter)
    yield until(advertising(f, "fast"), "the controller back: advertising fast again, without waiting")

    f.nodes[ADAPTER_PATH].update(ADAPTER, Powered=b(False))
    yield until(lambda: f.advertising is None and f.state().get("state") == "bluetooth-off",
                "Bluetooth turned off: nothing advertised")
    f.nodes[ADAPTER_PATH].update(ADAPTER, Powered=b(True))
    yield until(advertising(f, "fast"), "on again: advertising fast")

    with open(os.path.join(SCRATCH, "main.conf"), "w") as conf:
        conf.write("[General]\nControllerMode = bredr\n")
    bus.release_name("org.bluez")
    f.advertising = None
    yield 0.3
    bus.request_name("org.bluez")
    yield until(lambda: f.state().get("state") == "no-le", "with Bluetooth LE off, it says so")
    yield 0.5
    check(f.advertising is None, "and advertises nothing")


SCENARIOS = {"pairing": pairing, "declined": declined, "strangers": strangers, "notifications": notifications,
             "reused": reused, "hostile": hostile, "reconnect": reconnect, "restarts": restarts, "late": late,
             "taken": taken}
# A pairing window short enough to see it close; a fast phase that outlasts
# the wait after a refusal.
ENVIRONMENTS = {"strangers": {"NOVA_IPHONE_PAIR_SECONDS": "10"}, "late": {"NOVA_IPHONE_FAST_SECONDS": "60"}}


def main():
    fake = Fake()
    names = [dbus.service.BusName("org.bluez", bus), dbus.service.BusName(NOTIFICATIONS, bus)]
    os.makedirs(os.path.join(SCRATCH, "run"), mode=0o700, exist_ok=True)
    with open(os.path.join(SCRATCH, "main.conf"), "w") as conf:
        conf.write("[General]\n#ControllerMode = dual\n")
    # A state file a run before left behind, which this one is not to believe.
    os.makedirs(os.path.join(SCRATCH, "run", "nova"), mode=0o700, exist_ok=True)
    with open(os.path.join(SCRATCH, "run", "nova", "iphone-notifications.json"), "w") as left:
        left.write('{"state": "stale"}\n')
    env = dict(os.environ, NOVA_IPHONE_BUS="session", NOVA_IPHONE_FAST_SECONDS="1", NOVA_IPHONE_PAIR_SECONDS="30",
               NOVA_IPHONE_REPLY_SECONDS="1", NOVA_BLUETOOTH_CONF=os.path.join(SCRATCH, "main.conf"),
               XDG_RUNTIME_DIR=os.path.join(SCRATCH, "run"))
    env.update(ENVIRONMENTS.get(SCENARIO, {}))
    fake.env = env
    daemon = subprocess.Popen([sys.executable, "-B", "-I", DAEMON], env=env, stdout=sys.stdout, stderr=sys.stdout)
    loop = GLib.MainLoop()
    steps = SCENARIOS[SCENARIO](fake)
    waiting = {"test": None, "what": "", "until": 0.0}

    def advance():
        try:
            step = next(steps)
        except StopIteration:
            loop.quit()
            return
        if isinstance(step, (int, float)):
            GLib.timeout_add(int(step * 1000), lambda: advance() and False)
        else:
            waiting.update(test=step[0], what=step[1], until=time.monotonic() + step[2])
            GLib.timeout_add(20, poll)

    def poll():
        if waiting["test"]():
            advance()
            return False
        if time.monotonic() > waiting["until"]:
            check(False, "in time: " + waiting["what"])
            loop.quit()
            return False
        return True

    GLib.timeout_add(100, lambda: advance() and False)
    GLib.timeout_add(90000, lambda: (check(False, "the whole scenario in time"), loop.quit()) and False)
    loop.run()
    daemon.terminate()
    try:
        status = daemon.wait(5)
    except subprocess.TimeoutExpired:
        daemon.kill()
        status = "killed"
    check(status == 0, f"the daemon stops cleanly on SIGTERM ({status})")
    check(not os.path.exists(os.path.join(SCRATCH, "run", "nova", "iphone-notifications.json")),
          "and takes its state file with it")
    del names
    say("DONE")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
