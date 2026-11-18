# nova-calendar-sync against a CalDAV server on 127.0.0.1: the fake one
# (fake_caldav.py), or Radicale when one is given. The test plays the phone,
# changing the server's calendars over HTTP, and the shell, changing the
# calendar's files as Store.qml writes them; it prints "ok"/"FAIL" for each
# check, then DONE.
#
#   python3 -B -I sync_test.py <scenario> <sync program> [radicale]
#
# With "radicale", the server is the radicale on PATH, run with a scratch
# storage; scenarios that need something only the fake can do (no sync
# tokens, Google's sign-in, a read-only calendar) run on the fake whatever is
# asked.

import base64
import http.client
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fake_caldav  # noqa: E402

SCENARIO, SYNC = sys.argv[1], sys.argv[2]
WANT_RADICALE = len(sys.argv) > 3 and sys.argv[3] == "radicale"
FAILED = []

loader = importlib.machinery.SourceFileLoader("ncs", SYNC)
spec = importlib.util.spec_from_loader("ncs", loader)
ncs = importlib.util.module_from_spec(spec)
loader.exec_module(ncs)


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        FAILED.append(what)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


# ---- servers

class Fake:
    radicale = False

    def __init__(self, user="alice", password="pw-SECRET-1", bearer=None):
        self.fake = fake_caldav.FakeCalDAV(user=user, password=password, bearer=bearer)
        self.user, self.password = user, password
        self.fake.start()

    @property
    def url(self):
        return self.fake.url

    def base(self, cal):
        return "/alice/cals/%s/" % cal

    def make_calendar(self, name, display, comps=("VEVENT", "VTODO"), color="#FF2968FF"):
        self.fake.add_calendar(name, display, comps, color)

    def stop(self):
        self.fake.stop()

    def start(self):
        self.fake.start()


class Radicale:
    radicale = True

    def __init__(self, scratch):
        self.user, self.password = "alice", "pw-SECRET-1"
        self.port = free_port()
        self.dir = os.path.join(scratch, "radicale")
        os.makedirs(self.dir)
        with open(os.path.join(self.dir, "users"), "w") as f:
            f.write("%s:%s\n" % (self.user, self.password))
        with open(os.path.join(self.dir, "config"), "w") as f:
            f.write("[server]\nhosts = 127.0.0.1:%d\n[auth]\ntype = htpasswd\nhtpasswd_filename = %s/users\nhtpasswd_encryption = plain\n"
                    "[storage]\nfilesystem_folder = %s/collections\n[rights]\ntype = owner_only\n[logging]\nlevel = warning\n"
                    % (self.port, self.dir, self.dir))
        self.proc = None
        self.start()

    @property
    def url(self):
        return "http://127.0.0.1:%d/" % self.port

    def base(self, cal):
        return "/alice/%s/" % cal

    def start(self):
        self.proc = subprocess.Popen(["radicale", "--config", os.path.join(self.dir, "config")], stdout=subprocess.DEVNULL, stderr=open(os.path.join(self.dir, "log"), "a"))
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close()
                return
            except OSError:
                time.sleep(0.1)
        raise SystemExit("radicale did not start")

    def stop(self):
        self.proc.terminate()
        self.proc.wait()

    def make_calendar(self, name, display, comps=("VEVENT", "VTODO"), color="#FF2968FF"):
        phone = Phone(self)
        phone.req("PROPFIND", "/alice/", '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>', {"Depth": "0"})
        body = ('<?xml version="1.0" encoding="utf-8"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">'
                '<d:set><d:prop><d:displayname>%s</d:displayname><a:calendar-color>%s</a:calendar-color><c:supported-calendar-component-set>%s'
                '</c:supported-calendar-component-set></d:prop></d:set></c:mkcalendar>') % (display, color, "".join('<c:comp name="%s"/>' % c for c in comps))
        status, _, _ = phone.req("MKCALENDAR", self.base(name), body)
        assert status in (200, 201), status


