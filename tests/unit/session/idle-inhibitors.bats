#!/usr/bin/env bats

# data/session/bin/nova-idle-inhibitors on a D-Bus session of its own: an app's
# Inhibit through org.freedesktop.ScreenSaver is listed for the shell's idle
# service until it is let go, or until the app leaves the bus.

load ../test_helper

setup() {
  setup_scratch
  python3 -c 'import dbus, gi' 2>/dev/null || skip "needs python-dbus and python-gobject"
  command -v dbus-run-session >/dev/null || skip "needs dbus-run-session"
  export XDG_RUNTIME_DIR=$SCRATCH/run
  mkdir -m 700 "$XDG_RUNTIME_DIR"
  # The shell is not running here: its refresh is only counted.
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/sh\necho "$*" >>"%s/refreshes"\n' "$SCRATCH" >"$SCRATCH/bin/nova-shell"
  chmod +x "$SCRATCH/bin/nova-shell"
  export PATH=$SCRATCH/bin:$PATH
  cat >"$SCRATCH/app.py" <<'PY'
import os, sys, time, dbus
bus = dbus.SessionBus()
for _ in range(100):
    if bus.name_has_owner("org.freedesktop.ScreenSaver"):
        break
    time.sleep(0.05)
saver = dbus.Interface(bus.get_object("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver"),
                       "org.freedesktop.ScreenSaver")
held = os.path.join(os.environ["XDG_RUNTIME_DIR"], "nova", "idle-inhibitors")
def listed():
    time.sleep(0.3)
    return open(held).read() if os.path.exists(held) else ""
cookie = saver.Inhibit("Films", "Playing\tvideo\n")
print("held:", repr(listed()))
other = dbus.Interface(dbus.SessionBus(private=True).get_object(
    "org.freedesktop.ScreenSaver", "/ScreenSaver"), "org.freedesktop.ScreenSaver")
other.UnInhibit(cookie)
print("after a stranger's UnInhibit:", repr(listed()))
saver.UnInhibit(cookie)
print("let go:", repr(listed()))
if sys.argv[1:] == ["leave"]:
    saver.Inhibit("Call", "")
    print("held again:", repr(listed()), flush=True)
    os._exit(0)
PY
}

teardown() { teardown_scratch; }

# The service, the app, and what the file holds once the app has gone.
run_session() { # [leave]
  dbus-run-session -- bash -c '
    "$1" & service=$!
    python3 -I "$2" "$3"
    sleep 0.5
    echo "at the end: $(cat "$XDG_RUNTIME_DIR/nova/idle-inhibitors" 2>/dev/null)"
    kill "$service"; wait "$service"' _ "$REPO_ROOT/data/session/bin/nova-idle-inhibitors" "$SCRATCH/app.py" "${1:-}"
}

@test "an Inhibit is listed, as one plain line, until the app that asked lets go" {
  run run_session
  [ "$status" -eq 0 ]
  [[ $output == *"held: 'Films\\tPlaying video\\n'"* ]]
  [[ $output == *"after a stranger's UnInhibit: 'Films\\tPlaying video\\n'"* ]]
  [[ $output == *"let go: ''"* ]]
  [[ $output == *"at the end: "$'\n'* || $output == *"at the end: " ]]
  grep -qx -- '-q idle refresh' "$SCRATCH/refreshes"
}

@test "an app that leaves the bus lets go of what it held" {
  run run_session leave
  [ "$status" -eq 0 ]
  [[ $output == *"held again: 'Call\\t\\n'"* ]]
  [[ $output == *"left the bus"* ]]
  [ ! -e "$XDG_RUNTIME_DIR/nova/idle-inhibitors" ]
}
