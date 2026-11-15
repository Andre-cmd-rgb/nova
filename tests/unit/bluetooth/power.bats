#!/usr/bin/env bats

# nova-bluetooth-power: the rfkill block is what turns Bluetooth off and on,
# and on is any adapter powered. rfkill, bluetoothctl and busctl are stubs
# over one state: $SCRATCH/adapters, a line per adapter (its name, address and
# on or off); the block in $SCRATCH/blocked. Lifting the block powers every
# adapter up, as bluetoothd does, unless $SCRATCH/no-autoenable is there; an
# adapter will not come up at all with $SCRATCH/stuck.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" NOVA_BLUETOOTH_POWER_WAIT_SECONDS=0
  mkdir -p "$SCRATCH/bin"
  printf 'hci0 AA:AA:AA:AA:AA:01 off\nhci1 AA:AA:AA:AA:AA:02 off\n' >"$SCRATCH/adapters"
  touch "$SCRATCH/blocked"
  cat >"$SCRATCH/bin/rfkill" <<'STUB'
#!/bin/bash
echo "rfkill $*" >>"$CALLS"
case $1 in
  block) touch "$SCRATCH/blocked"; sed -i 's/ on$/ off/' "$SCRATCH/adapters" ;;
  unblock)
    rm -f "$SCRATCH/blocked"
    [[ -e $SCRATCH/no-autoenable || -e $SCRATCH/stuck ]] || sed -i 's/ off$/ on/' "$SCRATCH/adapters" ;;
esac
STUB
  cat >"$SCRATCH/bin/bluetoothctl" <<'STUB'
#!/bin/bash
case $1 in
  list) while read -r _ address _; do echo "Controller $address nova"; done <"$SCRATCH/adapters" ;;
  show) [[ $(grep " $2 " "$SCRATCH/adapters") == *" on" ]] && echo "Powered: yes" || echo "Powered: no" ;;
  power) [[ -e $SCRATCH/stuck ]] || sed -i '1s/ off$/ on/' "$SCRATCH/adapters" ;;
esac
STUB
  cat >"$SCRATCH/bin/busctl" <<'STUB'
#!/bin/bash
if [[ $* == *GetManagedObjects* ]]; then
  objects=""
  while read -r name _ state; do
    objects+="${objects:+,}\"/org/bluez/$name\":{\"org.bluez.Adapter1\":{\"Powered\":{\"type\":\"b\",\"data\":$([[ $state == on ]] && echo true || echo false)}}}"
    objects+=",\"/org/bluez/$name/dev_00\":{\"org.bluez.Device1\":{\"Connected\":{\"type\":\"b\",\"data\":true}}}"
  done <"$SCRATCH/adapters"
  echo "{\"type\":\"a{oa{sa{sv}}}\",\"data\":[{$objects}]}"
elif [[ $* == *set-property*Powered* && ! -e $SCRATCH/stuck ]]; then
  for arg; do [[ $arg != /org/bluez/* ]] || sed -i "s/^${arg##*/} \(.*\) off$/${arg##*/} \1 on/" "$SCRATCH/adapters"; done
fi
STUB
  printf '#!/bin/sh\n' >"$SCRATCH/bin/sleep"
  chmod +x "$SCRATCH/bin"/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

power() { "$REPO_ROOT/src/cli/bin/nova-bluetooth-power" "$@"; }

@test "on lifts the block, and the adapters come up by themselves" {
  run power on
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = 'rfkill unblock bluetooth' ]
  power is-on
}

@test "on powers up an adapter that was powered down without the block" {
  touch "$SCRATCH/no-autoenable"
  run power on
  [ "$status" -eq 0 ]
  power is-on
}

@test "on fails, saying so, when no adapter comes up" {
  touch "$SCRATCH/stuck"
  run power on
  [ "$status" -eq 1 ]
  [ "$output" = 'nova-bluetooth-power: adapter did not come up' ]
}

@test "off sets the block, which powers every adapter down" {
  power on
  : >"$CALLS"
  power off
  [ "$(cat "$CALLS")" = 'rfkill block bluetooth' ]
  fails power is-on
}

@test "is-on: any adapter powered, not only the first" {
  fails power is-on
  printf 'hci0 AA:AA:AA:AA:AA:01 off\nhci1 AA:AA:AA:AA:AA:02 on\n' >"$SCRATCH/adapters"
  power is-on
  : >"$SCRATCH/adapters"
  fails power is-on
}

@test "toggle turns it the other way" {
  power toggle
  power is-on
  power toggle
  fails power is-on
  [ "$(cat "$CALLS")" = $'rfkill unblock bluetooth\nrfkill block bluetooth' ]
}

@test "anything else is refused" {
  run power
  [ "$status" -eq 1 ]
  [ "$output" = 'Usage: nova-bluetooth-power <on|off|toggle|is-on>' ]
  run power yes
  [ "$status" -eq 1 ]
  [ ! -e "$CALLS" ]
}
