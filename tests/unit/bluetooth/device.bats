#!/usr/bin/env bats

# nova-bluetooth-device, from the Bluetooth panel: a pairing or a connection
# that fails says so in a notification, since nobody reads its stderr.
# bluetoothctl, systemctl and the notification are stubs that log.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" STATE="$SCRATCH/state" NOVA_BLUETOOTH_POLL=0
  mkdir -p "$SCRATCH/bin"
  : >"$STATE"
  # Powered and pairable; pair answers with $PAIR, connect with $CONNECT, and
  # info reports the link once a connect succeeded.
  cat >"$SCRATCH/bin/bluetoothctl" <<'STUB'
#!/bin/bash
echo "bluetoothctl $*" >>"$CALLS"
case $1 in
  show) printf 'Powered: yes\nPairable: yes\n' ;;
  pair) echo "${PAIR_OUT:-}"; exit "${PAIR:-0}" ;;
  connect) [[ ${CONNECT:-0} != 0 ]] || echo connected >"$STATE"; exit "${CONNECT:-0}" ;;
  info) printf '\tAlias: HD 450SE\n\tConnected: %s\n' "$(grep -q connected "$STATE" && echo yes || echo no)" ;;
esac
STUB
  printf '#!/bin/bash\necho "systemctl $*" >>"$CALLS"\n' >"$SCRATCH/bin/systemctl"
  printf '#!/bin/bash\necho "notify $*" >>"$CALLS"\n' >"$SCRATCH/bin/nova-notification-send"
  chmod +x "$SCRATCH"/bin/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

device() { "$REPO_ROOT/src/cli/bin/nova-bluetooth-device" "$@" 00:1B:66:AA:BB:CC; }

@test "a pairing that works pairs, connects and says nothing" {
  run device pair
  [ "$status" -eq 0 ]
  grep -qx 'bluetoothctl connect 00:1B:66:AA:BB:CC' "$CALLS"
  fails grep -q '^notify' "$CALLS"
  grep -qx 'systemctl --user stop bt-agent.service' "$CALLS"
}

@test "a refused pairing is named, and nothing is connected after it" {
  PAIR=1 PAIR_OUT='Failed to pair: org.bluez.Error.AuthenticationFailed' run device pair
  [ "$status" -eq 1 ]
  grep -q '^notify .*Could not pair with HD 450SE' "$CALLS"
  grep -q 'PIN' "$CALLS"
  fails grep -q 'bluetoothctl connect' "$CALLS"
  # The agent that says yes to any device stops with the attempt.
  grep -qx 'systemctl --user stop bt-agent.service' "$CALLS"
}

@test "a device paired already is connected, not reported" {
  PAIR=1 PAIR_OUT='Failed to pair: org.bluez.Error.AlreadyExists' run device pair
  [ "$status" -eq 0 ]
  fails grep -q '^notify' "$CALLS"
}

@test "a connection that does not come up is named" {
  CONNECT=1 run device connect
  [ "$status" -eq 1 ]
  grep -q '^notify .*Could not connect to HD 450SE' "$CALLS"
}
