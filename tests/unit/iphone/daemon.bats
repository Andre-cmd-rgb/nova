#!/usr/bin/env bats

# nova-iphone-notifications, its ANCS byte for byte (ancs_test.py), and the
# whole service on a D-Bus session of its own, against a fake BlueZ with a
# fake iPhone behind it and a fake notification server (fake_bluez.py, which
# prints "ok"/"FAIL" for each check). Nothing here reaches the computer's
# Bluetooth: the service is told that BlueZ is on the private session bus.

load ../test_helper

setup() {
  setup_scratch
  python3 -c 'import dbus, gi' 2>/dev/null || skip "needs python-dbus and python-gobject"
  DAEMON=$REPO_ROOT/src/iphone/nova-iphone-notifications
}

teardown() { teardown_scratch; }

scenario() { # name
  command -v dbus-run-session >/dev/null || skip "needs dbus-run-session"
  run dbus-run-session -- python3 -B -I "$BATS_TEST_DIRNAME/fake_bluez.py" "$1" "$DAEMON" "$SCRATCH"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *DONE* ]]
  [[ $output != *FAIL* ]]
}

@test "ANCS: events, commands and answers, byte for byte as the specification has them" {
  run python3 -B -I "$BATS_TEST_DIRNAME/ancs_test.py" "$DAEMON"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *OK* ]]
}

@test "pairing: a window on request, the code compared in a notification, then advertising for the iPhone to come back" {
  scenario pairing
  [[ $output == *'"Discoverable": true, "LocalName": "Test Laptop"'* ]]
  [[ $output == *"agent unregistered"* ]]
}

@test "pairing turned down: not paired, not asked again on the same link, the window still open" {
  scenario declined
  [[ $output == *"pairing: refused, org.bluez.Error.Rejected"* ]]
}

@test "pairing asked of it by others: no agent outside the window, an agent BlueZ would not make the default unregistered, no Just Works, BlueZ alone answered, one question at a time, a name as plain text" {
  scenario strangers
  [[ $output == *"agent not made the default"*"agent unregistered"* ]]
  [[ $output == *"turned down a pairing with no code to compare"* ]]
  [[ $output == *"turned down a second pairing while one is asked about"* ]]
}

@test "a toast from before a drop, dismissed, clears nothing on the iPhone, which has given its uid to another" {
  scenario reused
}

@test "an iPhone that keeps to no limit: texts cut and cleaned, an answer too long given up on, a flood followed to fifty" {
  scenario hostile
  [[ $output == *"an answer that does not fit: an answer of more than 8192 bytes"* ]]
  [ "$(grep -c "more than 50 notifications at once" <<<"$output")" -eq 1 ]
}

@test "an answer of the BlueZ before a restart, come late, counts for nothing" {
  scenario late
}

@test "its name taken: it ends with 3, which its unit does not restart" {
  scenario taken
}

@test "notifications: new ones shown with their app, calls and old ones left out, removed and cleared both ways" {
  scenario notifications
  [[ $output == *"write: 02 05 00 00 00 01"* ]]
}

@test "a link back after a blip: what came in the gap is shown, nothing older" {
  scenario reconnect
}

@test "BlueZ restarting, the controller resetting, Bluetooth off and LE off: it advertises again, or says why not" {
  scenario restarts
}

@test "it is Python with what Nova depends on, and never logs what a notification says" {
  run grep -nE '^(import|from) ' "$DAEMON"
  [[ $output != *requests* && $output != *bleak* ]]
  # The texts go to the shell alone.
  run grep -nE 'log\(f?".*\{[^}]*(summary|body|title|subtitle|info|found)' "$DAEMON"
  [ "$status" -eq 1 ]
}