class Phone:
    """The phone, or the web: the server's calendars changed over HTTP."""

    def __init__(self, server, bearer=None):
        self.server = server
        self.bearer = bearer

    def req(self, method, path, body=None, headers=None):
        port = urllib.parse.urlsplit(self.server.url).port
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        h = dict(headers or {})
        if self.bearer:
            h["Authorization"] = "Bearer " + self.bearer
        else:
            h["Authorization"] = "Basic " + base64.b64encode(("%s:%s" % (self.server.user, self.server.password)).encode()).decode()
        if body is not None:
            h.setdefault("Content-Type", "application/xml; charset=utf-8")
        conn.request(method, path, body.encode() if isinstance(body, str) else body, h)
        r = conn.getresponse()
        data = r.read()
        conn.close()
        return r.status, {k.lower(): v for k, v in r.getheaders()}, data.decode("utf-8", "replace")

    def put(self, cal, name, text, etag=None):
        h = {"Content-Type": "text/calendar; charset=utf-8"}
        if etag:
            h["If-Match"] = etag
        status, headers, _ = self.req("PUT", self.server.base(cal) + name, text, h)
        assert status in (200, 201, 204), status
        return headers.get("etag")

    def get(self, cal, name):
        status, headers, body = self.req("GET", self.server.base(cal) + name)
        return body if status == 200 else None

    def delete(self, cal, name):
        status, _, _ = self.req("DELETE", self.server.base(cal) + name)
        assert status in (200, 204), status

    def all(self, cal):
        """{uid: text} of every item in a calendar."""
        status, _, body = self.req("PROPFIND", self.server.base(cal), '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>', {"Depth": "1"})
        out = {}
        for href in re.findall(r"<(?:\w+:)?href>([^<]+)</(?:\w+:)?href>", body):
            path = urllib.parse.urlsplit(href).path
            if path.rstrip("/") == self.server.base(cal).rstrip("/"):
                continue
            status, _, text = self.req("GET", path)
            if status == 200:
                m = re.search(r"^UID:(.*)$", text.replace("\r\n", "\n"), re.M)
                out[m.group(1).strip() if m else path] = text
        return out

    def name_of(self, cal, uid):
        """The resource's name the server keeps an item under."""
        status, _, body = self.req("PROPFIND", self.server.base(cal), '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>', {"Depth": "1"})
        for href in re.findall(r"<(?:\w+:)?href>([^<]+)</(?:\w+:)?href>", body):
            path = urllib.parse.urlsplit(href).path
            if path.rstrip("/") == self.server.base(cal).rstrip("/"):
                continue
            status, _, text = self.req("GET", path)
            if "UID:" + uid in text:
                return path.rsplit("/", 1)[-1]
        return None


# ---- the computer: a scratch home, the keyring stubbed, the sync run

class Computer:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="nova-calsync.")
        self.home = os.path.join(self.dir, "home")
        os.makedirs(os.path.join(self.dir, "bin"))
        os.makedirs(self.home)
        self.env = {"HOME": self.home, "PATH": os.path.join(self.dir, "bin") + ":/usr/bin", "LANG": "C.UTF-8", "TZ": "Europe/Rome",
                    "NOVA_TEST_SECRETS": os.path.join(self.dir, "secrets.json"), "NOVA_CALENDAR_TIMEOUT": "5",
                    "NOVA_PATH": os.path.join(self.dir, "nova")}
        if SCENARIO == "keyring":
            # The real secret-tool, on the keyring of the test's own D-Bus
            # session (sync.bats starts both).
            self.env["DBUS_SESSION_BUS_ADDRESS"] = os.environ["DBUS_SESSION_BUS_ADDRESS"]
        else:
            stub = os.path.join(self.dir, "bin", "secret-tool")
            shutil.copy(os.path.join(HERE, "secret-tool"), stub)
            os.chmod(stub, 0o755)

    def run(self, *args, request=None):
        done = subprocess.run([sys.executable, "-B", "-I", SYNC] + list(args), input=json.dumps(request) if request is not None else "",
                              capture_output=True, text=True, env=self.env, timeout=120)
        return done

    def sync(self, *args):
        done = self.run("sync", *args)
        if done.stderr:
            print("  sync said: " + done.stderr.strip())
        return done

    def config(self):
        with open(os.path.join(self.home, ".config/nova/calendars.json")) as f:
            return json.load(f)

    def status(self):
        with open(os.path.join(self.home, ".local/state/nova/calendar-sync/status.json")) as f:
            return json.load(f)

    def calendar(self, name):
        return next(c for c in self.config()["calendars"] if c["name"] == name)

    def path(self, name):
        return os.path.join(self.home, ".local/share/nova/calendar", self.calendar(name)["file"])

    def items(self, name):
        """{uid: [components]} of a calendar's file."""
        text = ncs.read_file(self.path(name)) or ""
        return ncs.groups(ncs.calendar_of(ncs.parse(text)))

    def edit(self, name, change):
        """The file changed as the shell changes it: read, edited, written
        whole."""
        path = self.path(name)
        root = ncs.parse(ncs.read_file(path) or "")
        cal = ncs.calendar_of(root)
        change(cal)
        with open(path, "w", newline="") as f:
            f.write(ncs.serialize(root.children))

    def add(self, server, name=None):
        done = self.run("add", request={"type": "caldav", "url": server.url, "user": server.user, "password": server.password})
        check(done.returncode == 0, "the account is added (%s)" % done.stderr.strip())
        return json.loads(done.stdout or "{}")

    def secrets(self):
        try:
            with open(self.env["NOVA_TEST_SECRETS"]) as f:
                return json.load(f)
        except FileNotFoundError:
            return {}


def vcal(*components, zones=""):
    return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Phone//EN\r\n" + zones + "".join(components) + "END:VCALENDAR\r\n"


def vevent(uid, summary, start, end, *extra):
    lines = ["BEGIN:VEVENT", "UID:" + uid, "DTSTAMP:20261101T000000Z", "DTSTART" + start, "DTEND" + end, "SUMMARY:" + summary] + list(extra) + ["END:VEVENT"]
    return "\r\n".join(lines) + "\r\n"


