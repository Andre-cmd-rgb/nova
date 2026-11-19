#!/usr/bin/env bats

# nova-calendar-sync, the Calendar's two-way sync, against a CalDAV server on
# 127.0.0.1 (sync_test.py prints "ok"/"FAIL" for each check): the fake one,
# fake_caldav.py, or Radicale where NOVA_TEST_RADICALE=1 and radicale is on
# PATH (`pip install radicale` in a venv will do). No test reaches a real
# server, or the computer's keyring: secret-tool is a stub that keeps the
# secrets in a scratch file.

load ../test_helper

setup_file() {
  unset BATS_NO_PARALLELIZE_WITHIN_FILE
}

setup() {
  setup_scratch
  SYNC=$REPO_ROOT/src/calendar/nova-calendar-sync
}

teardown() { teardown_scratch; }

scenario() { # name [fake]
  local server=fake
  [[ ${NOVA_TEST_RADICALE:-} != 1 || ${2:-} == fake ]] || server=radicale
  run python3 -B -I "$BATS_TEST_DIRNAME/sync_test.py" "$1" "$SYNC" "$server"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *DONE* ]]
  [[ $output != *FAIL* ]]
}

@test "discovery: the principal, the calendar home, its calendars; set and remove" { scenario discovery; }
@test "two-way: made, changed, moved and deleted here and on the phone" { scenario two-way; }
@test "a server without sync-collection: its ctag and ETags, and no ETag after a write" { scenario fallback fake; }
@test "changed on both sides: merged, or both kept; deleted on one side and changed on the other" { scenario conflict; }
@test "offline: the edits wait in the file, and are sent when the server is back" { scenario offline; }
@test "a series with a time moved on its own, changed on each side" { scenario recurring; }
@test "a file written from before the server's change does not undo it" { scenario stale; }
@test "a read-only calendar: nothing sent, the server's version kept" { scenario readonly fake; }
@test "Google: OAuth for an installed app, a token renewed, one taken back" { scenario google fake; }
@test "iCloud: its own words for a refused password, and its partitions as its own server" { scenario icloud fake; }
@test "a subscription: read-only, its address in the keyring, a 304 when unchanged" { scenario subscription fake; }
@test "the password is in no file" { scenario secrets; }
@test "time zones a file names without their VTIMEZONE, from the zone database" { scenario zones fake; }
@test "the password goes to the account's own server only: no home, calendar, redirect or feed elsewhere has it" { scenario foreign fake; }
@test "a file gone, emptied or mostly emptied deletes nothing on the server; an item with no UID is given one" { scenario guard; }
@test "a calendar the server leaves out of its listing stays while it has changes not sent; no list, nothing deleted" { scenario listing fake; }
@test "an item a calendar-multiget leaves out is asked for again; only a 404 deletes it" { scenario multiget fake; }
@test "an account removed while it syncs stays removed; a file deleted while it is merged stays deleted" { scenario remove fake; }
@test "a server sending a byte at a time is stopped at the time limit" { scenario slow fake; }

@test "the login keyring itself: a gnome-keyring of a scratch home, on a D-Bus session of its own" {
  command -v gnome-keyring-daemon >/dev/null && command -v secret-tool >/dev/null && command -v dbus-run-session >/dev/null ||
    skip "needs gnome-keyring, secret-tool and dbus-run-session"
  mkdir -p "$SCRATCH/keyring-home"
  run env HOME="$SCRATCH/keyring-home" dbus-run-session -- bash -c \
    'eval "$(printf "scratch\n" | gnome-keyring-daemon --unlock --components=secrets)"; python3 -B -I "$1" keyring "$2" fake' \
    _ "$BATS_TEST_DIRNAME/sync_test.py" "$SYNC"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *DONE* ]]
  [[ $output != *FAIL* ]]
}
