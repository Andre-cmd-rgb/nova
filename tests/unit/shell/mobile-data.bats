#!/usr/bin/env bats

# The mobile-data helper's SIM policy: a modem that has never had a SIM is
# switched off and left out of the bar after the first start, and only
# `mobile-data check` (Settings > Mobile Data) switches it on to look again.
# rfkill, mmcli and nmcli are stand-ins; the rfkill one keeps the WWAN block in
# a file, and the mmcli one answers with the dump in $SCRATCH/dump.

load ../test_helper

helper="$REPO_ROOT/src/shell/plugins/mobile-data/bin/mobile-data"

setup() {
  setup_scratch
  export XDG_STATE_HOME=$SCRATCH/state XDG_CONFIG_HOME=$SCRATCH/config CALLS=$SCRATCH/calls
  export NOVA_MOBILE_NET_DIR=$SCRATCH/net
  state=$XDG_STATE_HOME/nova-mobile-data
  mkdir -p "$SCRATCH/bin" "$state" "$NOVA_MOBILE_NET_DIR"
  export PATH="$SCRATCH/bin:$PATH"
  echo unblocked >"$SCRATCH/wwan"
  stub rfkill '
args=" $* "
case $args in
  *" block wwan "*) echo blocked >"$SCRATCH/wwan"; echo "rfkill block" >>"$CALLS" ;;
  *" unblock wwan "*) echo unblocked >"$SCRATCH/wwan"; echo "rfkill unblock" >>"$CALLS" ;;
  *" TYPE,SOFT list wwan "*) echo "wwan $(cat "$SCRATCH/wwan")" ;;
  *" TYPE,HARD list wwan "*) echo "wwan unblocked" ;;
  *" TYPE list wwan "*) echo wwan ;;
esac'
  stub nmcli 'echo "nmcli $*" >>"$CALLS"'
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# ModemManager, with one modem whose `mmcli -K` dump is these lines.
modem() { # line...
  printf '%s\n' "$@" >"$SCRATCH/dump"
  stub mmcli '
case "$*" in
  -L) echo "    /org/freedesktop/ModemManager1/Modem/0 [Foxconn] T99W175" ;;
  "-m 0 -K") cat "$SCRATCH/dump" ;;
  *) exit 1 ;;
esac'
}

empty_slot() {
  modem "modem.generic.state                              : failed" \
    "modem.generic.state-failed-reason               : sim-missing" \
    "modem.generic.sim                                : --"
}

with_sim() {
  modem "modem.generic.state                              : disabled" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
}

info() { "$helper" info | sed -n "s/^$1=//p"; }

@test "first start, an empty slot: the modem is switched off and out of the bar" {
  empty_slot
  [ "$(info state)" = parked ]
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
  [ "$(cat "$state/parked")" = nosim ]
  [ "$(info parked)" = nosim ]
  run "$helper" status
  [[ $output == *"no SIM was found"* ]]
}

@test "first start, a SIM: nothing is switched off, and it never will be for want of one" {
  with_sim
  [ "$(info state)" = disabled ]
  [ -z "$(info parked)" ]
  [ -e "$state/sim-seen" ]
  empty_slot
  [ "$(info state)" = nosim ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
  [ ! -e "$state/parked" ]
}

@test "first start, a modem still reading its slot: nothing is decided yet" {
  modem "modem.generic.state                              : initializing" \
    "modem.generic.sim                                : --"
  [ "$(info state)" = starting ]
  [ ! -e "$state/parked" ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
  with_sim
  [ "$(info state)" = disabled ]
  [ -e "$state/sim-seen" ]
}

@test "first start without ModemManager: nothing can ask for a SIM, so it is off" {
  if command -v mmcli >/dev/null; then skip "this system has ModemManager"; fi
  [ "$(info state)" = parked ]
  [ "$(cat "$state/parked")" = no-modemmanager ]
  [ "$(info parked)" = no-modemmanager ]
  run "$helper" status
  [[ $output == *"ModemManager is not installed"* ]]
}

@test "a radio turned off by hand is no answer: nothing is decided" {
  empty_slot
  echo blocked >"$SCRATCH/wwan"
  [ "$(info state)" = disabled ]
  [ ! -e "$state/parked" ]
}

@test "parked: kept off when something switches every radio back on, and on is refused" {
  empty_slot
  echo nosim >"$state/parked"
  [ "$(info state)" = parked ]
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
  run "$helper" on
  [ "$status" -ne 0 ]
  [[ $output == *"mobile-data check"* ]]
}

@test "check: a SIM found brings the modem back for good" {
  echo nosim >"$state/parked"
  echo blocked >"$SCRATCH/wwan"
  with_sim
  run "$helper" check
  [ "$status" -eq 0 ]
  [ ! -e "$state/parked" ] && [ -e "$state/sim-seen" ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
  [ "$(info state)" = disabled ]
}

@test "check: still no SIM, and the modem is off again" {
  echo nosim >"$state/parked"
  echo blocked >"$SCRATCH/wwan"
  empty_slot
  run "$helper" check
  [ "$status" -ne 0 ]
  [[ $output == *"no SIM in the slot"* ]]
  [ "$(cat "$state/parked")" = nosim ]
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
  grep -qx "rfkill unblock" "$CALLS"
}

@test "the SMS archive stays private when it is trimmed" {
  sed '/^usage() {/,$d' "$helper" >"$SCRATCH/mobile-data.sh"
  # shellcheck source=/dev/null
  source "$SCRATCH/mobile-data.sh"
  mkdir -p "$XDG_CONFIG_HOME/nova-mobile-data"
  echo SMS_KEEP=2 >"$XDG_CONFIG_HOME/nova-mobile-data/config"
  umask 022
  local n
  for n in 1 2 3; do sms_archive "hash$n" 2026-10-24 +100 "text $n"; done
  [ "$(cut -f2 "$INBOX" | paste -sd ' ')" = 'hash2 hash3' ]
  [ "$(stat -c %a "$INBOX")" = 600 ]
}