def new_component(cal, text):
    for c in ncs.parse(text).children:
        cal.children.append(c)


def summary(group):
    return ncs.unescape(ncs.value(group[0], "SUMMARY")) if group else None


def set_prop(cal, uid, name, text, rid=None):
    for c in cal.children:
        if ncs.unescape(ncs.value(c, "UID")) == uid and (rid is None) == (ncs.get(c, "RECURRENCE-ID") is None):
            if rid is None or rid in ncs.value(c, "RECURRENCE-ID"):
                # NAME;PARAM=x in place of every NAME, as the shell's setProp.
                base = name.split(";")[0]
                at = next((i for i, line in enumerate(c.lines) if ncs.prop_name(line) == base), len(c.lines))
                c.lines = [line for line in c.lines if ncs.prop_name(line) != base]
                c.lines.insert(min(at, len(c.lines)), name + ":" + text)
                ncs.set_line(c, "LAST-MODIFIED", "20261118T120000Z")


def drop(cal, uid):
    cal.children = [c for c in cal.children if ncs.unescape(ncs.value(c, "UID")) != uid]


def server_for(scratch, need_fake=False, **kw):
    if WANT_RADICALE and not need_fake:
        return Radicale(scratch)
    return Fake(**kw)


ROME = ("BEGIN:VTIMEZONE\r\nTZID:Europe/Rome\r\nBEGIN:DAYLIGHT\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\nTZNAME:CEST\r\n"
        "DTSTART:19700329T020000\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\nEND:DAYLIGHT\r\nBEGIN:STANDARD\r\nTZOFFSETFROM:+0200\r\n"
        "TZOFFSETTO:+0100\r\nTZNAME:CET\r\nDTSTART:19701025T030000\r\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n")


# ---- scenarios

def scenario_discovery(pc):
    server = server_for(pc.dir)
    if not server.radicale:
        server.fake.home_host = "localhost"  # the home on another host, as iCloud has it
    server.make_calendar("home", "Home", ("VEVENT", "VTODO"), "#FF2968FF")
    server.make_calendar("work", "Work", ("VEVENT",), "#1BADF8FF")
    bad = pc.run("add", request={"type": "caldav", "url": server.url, "user": server.user, "password": "wrong"})
    check(bad.returncode == 3 and "not accepted" in bad.stderr, "a wrong password is refused, in words (%d: %s)" % (bad.returncode, bad.stderr.strip()))
    plain = pc.run("add", request={"type": "caldav", "url": "http://calendar.example.org/", "user": "a", "password": "b"})
    check(plain.returncode == 1 and "https://" in plain.stderr, "a password is not sent in the clear to another computer")
    added = pc.add(server)
    names = sorted(c["name"] for c in added.get("calendars", []))
    check(names == ["Home", "Work"], "it finds the account's calendars, and only calendars: %s" % names)
    config = pc.config()
    home, work = pc.calendar("Home"), pc.calendar("Work")
    check(config["calendars"][0]["id"] == "local" and config["calendars"][0]["kind"] == "local", "the calendar on this computer stays first")
    check(home["tasks"] and home["events"] and not work["tasks"] and not home["readOnly"], "what each calendar takes: events, tasks")
    check(home["color"] == "red" and work["color"] == "blue", "the server's colours become the theme's nearest (%s, %s)" % (home["color"], work["color"]))
    check(home["shown"] and work["shown"], "found calendars are shown")
    if not server.radicale:
        check(("PROPFIND", "/.well-known/caldav") in server.fake.log, "a server's address is looked up at /.well-known/caldav first")
        check(home["href"].startswith("http://localhost:"), "the calendar home on another host is followed")
    text = open(os.path.join(pc.home, ".config/nova/calendars.json")).read()
    check(server.password not in text, "the password is not in the calendar list")
    check(any(server.password == v for v in pc.secrets().values()), "it is in the keyring")
    check(oct(os.stat(os.path.join(pc.home, ".config/nova/calendars.json")).st_mode & 0o777) == "0o600", "the list is the user's alone")
    again = pc.run("add", request={"type": "caldav", "url": server.url, "user": server.user, "password": server.password})
    check(again.returncode == 1 and "already" in again.stderr, "the same account is not added twice")
    # set, and remove
    check(pc.run("set", home["id"], "shown=false", "color=green", "name=Family").returncode == 0, "set runs")
    home = next(c for c in pc.config()["calendars"] if c["id"] == home["id"])
    check(not home["shown"] and home["color"] == "green" and home["name"] == "Family", "a calendar hidden, coloured and named")
    check(pc.run("set", home["id"], "color=purple").returncode == 1, "a colour that is not the theme's is refused")
    pc.sync()
    check(os.path.exists(pc.path("Work")), "a synced calendar has its file")
    account = pc.config()["accounts"][0]["id"]
    check(pc.run("remove", account).returncode == 0, "remove runs")
    left = pc.config()
    check(left["accounts"] == [] and [c["id"] for c in left["calendars"]] == ["local"], "the account and its calendars are gone from the list")
    check(not [f for f in os.listdir(os.path.join(pc.home, ".local/share/nova/calendar")) if f != "calendar.ics"], "and their files")
    check(not pc.secrets(), "and the password from the keyring")
    server.stop()


