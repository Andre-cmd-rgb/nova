#!/usr/bin/env bats

# nova-bluetooth-device, from the Bluetooth panel: a pairing or a connection
# that fails says so in a notification, since nobody reads its stderr.
# bluetoothctl and the notification are stubs that log; the switch that has
# nova-sessiond's agent ask the pairing's questions is in a scratch runtime
# folder.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" STATE="$SCRATCH/state" NOVA_BLUETOOTH_POLL=0
  export XDG_RUNTIME_DIR="$SCRATCH/run" HYPRLAND_INSTANCE_SIGNATURE=test-session
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR"
  : >"$STATE"
  # Powered and pairable; pair answers with $PAIR, connect with $CONNECT, and
  # info reports the link once a connect succeeded.
  cat >"$SCRATCH/bin/bluetoothctl" <<'STUB'
#!/bin/bash
echo "bluetoothctl $*" >>"$CALLS"
case $1 in
  show) printf 'Powered: yes\nPairable: yes\n' ;;
  pair)
    # What the agent is told while bluetoothctl pairs.
    cat "$XDG_RUNTIME_DIR/nova/bluetooth-pairing" >"$SCRATCH/switch" 2>/dev/null || true
    echo "${PAIR_OUT:-}"
    exit "${PAIR:-0}"
    ;;
  connect) [[ ${CONNECT:-0} != 0 ]] || echo connected >"$STATE"; exit "${CONNECT:-0}" ;;
  info) printf '\tAlias: HD 450SE\n\tConnected: %s\n' "$(grep -q connected "$STATE" && echo yes || echo no)" ;;
esac
STUB
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
  # The agent was told this session and this device while it paired, and
  # is told no more once it is done.
  [ "$(cat "$SCRATCH/switch")" = "$(printf 'test-session\n00:1B:66:AA:BB:CC')" ]
  [ ! -e "$XDG_RUNTIME_DIR/nova/bluetooth-pairing" ]
}

@test "a refused pairing is named, and nothing is connected after it" {
  PAIR=1 PAIR_OUT='Failed to pair: org.bluez.Error.AuthenticationFailed' run device pair
  [ "$status" -eq 1 ]
  grep -q '^notify .*Could not pair with HD 450SE' "$CALLS"
  grep -q 'pairing mode' "$CALLS"
  fails grep -q 'bluetoothctl connect' "$CALLS"
  # The agent stops asking with the attempt.
  [ ! -e "$XDG_RUNTIME_DIR/nova/bluetooth-pairing" ]
}

@test "a pairing turned down on the card says nothing more" {
  for why in AuthenticationRejected AuthenticationCanceled; do
    : >"$CALLS"
    PAIR=1 PAIR_OUT="Failed to pair: org.bluez.Error.$why" run device pair
    [ "$status" -eq 1 ]
    fails grep -q '^notify' "$CALLS"
    fails grep -q 'bluetoothctl connect' "$CALLS"
  done
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

@test "disconnect drops the link; forget drops it and removes the device" {
  device disconnect
  [ "$(cat "$CALLS")" = 'bluetoothctl disconnect 00:1B:66:AA:BB:CC' ]
  : >"$CALLS"
  device forget
  [ "$(grep -v show "$CALLS")" = $'bluetoothctl disconnect 00:1B:66:AA:BB:CC\nbluetoothctl remove 00:1B:66:AA:BB:CC' ]
}

@test "anything but an action and an address is refused" {
  run "$REPO_ROOT/src/cli/bin/nova-bluetooth-device" connect not-an-address
  [ "$status" -eq 1 ]
  run "$REPO_ROOT/src/cli/bin/nova-bluetooth-device" rename 00:1B:66:AA:BB:CC
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS" ]
}
