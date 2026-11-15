#!/usr/bin/env bats

# `nova bluetooth le`: ControllerMode set in main.conf's [General], in place of
# BlueZ's own commented line, the rest of the file as it was, and bluetoothd
# restarted only when the mode changed. systemctl is a stub that logs.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_BLUETOOTH_CONF="$SCRATCH/main.conf"
  export NOVA_BLUETOOTH_LE_APPLY="$REPO_ROOT/data/bluetooth/nova-bluetooth-le-apply"
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/bash\necho "systemctl $*" >>"$CALLS"\n' >"$SCRATCH/bin/systemctl"
  # The CLI goes through pkexec, which here just runs the helper.
  printf '#!/bin/bash\nexec "$@"\n' >"$SCRATCH/bin/pkexec"
  chmod +x "$SCRATCH/bin/systemctl" "$SCRATCH/bin/pkexec"
  export PATH="$SCRATCH/bin:$PATH"
  # As BlueZ ships it, shortened: every setting commented out.
  cat >"$NOVA_BLUETOOTH_CONF" <<'EOF'
[General]

# Default device class.
#Class = 0x000100

# Restricts all controllers to the specified transport. Default value
# is "dual", i.e. both BR/EDR and LE enabled (when supported by the HW).
# Possible values: "dual", "bredr", "le"
#ControllerMode = dual

#MaxControllers=0

[BR]
#PageScanType=

[LE]
#MinAdvertisementInterval=
EOF
  chmod 644 "$NOVA_BLUETOOTH_CONF"
  cp "$NOVA_BLUETOOTH_CONF" "$SCRATCH/stock"
}

teardown() { teardown_scratch; }

apply="$REPO_ROOT/data/bluetooth/nova-bluetooth-le-apply"
cli="$REPO_ROOT/data/bluetooth/nova-bluetooth-le"

@test "off: classic only, in place of BlueZ's own line, and Bluetooth restarted" {
  run "$apply" off
  [ "$status" -eq 0 ]
  [ "$(diff "$SCRATCH/stock" "$NOVA_BLUETOOTH_CONF" | grep '^[<>]')" = "$(printf '< #ControllerMode = dual\n> ControllerMode = bredr')" ]
  grep -qx 'systemctl try-restart bluetooth.service' "$CALLS"
  [ "$(stat -c %a "$NOVA_BLUETOOTH_CONF")" = 644 ]
  [ "$("$apply" status)" = off ]
}

@test "on: back to dual, and a mode already set restarts nothing" {
  "$apply" off
  rm -f "$CALLS"
  "$apply" off
  [ ! -e "$CALLS" ]
  "$apply" on
  grep -qx 'ControllerMode = dual' "$NOVA_BLUETOOTH_CONF"
  [ "$(grep -c '^ControllerMode' "$NOVA_BLUETOOTH_CONF")" -eq 1 ]
  [ "$("$apply" status)" = on ]
}

@test "stock main.conf, and none at all, are on" {
  [ "$("$apply" status)" = on ]
  rm "$NOVA_BLUETOOTH_CONF"
  [ "$("$apply" status)" = on ]
  run "$apply" off
  [ "$status" -ne 0 ]
  [[ $output == *"no $NOVA_BLUETOOTH_CONF"* ]]
}

@test "a [General] without the line gets it, before the next section" {
  printf '[General]\nName = nova\n\n[LE]\nControllerMode = le\n' >"$NOVA_BLUETOOTH_CONF"
  "$apply" off
  [ "$(cat "$NOVA_BLUETOOTH_CONF")" = "$(printf '[General]\nName = nova\n\nControllerMode = bredr\n[LE]\nControllerMode = le')" ]
}

@test "no [General] at all: one at the end; two lines set: one left" {
  printf '[Policy]\nAutoEnable=true\n' >"$NOVA_BLUETOOTH_CONF"
  "$apply" off
  [ "$(cat "$NOVA_BLUETOOTH_CONF")" = "$(printf '[Policy]\nAutoEnable=true\n\n[General]\nControllerMode = bredr')" ]
  printf '[General]\nControllerMode = le\nControllerMode = dual # twice\n' >"$NOVA_BLUETOOTH_CONF"
  [ "$("$apply" status)" = on ]
  "$apply" off
  [ "$(cat "$NOVA_BLUETOOTH_CONF")" = "$(printf '[General]\nControllerMode = bredr')" ]
}

@test "anything but on, off or status is refused, and nothing changes" {
  run "$apply" "bredr; rm -rf /"
  [ "$status" -eq 2 ]
  cmp -s "$SCRATCH/stock" "$NOVA_BLUETOOTH_CONF"
  [ ! -e "$CALLS" ]
}

@test "the command: what is set, set through pkexec, and as JSON" {
  run "$cli"
  [[ $output == "Bluetooth LE is on."* ]]
  run "$cli" off
  [ "$status" -eq 0 ]
  [[ $output == "Bluetooth LE is off: classic Bluetooth only."* ]]
  [ "$("$cli" --json)" = '{"le":false}' ]
  run "$cli" sideways
  [ "$status" -eq 2 ]
}