def scenario_two_way(pc):
    server = server_for(pc.dir)
    server.make_calendar("home", "Home")
    phone = Phone(server)
    phone.put("home", "dentist.ics", vcal(vevent("dentist@phone", "Dentist", ";TZID=Europe/Rome:20261110T100000", ";TZID=Europe/Rome:20261110T110000"), zones=ROME))
    phone.put("home", "trip.ics", vcal(vevent("trip@phone", "Trip", ";VALUE=DATE:20261112", ";VALUE=DATE:20261115")))
    phone.put("home", "milk.ics", vcal("BEGIN:VTODO\r\nUID:milk@phone\r\nDTSTAMP:20261101T000000Z\r\nSUMMARY:Buy milk\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\n"))
    pc.add(server)
    done = pc.sync()
    check(done.returncode == 0 and pc.status()[pc.config()["accounts"][0]["id"]]["state"] == "ok", "the first sync runs, and says so")
    items = pc.items("Home")
    check(sorted(items) == ["dentist@phone", "milk@phone", "trip@phone"], "the server's events and tasks come in: %s" % sorted(items))
    text = ncs.read_file(pc.path("Home"))
    check("BEGIN:VTIMEZONE" in text and "TZID:Europe/Rome" in text, "with the zones they name")

    # Made, changed, moved and deleted here.
    pc.edit("Home", lambda cal: new_component(cal, vevent("new@nova", "Lunch\\, with Sam", ";TZID=Europe/Rome:20261111T130000", ";TZID=Europe/Rome:20261111T140000",
                                                          "DESCRIPTION:Line one\\nline two")))
    pc.edit("Home", lambda cal: set_prop(cal, "dentist@phone", "SUMMARY", "Dentist (Dr Rossi)"))
    pc.edit("Home", lambda cal: (set_prop(cal, "trip@phone", "DTSTART;VALUE=DATE", "20261113"), set_prop(cal, "trip@phone", "DTEND;VALUE=DATE", "20261116")))
    pc.edit("Home", lambda cal: drop(cal, "milk@phone"))
    pc.sync()
    on_phone = phone.all("home")
    check("new@nova" in on_phone and "SUMMARY:Lunch\\, with Sam" in on_phone["new@nova"], "an event made here reaches the server")
    check("BEGIN:VTIMEZONE" in on_phone.get("new@nova", "") and "TZID:Europe/Rome" in on_phone.get("new@nova", ""), "with a VTIMEZONE for the zone it names")
    check("Dentist (Dr Rossi)" in on_phone.get("dentist@phone", ""), "a title changed here reaches it")
    check("DTSTART;VALUE=DATE:20261113" in on_phone.get("trip@phone", ""), "an event moved here reaches it")
    check("milk@phone" not in on_phone, "a task deleted here is deleted there")

    # Made, changed and deleted on the phone.
    phone.put("home", "gym.ics", vcal(vevent("gym@phone", "Gym", ":20261114T170000Z", ":20261114T180000Z")))
    name = phone.name_of("home", "dentist@phone")
    phone.put("home", name, on_phone["dentist@phone"].replace("Dentist (Dr Rossi)", "Dentist\\, moved").replace("20261110T110000", "20261110T160000").replace("20261110T100000", "20261110T150000"))
    phone.delete("home", phone.name_of("home", "trip@phone"))
    pc.sync()
    items = pc.items("Home")
    check("gym@phone" in items, "an event made on the phone comes in")
    check(summary(items.get("dentist@phone")) == "Dentist, moved" and "20261110T150000" in ncs.canon(items["dentist@phone"][0]), "one changed there comes in changed")
    check("trip@phone" not in items, "one deleted there is deleted here")
    check("Line one\\nline two" in ncs.read_file(pc.path("Home")), "text is kept as it was written")
    before = ncs.read_file(pc.path("Home"))
    mtime = os.stat(pc.path("Home")).st_mtime_ns
    pc.sync()
    check(ncs.read_file(pc.path("Home")) == before and os.stat(pc.path("Home")).st_mtime_ns == mtime, "with nothing changed, the file is left alone")
    if not server.radicale:
        check(any(m == "REPORT" for m, _ in server.fake.log), "the changes are asked for with sync-collection")
    server.stop()


