# Files, as nova-previewer sees it: calls what Nautilus 51 calls and says
# "ok" or "FAIL" for each thing it checks. Run by front.bats on a bus of its
# own, with a fake nova-shell that logs its arguments to $SHELL_LOG, one call
# to a line, a tab after each; with SHELL_FAILS in the environment it exits
# 1, as a shell that is not running does.
#
#   client.py <scratch dir>
import json
import os
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NAME = "org.gnome.NautilusPreviewer"
PATH = "/org/gnome/NautilusPreviewer"
PREVIEWER = "org.gnome.NautilusPreviewer2"
OURS = "org.nova.Previewer"

scratch = sys.argv[1]
log = os.environ["SHELL_LOG"]
events = []
changes = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)


bus = Gio.bus_get_sync(Gio.BusType.SESSION)
bus.signal_subscribe(NAME, PREVIEWER, "SelectionEvent", PATH, None, 0,
                     lambda *a: events.append(a[5].unpack()[0]))
bus.signal_subscribe(NAME, "org.freedesktop.DBus.Properties", "PropertiesChanged", PATH, None, 0,
                     lambda *a: changes.append(a[5].unpack()[1]))


def pump(seconds=0.4):
    end = time.time() + seconds
    context = GLib.MainContext.default()
    while time.time() < end:
        while context.iteration(False):
            pass
        time.sleep(0.02)


def call(interface, method, signature, *args):
    return bus.call_sync(NAME, PATH, interface, method,
                         GLib.Variant(signature, args) if signature else None,
                         None, Gio.DBusCallFlags.NONE, 5000, None)


def visible():
    reply = call("org.freedesktop.DBus.Properties", "Get", "(ss)", PREVIEWER, "Visible")
    return reply.unpack()[0]


def shell_calls():
    if not os.path.exists(log):
        return []
    with open(log) as lines:
        return [line.rstrip("\n").split("\t")[:-1] for line in lines]


def show(path, close_if_shown=False):
    call(PREVIEWER, "ShowFile", "(ssbs)", "file://" + path, "x11:1", close_if_shown, "token")
    pump()


text = os.path.join(scratch, "notes.txt")
folder = os.path.join(scratch, "stuff")
os.makedirs(folder)
for name in ("a", "b", ".hidden"):
    open(os.path.join(folder, name), "w").close()
with open(text, "w") as f:
    f.write("one\ntwo\n")

# The first Space: activated by the call, the shell is handed the file.
check(visible() is False, "nothing is shown before the first ShowFile")
show(text)
check(visible() is True, "Visible is true once a file is shown")
calls = shell_calls()
check(len(calls) == 1 and calls[0][:3] == ["shell", "summon", "nova.preview"], "the shell is asked to summon the preview, once")
info = json.loads(calls[0][3]) if calls else {}
check(info.get("path") == text and info.get("name") == "notes.txt" and info.get("kind") == "text"
      and info.get("mime") == "text/plain" and info.get("uri") == "file://" + text
      and info.get("size") == 8 and info.get("seq") == 1, "the file is described: path, name, kind, type, size")
check({"Visible": True} == {k: v for c in changes for k, v in c.items() if k == "Visible"}, "Visible's change is announced")
reply = call("org.freedesktop.DBus.Properties", "Get", "(ss)", PREVIEWER, "ParentHandle")
check(reply.unpack()[0] == "x11:1", "ParentHandle is the window handle given")

# Another file replaces it in place: no hide, a new request.
show(folder)
calls = shell_calls()
info = json.loads(calls[-1][3])
check(len(calls) == 2 and calls[1][1] == "summon" and info["kind"] == "folder" and info["items"] == 2
      and info["seq"] == 2, "a second file is summoned in place, a folder with its visible items counted")

# Files moves its selection when the window sends a direction.
call(OURS, "Select", "(u)", 5)
pump()
check(events == [5], "Select becomes SelectionEvent with the direction")

# A window that was replaced and reports it closed is not the one shown.
call(OURS, "Closed", "(u)", 1)
check(visible() is True, "a Closed for an older file changes nothing")

# The same file again, with close-if-shown: the window is closed.
show(folder, True)
calls = shell_calls()
check(calls[-1][:3] == ["shell", "hide", "nova.preview"] and visible() is False,
      "the same file again with close-if-shown hides it")

# The same file again without it, once it is shown: nothing more is asked.
show(text)
before = len(shell_calls())
show(text)
check(len(shell_calls()) == before and visible() is True, "the file already shown is not summoned again")

# The window closed by a key: Closed with the file's own number.
call(OURS, "Closed", "(u)", json.loads(shell_calls()[-1][3])["seq"])
check(visible() is False, "Closed for the file shown ends the preview")

# Close() from Files.
show(text)
call(PREVIEWER, "Close", None)
pump()
check(shell_calls()[-1][1] == "hide" and visible() is False, "Close hides the window")

# A file that is not there still gets a page with its name.
show(os.path.join(scratch, "gone.bin"))
info = json.loads(shell_calls()[-1][3])
check(info["name"] == "gone.bin" and info["kind"] == "other", "a file that is gone is described by its name")
call(OURS, "Closed", "(u)", info["seq"])

# It quits when idle: its name leaves the bus a moment after the preview is
# closed.
deadline = time.time() + 8
owned = True
while time.time() < deadline and owned:
    pump(0.3)
    owned = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                          "NameHasOwner", GLib.Variant("(s)", (NAME,)), None, Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]
check(not owned, "it quits when the preview has been closed for a while")
print("DONE")
