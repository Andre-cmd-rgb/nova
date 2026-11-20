#!/usr/bin/env bats

# nova-iphone-notifications, the whole service on a D-Bus session of its own,
# against a fake BlueZ with a fake iPhone behind it and a fake notification
# server (fake_bluez.py, which prints "ok"/"FAIL" for each check). Nothing
# here reaches the computer's Bluetooth: the service is told that BlueZ is on
# the private session bus. Its ANCS byte for byte, and the rest of what can
# be tried without a bus, are its Rust tests (cargo test).

load ../test_helper

# Each scenario has a bus, a scratch and a service of its own, and spends its
# seconds waiting on the service's timers, not working: one after another they
# took 94 s, the longest file of `make test` by far, which runs a file's tests
# in a row (the Makefile says why). These go side by side, as many as
# --jobs allows. The service is built once for them, as `cargo test` builds
# only its tests.
setup_file() {
  unset BATS_NO_PARALLELIZE_WITHIN_FILE
  if command -v cargo >/dev/null; then
    (cd "$REPO_ROOT" && cargo build --quiet --package nova-iphone-notifications)
  fi
}

setup() {
  setup_scratch
  python3 -c 'import dbus, gi' 2>/dev/null || skip "the fake BlueZ needs python-dbus and python-gobject"
  DAEMON=${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/nova-iphone-notifications
  [[ -x $DAEMON ]] || skip "needs cargo, to build nova-iphone-notifications"
  UNIT=$REPO_ROOT/src/iphone/nova-iphone-notifications.service
}

teardown() { teardown_scratch; }

scenario() { # name
  command -v dbus-run-session >/dev/null || skip "needs dbus-run-session"
  run dbus-run-session -- python3 -B -I "$BATS_TEST_DIRNAME/fake_bluez.py" "$1" "$DAEMON" "$SCRATCH" "$UNIT"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *DONE* ]]
  [[ $output != *FAIL* ]]
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

@test "a toast dismissed while its change is on the way stays dismissed, and is cleared on the iPhone" {
  scenario changing
}

@test "after a link back, old ones that only look new do not use up the few that came in the gap" {
  scenario evicted
}

@test "BlueZ restarting while a pairing is asked about: the question withdrawn, and the BlueZ back asked anew" {
  scenario asking
  [[ $output == *"pairing question withdrawn: BlueZ restarted"* ]]
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

@test "it never logs what a notification says" {
  # The texts go to the shell alone.
  # A whole log statement, up to its semicolon, as rustfmt may spread one
  # over several lines.
  run grep -lPz 'log\([^;]*(summary|body|title|subtitle|info\.|found)' "$REPO_ROOT"/src/iphone/daemon/src/*.rs
  [ "$status" -eq 1 ]
}