def scenario_fallback(pc):
    server = Fake()
    server.fake.sync_tokens = False
    server.fake.etag_on_put = False
    server.make_calendar("home", "Home")
    phone = Phone(server)
    phone.put("home", "a.ics", vcal(vevent("a@phone", "A", ":20261110T100000Z", ":20261110T110000Z")))
    pc.add(server)
    pc.sync()
    check("a@phone" in pc.items("Home"), "without sync tokens, the first sync lists the items by their ETags")
    server.fake.log.clear()
    pc.sync()
    listed = [p for m, p in server.fake.log if m == "PROPFIND" and p == "/alice/cals/home/"]
    check(len(listed) == 1, "an unchanged ctag spares the listing (%d PROPFINDs of the calendar)" % len(listed))
    pc.edit("Home", lambda cal: set_prop(cal, "a@phone", "SUMMARY", "A here"))
    pc.sync()
    check("A here" in Phone(server).all("home")["a@phone"], "a change here is sent")
    check(any(m == "GET" for m, _ in server.fake.log), "with no ETag in the answer, what the server kept is read back")
    phone.put("home", "a.ics", Phone(server).all("home")["a@phone"].replace("A here", "A there"))
    pc.sync()
    check(summary(pc.items("Home")["a@phone"]) == "A there", "a change there is found by its ETag")
    check(not any(m == "REPORT" and "sync" in p for m, p in server.fake.log), "sync-collection is not asked of a server without it")
    server.stop()


def scenario_conflict(pc):
    server = server_for(pc.dir)
    server.make_calendar("home", "Home")
    phone = Phone(server)
    for uid in ("same", "apart", "gone-here", "gone-there"):
        phone.put("home", uid + ".ics", vcal(vevent(uid, "Title " + uid, ":20261110T100000Z", ":20261110T110000Z", "LOCATION:Room 1")))
    pc.add(server)
    pc.sync()
    texts = phone.all("home")
    # Both change the title differently; one changes the place and the other the title;
    # one deleted here and changed there; one changed here and deleted there.
    phone.put("home", phone.name_of("home", "same"), texts["same"].replace("Title same", "Phone's title"))
    phone.put("home", phone.name_of("home", "apart"), texts["apart"].replace("Title apart", "New title"))
    phone.put("home", phone.name_of("home", "gone-here"), texts["gone-here"].replace("Room 1", "Room 9"))
    phone.delete("home", phone.name_of("home", "gone-there"))
    pc.edit("Home", lambda cal: set_prop(cal, "same", "SUMMARY", "Computer's title"))
    pc.edit("Home", lambda cal: set_prop(cal, "apart", "LOCATION", "Room 2"))
    pc.edit("Home", lambda cal: drop(cal, "gone-here"))
    pc.edit("Home", lambda cal: set_prop(cal, "gone-there", "SUMMARY", "Still wanted"))
    pc.sync()
    items = pc.items("Home")
    on_phone = phone.all("home")
    copies = [u for u, g in items.items() if summary(g) == "Computer's title"]
    check(summary(items.get("same")) == "Phone's title", "changed the same way on both sides, the server's version stays the event")
    check(len(copies) == 1 and copies[0] != "same", "and this computer's is kept beside it, as a copy of its own")
    check(copies and copies[0] in on_phone and "Phone's title" in on_phone.get("same", ""), "both are on the server too")
    apart = ncs.canon(items["apart"][0])
    check("SUMMARY:New title" in apart and "LOCATION:Room 2" in apart, "changes to different things are merged")
    check("SUMMARY:New title" in on_phone["apart"] and "LOCATION:Room 2" in on_phone["apart"], "and the merge is sent")
    check("gone-here" in items and "Room 9" in ncs.canon(items["gone-here"][0]), "deleted here but changed there, it comes back changed")
    check("gone-there" in on_phone and "Still wanted" in on_phone["gone-there"], "changed here but deleted there, it is sent again")
    check(len(items) == 5 and len(on_phone) == 5, "and nothing else: %d here, %d there" % (len(items), len(on_phone)))
    pc.sync()
    check(len(pc.items("Home")) == 5 and len(phone.all("home")) == 5, "a second sync changes nothing")
    server.stop()


def scenario_offline(pc):
    server = server_for(pc.dir)
    server.make_calendar("home", "Home")
    phone = Phone(server)
    phone.put("home", "a.ics", vcal(vevent("a", "A", ":20261110T100000Z", ":20261110T110000Z")))
    phone.put("home", "b.ics", vcal(vevent("b", "B", ":20261110T120000Z", ":20261110T130000Z")))
    pc.add(server)
    pc.sync()
    account = pc.config()["accounts"][0]["id"]
    server.stop()
    pc.edit("Home", lambda cal: new_component(cal, vevent("c@nova", "Made offline", ":20261111T100000Z", ":20261111T110000Z")))
    pc.edit("Home", lambda cal: set_prop(cal, "a", "SUMMARY", "A offline"))
    pc.edit("Home", lambda cal: drop(cal, "b"))
    done = pc.sync()
    status = pc.status()[account]
    check(done.returncode == 0 and status["state"] == "offline", "with the server out of reach, the sync says offline, not failed")
    check(status.get("pending") == 3, "and how many changes wait: %s" % status.get("pending"))
    items = pc.items("Home")
    check("c@nova" in items and summary(items["a"]) == "A offline" and "b" not in items, "the edits stay in the file")
    server.start()
    pc.sync()
    on_phone = phone.all("home")
    check("c@nova" in on_phone and "A offline" in on_phone.get("a", "") and "b" not in on_phone, "back online, they are sent")
    check(pc.status()[account]["state"] == "ok" and pc.status()[account]["pending"] == 0, "and nothing waits")
    server.stop()


