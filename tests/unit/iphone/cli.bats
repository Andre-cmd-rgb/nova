#!/usr/bin/env bats

# `nova notification iphone`: on enables the user service and opens the
# pairing window when no iPhone is paired yet; off disables it; pair asks
# the running service; the buttons' answer goes to it; and the state file
# the service writes becomes one plain line, or JSON. systemctl and busctl
# are stubs that log.

load ../test_helper

cli="$REPO_ROOT/src/iphone/bin/nova-notification-iphone"

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR/nova"
  # is-active answers as $SCRATCH/active says.
  cat >"$SCRATCH/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$CALLS"
[[ $* == *is-active* ]] && { [[ -e $SCRATCH/active ]]; exit; }
exit 0
EOF
  printf '#!/bin/bash\necho "busctl $*" >>"$CALLS"\necho "b true"\n' >"$SCRATCH/bin/busctl"
  chmod +x "$SCRATCH/bin/systemctl" "$SCRATCH/bin/busctl"
  export PATH="$SCRATCH/bin:$PATH"
  STATE=$XDG_RUNTIME_DIR/nova/iphone-notifications.json
}

teardown() { teardown_scratch; }

state() { touch "$SCRATCH/active"; printf '%s\n' "$1" >"$STATE"; }

@test "on: the service enabled and started for this user, then the pairing window if no iPhone is paired" {
  state '{"state":"pairing","name":"Nova","pairingUntil":0,"phones":[]}'
  run "$cli" on
  [ "$status" -eq 0 ]
  grep -qx "systemctl --user enable --now nova-iphone-notifications.service" "$CALLS"
  grep -qx "busctl --user --timeout=10 call org.nova.iPhoneNotifications /org/nova/iPhoneNotifications org.nova.iPhoneNotifications Pair b true" "$CALLS"
  [[ $output == "Pairing: on your iPhone, open Settings → Bluetooth and tap “Nova”. 0 s left." ]]
}

@test "off: disabled and stopped" {
  run "$cli" off
  [ "$status" -eq 0 ]
  grep -qx "systemctl --user disable --now nova-iphone-notifications.service" "$CALLS"
  [[ $output == "iPhone notifications are off. Turn them on with: nova notification iphone on" ]]
}

@test "pair: asks the running service, and says what to do when it is off" {
  run "$cli" pair
  [ "$status" -eq 1 ]
  [[ $output == *"Turn them on with: nova notification iphone on"* ]]
  [[ ! -e $CALLS ]] || ! grep -q busctl "$CALLS"
  state '{"state":"pairing","name":"Nova","pairingUntil":0}'
  run "$cli" pair
  [ "$status" -eq 0 ]
  grep -q "Pair b false" "$CALLS"
}

@test "answer: the pairing notification's buttons, and nothing printed" {
  run "$cli" answer yes
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$cli" answer no
  grep -q "Answer b true" "$CALLS"
  grep -q "Answer b false" "$CALLS"
}

@test "each state in a plain line" {
  state '{"state":"connected","name":"Nova","phones":[{"name":"Anna’s iPhone","connected":true}]}'
  run "$cli"
  [[ $output == "Anna’s iPhone is connected: its notifications show here." ]]
  state '{"state":"waiting","name":"Nova","phones":[{"name":"Anna’s iPhone","connected":false}]}'
  run "$cli"
  [[ $output == "Anna’s iPhone is not connected. It connects by itself when it is near, with Bluetooth on." ]]
  state '{"state":"not-shared","name":"Nova","phones":[{"name":"Anna’s iPhone"}]}'
  run "$cli"
  [[ $output == *"Settings → Bluetooth → ⓘ beside “Nova” → Share System Notifications."* ]]
  state '{"state":"no-le","name":"Nova","phones":[]}'
  run "$cli"
  [[ $output == "iPhone notifications need Bluetooth Low Energy: nova bluetooth le on" ]]
  state '{"state":"no-iphone","name":"Nova","phones":[]}'
  run "$cli"
  [[ $output == "No iPhone is paired. Pair one with: nova notification iphone pair" ]]
}

@test "--json: the service's state, or off, or starting before it has written one" {
  run "$cli" --json
  [[ $output == '{"state":"off"}' ]]
  touch "$SCRATCH/active"
  run "$cli" --json
  [[ $output == '{"state":"starting"}' ]]
  state '{"state":"connected", "phones":[]}'
  run "$cli" --json
  [[ $output == '{"state":"connected","phones":[]}' ]]
}

@test "anything else is the usage" {
  run "$cli" sideways
  [ "$status" -eq 2 ]
  [[ $output == *"Usage: nova notification iphone"* ]]
}
