#!/usr/bin/env bats

# nova-modemmanager: ModemManager enabled, once, on a computer with a
# cellular modem and the service installed; never again after, so one turned
# off by hand stays off; nothing on a computer without a modem.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_PCI_DEVICES=$SCRATCH/pci NOVA_STATE_DIR=$SCRATCH/state NOVA_MM_UNIT=$SCRATCH/ModemManager.service
  export CALLS=$SCRATCH/calls
  helper=$REPO_ROOT/data/network/bin/nova-modemmanager
  mkdir -p "$SCRATCH/bin" "$NOVA_PCI_DEVICES/0000:00:14.3"
  echo 0x028000 >"$NOVA_PCI_DEVICES/0000:00:14.3/class"
  : >"$NOVA_MM_UNIT"
  printf '#!/bin/bash\necho "systemctl $*" >>"$CALLS"\n' >"$SCRATCH/bin/systemctl"
  chmod +x "$SCRATCH/bin/systemctl"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

modem() {
  mkdir -p "$NOVA_PCI_DEVICES/0000:08:00.0"
  echo 0x0d4000 >"$NOVA_PCI_DEVICES/0000:08:00.0/class"
}

@test "a modem: ModemManager is enabled, and only the first time" {
  modem
  "$helper"
  grep -qx "systemctl enable ModemManager.service" "$CALLS"
  [ -e "$NOVA_STATE_DIR/modemmanager-enabled" ]
  : >"$CALLS"
  "$helper"
  [ ! -s "$CALLS" ]
}

@test "no modem, or no ModemManager installed: nothing is enabled" {
  "$helper"
  [ ! -e "$CALLS" ]
  [ ! -e "$NOVA_STATE_DIR/modemmanager-enabled" ]
  modem
  rm "$NOVA_MM_UNIT"
  "$helper"
  [ ! -e "$CALLS" ]
}

@test "every FCC unlock ModemManager ships is turned on, by vid:pid, and none of its vendor scripts" {
  local available=$SCRATCH/available root=$SCRATCH/root enabled
  mkdir -p "$available"
  printf '#!/bin/sh\n' >"$available/105b"
  ln -s 105b "$available/105b:e0ab"
  ln -s 105b "$available/105b:e0c3"
  (cd "$REPO_ROOT" && make -s install-network DESTDIR="$root" MM_FCC_AVAILABLE="$available" >/dev/null)
  enabled=$root/usr/lib/ModemManager/fcc-unlock.d
  [ "$(find "$enabled" -mindepth 1 -printf '%f\n' | sort | paste -sd ' ')" = "105b:e0ab 105b:e0c3" ]
  # Pointing where the scripts are on the computer it is installed on.
  [ "$(readlink "$enabled/105b:e0ab")" = /usr/share/ModemManager/fcc-unlock.available.d/105b:e0ab ]
}