def scenario_recurring(pc):
    server = server_for(pc.dir)
    server.make_calendar("home", "Home")
    phone = Phone(server)
    series = vcal(vevent("weekly", "Planning", ";TZID=Europe/Rome:20261012T100000", ";TZID=Europe/Rome:20261012T110000",
                         "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10", "EXDATE;TZID=Europe/Rome:20261019T100000"),
                  "BEGIN:VEVENT\r\nUID:weekly\r\nDTSTAMP:20261101T000000Z\r\nRECURRENCE-ID;TZID=Europe/Rome:20261026T100000\r\n"
                  "DTSTART;TZID=Europe/Rome:20261026T140000\r\nDTEND;TZID=Europe/Rome:20261026T150000\r\nSUMMARY:Planning (later)\r\nEND:VEVENT\r\n", zones=ROME)
    phone.put("home", "weekly.ics", series)
    pc.add(server)
    pc.sync()
    group = pc.items("Home").get("weekly", [])
    check(len(group) == 2 and any(ncs.get(c, "RECURRENCE-ID") for c in group), "a series comes in with the time moved on its own")
    # On the phone: the moved time changed again. Here: the series' title.
    text = phone.all("home")["weekly"]
    phone.put("home", phone.name_of("home", "weekly"), text.replace("Planning (later)", "Planning (moved twice)").replace("20261026T140000", "20261026T160000"))
    pc.edit("Home", lambda cal: set_prop(cal, "weekly", "SUMMARY", "Team planning"))
    pc.sync()
    group = pc.items("Home")["weekly"]
    master = next(c for c in group if not ncs.get(c, "RECURRENCE-ID"))
    moved = next(c for c in group if ncs.get(c, "RECURRENCE-ID"))
    check(summary([master]) == "Team planning" and "EXDATE" in ncs.canon(master) and "RRULE:FREQ=WEEKLY" in ncs.canon(master), "the series keeps the title given here, its rule and what it left out")
    check(summary([moved]) == "Planning (moved twice)" and "20261026T160000" in ncs.canon(moved), "the time moved on its own takes the phone's change")
    on_phone = phone.all("home")["weekly"]
    check("Team planning" in on_phone and "Planning (moved twice)" in on_phone and on_phone.count("BEGIN:VEVENT") == 2, "and the server has both")
    # Here: another time moved on its own.
    pc.edit("Home", lambda cal: new_component(cal, "BEGIN:VEVENT\r\nUID:weekly\r\nRECURRENCE-ID;TZID=Europe/Rome:20261102T100000\r\nDTSTART;TZID=Europe/Rome:20261102T090000\r\n"
                                                    "DTEND;TZID=Europe/Rome:20261102T100000\r\nSUMMARY:Team planning (early)\r\nEND:VEVENT\r\n"))
    pc.sync()
    check(phone.all("home")["weekly"].count("BEGIN:VEVENT") == 3, "a time moved here reaches the server, in the same item")
    server.stop()


def scenario_stale(pc):
    server = server_for(pc.dir)
    server.make_calendar("home", "Home")
    phone = Phone(server)
    phone.put("home", "a.ics", vcal(vevent("a", "Before", ":20261110T100000Z", ":20261110T110000Z")))
    pc.add(server)
    pc.sync()
    old = ncs.read_file(pc.path("Home"))
    phone.put("home", phone.name_of("home", "a"), phone.all("home")["a"].replace("Before", "After"))
    pc.sync()
    # The shell writes from what it had read before the sync changed the file.
    with open(pc.path("Home"), "w", newline="") as f:
        f.write(old)
    pc.sync()
    check("After" in phone.all("home")["a"], "a file written from before the server's change does not undo it")
    check(summary(pc.items("Home")["a"]) == "After", "and the file has the change again")
    server.stop()


def scenario_readonly(pc):
    server = Fake()
    server.make_calendar("holidays", "Holidays", ("VEVENT",))
    Phone(server).put("holidays", "x.ics", vcal(vevent("xmas", "Christmas", ";VALUE=DATE:20261225", ";VALUE=DATE:20261226")))
    server.fake.calendars["holidays"].read_only = True
    pc.add(server)
    check(pc.calendar("Holidays")["readOnly"], "a calendar the user may not write is read-only")
    pc.sync()
    pc.edit("Holidays", lambda cal: set_prop(cal, "xmas", "SUMMARY", "Mine now"))
    pc.edit("Holidays", lambda cal: new_component(cal, vevent("new@nova", "New", ":20261110T100000Z", ":20261110T110000Z")))
    server.fake.log.clear()
    pc.sync()
    items = pc.items("Holidays")
    check(summary(items["xmas"]) == "Christmas" and "new@nova" not in items, "what was changed in it here goes back to the server's")
    check(not any(m in ("PUT", "DELETE") for m, _ in server.fake.log), "and nothing is sent")
    server.stop()


def scenario_google(pc):
    server = Fake(bearer="access-1")
    server.make_calendar("primary", "andre@example.org", ("VEVENT",), "#16A765")
    Phone(server, bearer="access-1").put("primary", "a.ics", vcal(vevent("a", "From Google", ":20261110T100000Z", ":20261110T110000Z")))
    os.makedirs(os.path.join(pc.dir, "nova", "calendar"))
    missing = pc.run("google")
    check(missing.returncode == 1, "without a client set up, Google sign-in says it is not")
    with open(os.path.join(pc.dir, "nova", "calendar", "google.json"), "w") as f:
        json.dump({"client_id": "nova-test.apps.googleusercontent.com", "client_secret": "not-secret"}, f)
    check(pc.run("google").returncode == 0, "with one, it is")
    server.fake.oauth = {"client_id": "nova-test.apps.googleusercontent.com", "code": "code-1", "refresh": "refresh-SECRET-1", "email": "andre@example.org"}
    # The browser: it opens the address, and Google's page (the fake's)
    # signs in at once and sends it back to this computer with a code.
    browser = os.path.join(pc.dir, "bin", "browser")
    with open(browser, "w") as f:
        f.write("#!%s\nimport sys, json, urllib.parse, urllib.request\nq = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(sys.argv[1]).query))\n"
                "open(%r, 'w').write(json.dumps(q))\nurllib.request.urlopen(sys.argv[1]).read()\n" % (sys.executable, os.path.join(pc.dir, "asked.json")))
    os.chmod(browser, 0o755)
    pc.env.update({"NOVA_CALENDAR_BROWSER": browser, "NOVA_CALENDAR_GOOGLE_AUTH": server.url + "auth", "NOVA_CALENDAR_GOOGLE_TOKEN": server.url + "token",
                   "NOVA_CALENDAR_GOOGLE_CALDAV": server.url})
    done = pc.run("add", request={"type": "google"})
    asked = json.load(open(os.path.join(pc.dir, "asked.json")))
    check(done.returncode == 0, "signing in to Google adds the account (%s)" % done.stderr.strip())
    check(asked.get("code_challenge_method") == "S256" and asked.get("redirect_uri", "").startswith("http://127.0.0.1:") and "calendar" in asked.get("scope", ""),
          "the sign-in is OAuth for an installed app: PKCE, the browser back to this computer, the calendar scope")
    check(asked.get("access_type") == "offline", "and asks for a token that lasts")
    exchange = server.fake.oauth["requests"][0]
    check(exchange.get("code_verifier") and exchange.get("client_secret") == "not-secret", "the code is exchanged with its verifier")
    config = pc.config()
    check(config["accounts"][0]["name"] == "andre@example.org" and config["accounts"][0]["type"] == "google", "the account is named by its address")
    secret = list(pc.secrets().values())[0]
    check("refresh-SECRET-1" in secret and "refresh-SECRET-1" not in json.dumps(config), "the tokens are in the keyring, not the list")
    pc.sync()
    check("a" in pc.items("andre@example.org"), "Google's calendar syncs with its token")
    # The token runs out: a new one, and on.
    server.fake.bearer = "access-2"
    server.fake.oauth["requests"].clear()
    Phone(server, bearer="access-2").put("primary", "b.ics", vcal(vevent("b", "Later", ":20261111T100000Z", ":20261111T110000Z")))
    pc.sync()
    check("b" in pc.items("andre@example.org") and server.fake.oauth["requests"][0]["grant_type"] == "refresh_token", "a refused token is renewed")
    server.fake.oauth["revoked"] = True
    server.fake.bearer = "access-3"
    pc.sync()
    status = pc.status()[config["accounts"][0]["id"]]
    check(status["state"] == "signin", "a token taken back asks to sign in again: %s" % status)
    server.stop()


def scenario_icloud(pc):
    server = Fake(user="me@icloud.com", password="abcd-efgh-ijkl-mnop")
    server.fake.home_host = "localhost"
    server.make_calendar("home", "Home")
    pc.env["NOVA_CALENDAR_ICLOUD"] = server.url
    bad = pc.run("add", request={"type": "icloud", "user": "me@icloud.com", "password": "wrong"})
    check(bad.returncode == 3 and "Apple ID" in bad.stderr, "iCloud's refusal names the Apple ID and the app-specific password")
    done = pc.run("add", request={"type": "icloud", "user": "me@icloud.com", "password": "abcd-efgh-ijkl-mnop"})
    check(done.returncode == 0 and pc.config()["accounts"][0]["name"] == "iCloud", "an iCloud account is added as iCloud")
    server.stop()


def scenario_subscription(pc):
    server = Fake()
    server.fake.feed = ('"f1"', vcal(vevent("h1", "Holiday", ";VALUE=DATE:20261208", ";VALUE=DATE:20261209"),
                                     vevent("m1", "Meeting", ";TZID=America/New_York:20261110T090000", ";TZID=America/New_York:20261110T100000"),
                                     "").replace("PRODID:-//Phone//EN", "PRODID:-//Phone//EN\r\nX-WR-CALNAME:Team"))
    check(ncs.normalize_url("webcal://example.org/a.ics", webcal=True) == "https://example.org/a.ics", "a webcal address is fetched over https")
    url = "http://127.0.0.1:%d/feed.ics?token=FEED-SECRET-9" % server.fake.port
    done = pc.run("subscribe", request={"url": url})
    check(done.returncode == 0, "subscribing runs (%s)" % done.stderr.strip())
    cal = pc.calendar("Team")
    check(cal["kind"] == "subscription" and cal["readOnly"] and not cal["tasks"], "a subscription is a read-only calendar, named as the feed names itself")
    text = ncs.read_file(pc.path("Team"))
    check("Holiday" in text and "TZID:America/New_York" in text and "BEGIN:VTIMEZONE" in text, "its events are in its file, with a zone the feed did not define")
    check("FEED-SECRET-9" not in open(os.path.join(pc.home, ".config/nova/calendars.json")).read(), "its address is not in the list")
    check(any("FEED-SECRET-9" in v for v in pc.secrets().values()), "it is in the keyring")
    server.fake.log.clear()
    pc.sync()
    check(("GET", "/feed.ics") in server.fake.log and ncs.read_file(pc.path("Team")) == text, "an unchanged feed is not read again (304)")
    bad = pc.run("subscribe", request={"url": "ftp://example.org/x.ics"})
    check(bad.returncode == 1, "an address that is not a web one is refused")
    check(pc.run("remove", cal["id"]).returncode == 0 and not os.path.exists(os.path.join(pc.home, ".local/share/nova/calendar", cal["file"])), "unsubscribing removes its file")
    server.stop()


def scenario_secrets(pc):
    server = server_for(pc.dir)
    server.make_calendar("home", "Home")
    pc.add(server)
    pc.sync()
    leaks = []
    for folder, _, files in os.walk(pc.home):
        for name in files:
            if server.password in open(os.path.join(folder, name), errors="replace").read():
                leaks.append(name)
    check(not leaks, "the password is in no file of the home: %s" % leaks)
    server.stop()


def scenario_zones(pc):
    def parts(tz):
        return {c.name: ncs.canon(c) for c in tz.children}
    rome = ncs.vtimezone("Europe/Rome")
    p = parts(rome)
    check("RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU" in p["DAYLIGHT"] and "TZOFFSETTO:+0200" in p["DAYLIGHT"] and "DTSTART:19700329T020000" in p["DAYLIGHT"],
          "Rome's summer time: the last Sunday of March, at two")
    check("RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU" in p["STANDARD"] and "DTSTART:19701025T030000" in p["STANDARD"], "and its end: the last Sunday of October, at three")
    ny = parts(ncs.vtimezone("America/New_York"))
    check("BYMONTH=3;BYDAY=2SU" in ny["DAYLIGHT"] and "BYMONTH=11;BYDAY=1SU" in ny["STANDARD"] and "TZOFFSETFROM:-0500" in ny["DAYLIGHT"], "New York's, on the second and first Sundays")
    kolkata = parts(ncs.vtimezone("Asia/Kolkata"))
    check(list(kolkata) == ["STANDARD"] and "TZOFFSETTO:+0530" in kolkata["STANDARD"], "a zone with no summer time has one part")
    nuuk = ncs.vtimezone("America/Nuuk")
    check(nuuk is not None and "RDATE" in serialize_text(nuuk), "a rule a yearly RRULE cannot say is written as its changes")
    check(ncs.vtimezone("Nowhere/Known") is None and ncs.vtimezone("../etc/passwd") is None, "no zone for a name that is none")


def scenario_keyring(pc):
    server = Fake()
    server.make_calendar("home", "Home")
    Phone(server).put("home", "a.ics", vcal(vevent("a", "A", ":20261110T100000Z", ":20261110T110000Z")))
    pc.add(server)
    account = pc.config()["accounts"][0]["id"]

    def lookup():
        return subprocess.run(["secret-tool", "lookup", "service", "nova-calendar", "id", account], capture_output=True, text=True, env=pc.env).stdout

    check(lookup() == server.password, "the password is in the login keyring, as it was typed")
    pc.sync()
    check("a" in pc.items("Home") and pc.status()[account]["state"] == "ok", "and read from it to sync")
    pc.run("remove", account)
    check(lookup() == "", "removing the account takes it out of the keyring")
    server.stop()


def serialize_text(c):
    return ncs.serialize([c])


def main():
    pc = Computer()
    try:
        globals()["scenario_" + SCENARIO.replace("-", "_")](pc)
    finally:
        shutil.rmtree(pc.dir, ignore_errors=True)
    print("DONE")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
