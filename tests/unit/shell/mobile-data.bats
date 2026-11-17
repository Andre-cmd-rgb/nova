#!/usr/bin/env bats

# The mobile-data helper's SIM policy: a modem with no SIM is switched off and
# left out of the bar whenever that is seen, and a SIM seen in its slot while it
# is off (ModemManager still reads it) brings it back, with the APN looked up for
# a SIM new in the slot. rfkill, mmcli and nmcli are stand-ins; the rfkill one
# keeps the WWAN block in a file, and the mmcli one answers with the dump in
# $SCRATCH/dump, and the SIM's in $SCRATCH/sim.

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

# ModemManager, with one modem whose `mmcli -K` dump is these lines; its SIM's
# is in $SCRATCH/sim, when there is one.
modem() { # line...
  printf '%s\n' "$@" >"$SCRATCH/dump"
  stub mmcli '
case "$*" in
  -L) echo "    /org/freedesktop/ModemManager1/Modem/0 [Foxconn] T99W175" ;;
  "-m 0 -K") cat "$SCRATCH/dump" ;;
  "-i 0 -K") [ -e "$SCRATCH/sim" ] && cat "$SCRATCH/sim" || exit 1 ;;
  *) exit 1 ;;
esac'
}

empty_slot() {
  modem "modem.generic.state                              : failed" \
    "modem.generic.state-failed-reason               : sim-missing" \
    "modem.generic.sim                                : --"
}

# A SIM that says what it is: a made-up ICCID, <n> its last digit.
sim_card() { # [n]
  printf '%s\n' "sim.dbus-path                 : /org/freedesktop/ModemManager1/SIM/0" \
    "sim.properties.imsi           : 00101000000000${1:-1}" \
    "sim.properties.iccid          : 899900000000000000${1:-1}" >"$SCRATCH/sim"
}

# An eSIM with no plan on it: nothing to read but its EID.
blank_esim() {
  printf '%s\n' "sim.dbus-path                 : /org/freedesktop/ModemManager1/SIM/0" \
    "sim.properties.active         : yes" \
    "sim.properties.imsi           : --" \
    "sim.properties.iccid          : --" \
    "sim.properties.eid            : 89000000000000000000000000000000" >"$SCRATCH/sim"
}

with_sim() {
  modem "modem.generic.state                              : disabled" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  sim_card
}

info() { "$helper" info | sed -n "s/^$1=//p"; }

@test "an empty slot: the modem is switched off and out of the bar" {
  empty_slot
  [ "$(info state)" = parked ]
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
  [ "$(cat "$state/parked")" = nosim ]
  [ "$(info parked)" = nosim ]
  run "$helper" status
  [[ $output == *"no SIM. One put in brings it back"* ]]
}

@test "a SIM: nothing is switched off; taken out, the modem is, whatever it had before" {
  with_sim
  [ "$(info state)" = disabled ]
  [ -z "$(info parked)" ]
  # A mark of a SIM seen once, from before, no longer keeps a modem on.
  echo x >"$state/sim-seen"
  empty_slot
  [ "$(info state)" = parked ]
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
  [ ! -e "$state/sim-seen" ]
}

@test "a modem still reading its slot: nothing is decided yet" {
  modem "modem.generic.state                              : initializing" \
    "modem.generic.sim                                : --"
  [ "$(info state)" = starting ]
  [ ! -e "$state/parked" ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
  with_sim
  [ "$(info state)" = disabled ]
  [ ! -e "$state/parked" ]
}

@test "parked: a SIM seen in the slot brings the modem back, with mobile data on" {
  empty_slot
  [ "$(info state)" = parked ]
  : >"$CALLS"
  # Off, the modem is in low power and ModemManager still reads its slot.
  with_sim
  [ "$(info state)" = disabled ]
  [ ! -e "$state/parked" ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
  grep -qx "nmcli radio wwan on" "$CALLS"
}

@test "parked: a slot that says nothing, or an eSIM with no plan, leaves it off, the radio never on" {
  echo nosim >"$state/parked"
  echo blocked >"$SCRATCH/wwan"
  modem "modem.generic.state                              : disabled" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  [ "$(info state)" = parked ]
  blank_esim
  [ "$(info state)" = parked ]
  # Where blocking the radio cut the modem's power, there is no modem to ask.
  stub mmcli 'exit 1'
  [ "$(info state)" = parked ]
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
  ! grep -q "unblock\|radio wwan on" "$CALLS"
}

# ModemManager installed, and not running: mmcli finds nothing on the bus.
stopped_modemmanager() {
  stub mmcli 'echo "error: couldn'"'"'t find the ModemManager process in the bus" >&2; exit 1'
}

@test "ModemManager installed but not running: said so, with the command, and nothing is decided" {
  stopped_modemmanager
  [ "$(info state)" = noservice ]
  [ ! -e "$state/parked" ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
  run "$helper" status
  [[ $output == *"sudo systemctl enable --now ModemManager.service"* ]]
  echo blocked >"$SCRATCH/wwan"
  [ "$(info state)" = noservice ]
}

@test "ModemManager not running: on and check refuse at once, and check parks nothing" {
  stopped_modemmanager
  run "$helper" on
  [ "$status" -ne 0 ]
  [[ $output == *"ModemManager is not running"* ]]
  run "$helper" check
  [ "$status" -ne 0 ]
  [[ $output == *"ModemManager running"* ]]
  [ ! -e "$state/parked" ]
}

@test "kept off by an older Nova for want of ModemManager, which is here now: brought back" {
  with_sim
  echo no-modemmanager >"$state/parked"
  echo blocked >"$SCRATCH/wwan"
  [ "$(info state)" = disabled ]
  [ ! -e "$state/parked" ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
  # A park for want of a SIM is no such thing: with no SIM, it stays.
  empty_slot
  echo nosim >"$state/parked"
  echo blocked >"$SCRATCH/wwan"
  [ "$(info state)" = parked ]
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
  [ ! -e "$state/parked" ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
  [ "$(info state)" = disabled ]
}

@test "check: no SIM in a slot it can read off, and the radio never comes on" {
  echo nosim >"$state/parked"
  echo blocked >"$SCRATCH/wwan"
  empty_slot
  run "$helper" check
  [ "$status" -ne 0 ]
  [[ $output == *"no SIM in the slot"* ]]
  [ "$(cat "$state/parked")" = nosim ]
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
  ! grep -qx "rfkill unblock" "$CALLS"
}

@test "check: a modem it cannot ask while off is switched on to look, and off again with no SIM" {
  echo nosim >"$state/parked"
  echo blocked >"$SCRATCH/wwan"
  empty_slot
  # ModemManager runs, and sees the modem only once its radio is unblocked.
  stub mmcli '
if [ "$(cat "$SCRATCH/wwan")" != unblocked ]; then
  [ "$*" = -L ] && echo "No modems were found" && exit 0
  exit 1
fi
case "$*" in
  -L) echo "    /org/freedesktop/ModemManager1/Modem/0 [Foxconn] T99W175" ;;
  "-m 0 -K") cat "$SCRATCH/dump" ;;
  *) exit 1 ;;
esac'
  run "$helper" check
  [ "$status" -ne 0 ]
  [[ $output == *"no SIM in the slot"* ]]
  grep -qx "rfkill unblock" "$CALLS"
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
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

@test "a message that came without a number is from Unknown, and keeps its words" {
  sed '/^usage() {/,$d' "$helper" >"$SCRATCH/mobile-data.sh"
  # shellcheck source=/dev/null
  source "$SCRATCH/mobile-data.sh"
  sms_archive hash1 2026-10-24T09:00:00+02:00 "" "Your bill is ready"
  run cmd_sms_list
  [[ $output == *"Unknown"*"Your bill is ready"* ]]
  run cmd_sms_show 1
  [ "${lines[0]}" = "From: Unknown" ]
  [ "${lines[2]}" = "Your bill is ready" ]
}

@test "a connected modem: what the bar shows, read in one pass of its dump" {
  modem "modem.generic.ports.value[1]                    : cdc-wdm0 (mbim)" \
    "modem.generic.ports.value[2]                    : wwan0 (net)" \
    "modem.generic.access-technologies.value[1]      : lte" \
    "modem.generic.access-technologies.value[2]      : 5gnr" \
    "modem.generic.state                             : connected" \
    "modem.generic.signal-quality.value              : 72" \
    "modem.generic.sim                               : /org/freedesktop/ModemManager1/SIM/0" \
    "modem.3gpp.operator-name                        : Voda: fone"
  stub nmcli '
case "$*" in
  "-t -f TYPE,NAME connection show") printf "%s\n" "802-11-wireless:Home" "gsm:Work\\: SIM" ;;
  "-t -f TYPE,DEVICE,STATE device status") printf "%s\n" "wifi:wlp9s0:connected" "gsm:cdc-wdm0:connected" ;;
esac'
  stub ip 'echo "5: wwan0    inet 10.1.2.3/30 scope global wwan0"'
  [ "$(info state)" = connected ]
  [ "$(info operator)" = "Voda: fone" ]
  [ "$(info tech)" = 5G ]
  [ "$(info signal)" = 72 ]
  [ "$(info iface)" = wwan0 ]
  [ "$(info ip)" = 10.1.2.3 ]
  [ "$(info profile)" = "Work: SIM" ]
  [ "$(info managed)" = yes ]
}

@test "the billing period starts on its day, or the last of a shorter month" {
  sed '/^usage() {/,$d' "$helper" >"$SCRATCH/mobile-data.sh"
  # shellcheck source=/dev/null
  source "$SCRATCH/mobile-data.sh"
  mkdir -p "$XDG_CONFIG_HOME/nova-mobile-data"
  period() { # today reset-day
    echo "RESET_DAY=$2" >"$CONFIG"
    NOVA_MOBILE_TODAY=$1 period_bounds
    echo "$PERIOD_START $PERIOD_NEXT"
  }
  [ "$(period 2025-02-15 31)" = "2025-01-31 2025-02-28" ]
  [ "$(period 2024-02-29 31)" = "2024-02-29 2024-03-31" ]
  [ "$(period 2100-02-28 29)" = "2100-02-28 2100-03-29" ]
  [ "$(period 2025-12-31 1)" = "2025-12-01 2026-01-01" ]
  [ "$(period 2026-01-05 10)" = "2025-12-10 2026-01-10" ]
  [ "$(period 2026-03-01 x)" = "2026-03-01 2026-04-01" ]
}

@test "the config: the last line for a key wins, spaces and CRLF aside" {
  sed '/^usage() {/,$d' "$helper" >"$SCRATCH/mobile-data.sh"
  # shellcheck source=/dev/null
  source "$SCRATCH/mobile-data.sh"
  mkdir -p "$XDG_CONFIG_HOME/nova-mobile-data"
  printf '%s\r\n' "PROFILE = first" " PROFILE =  Last One  " "PROFILE_X=no" >"$CONFIG"
  [ "$(get_cfg PROFILE)" = "Last One" ]
  [ "$(get_cfg APN fallback)" = fallback ]
}

# NetworkManager with a gsm device in the state $SCRATCH/device says (prepare
# by default, as while it keeps asking) and the profiles in $SCRATCH/profiles;
# `connection up` exits with $SCRATCH/up-status. The radio goes off and on
# as rfkill's does. Every call is noted.
network_manager() {
  printf '%s\n' "${1:-connecting (prepare)}" >"$SCRATCH/device"
  [[ -e $SCRATCH/profiles ]] || : >"$SCRATCH/profiles"
  stub nmcli '
echo "nmcli $*" >>"$CALLS"
case "$*" in
  "-t -f TYPE,DEVICE,STATE device status") echo "gsm:wwan0mbim0:$(cat "$SCRATCH/device")" ;;
  "-t -f TYPE,NAME connection show") sed "s/^/gsm:/" "$SCRATCH/profiles" ;;
  "-t -f NAME connection show") cat "$SCRATCH/profiles" ;;
  "radio wwan off") echo blocked >"$SCRATCH/wwan" ;;
  "radio wwan on") echo unblocked >"$SCRATCH/wwan" ;;
  "connection add "*) echo mobile >>"$SCRATCH/profiles" ;;
  "-g gsm.apn connection show "*) cat "$SCRATCH/apn" 2>/dev/null ;;
  *"connection up "*) exit "$(cat "$SCRATCH/up-status" 2>/dev/null || echo 0)" ;;
esac
exit 0'
}

# A modem ModemManager cannot power up: `--enable` answers as it does for a
# modem its maker locked.
locked_by_maker() {
  modem "modem.generic.state                              : enabling" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  stub mmcli '
case "$*" in
  -L) echo "    /org/freedesktop/ModemManager1/Modem/0 [foxconn] T99W175" ;;
  "-m 0 -K") cat "$SCRATCH/dump" ;;
  "-m 0 --enable --timeout=30") echo "mmcli -m 0 --enable" >>"$CALLS"
    echo "error: couldn'"'"'t enable the modem: '"'"'GDBus.Error:org.freedesktop.ModemManager1.Error.Core.Retry: Invalid transition'"'"'" >&2; exit 1 ;;
  *) exit 1 ;;
esac'
}

@test "a modem that cannot be powered up: a minute of it, and mobile data is off, said why" {
  echo x >"$state/sim-seen"
  locked_by_maker
  network_manager
  NOVA_MOBILE_NOW=1000 info state >/dev/null
  [ "$(NOVA_MOBILE_NOW=1030 info state)" = starting ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
  [ "$(NOVA_MOBILE_NOW=1060 info state)" = failed ]
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
  grep -qx "nmcli radio wwan off" "$CALLS"
  [ "$(cat "$state/stopped")" = noenable ]
  [ "$(info why)" = noenable ]
  run "$helper" status
  [[ $output == *"could not be turned on"* ]]
}

@test "a modem slow to come up, or seen again after a sleep, is given its minute afresh" {
  echo x >"$state/sim-seen"
  locked_by_maker
  network_manager
  NOVA_MOBILE_NOW=1000 info state >/dev/null
  # Hours later: a sleep in between, and the minute starts again.
  [ "$(NOVA_MOBILE_NOW=20000 info state)" = starting ]
  [ "$(NOVA_MOBILE_NOW=20050 info state)" = starting ]
  # Up at last: nothing is kept of the wait.
  modem "modem.generic.state                              : registered" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  NOVA_MOBILE_NOW=20055 info state >/dev/null
  [ ! -e "$state/trying" ] && [ ! -e "$state/stopped" ]
  [ "$(cat "$SCRATCH/wwan")" = unblocked ]
}

@test "a modem NetworkManager is not asking, its radio off, is not the loop" {
  echo x >"$state/sim-seen"
  locked_by_maker
  network_manager unavailable
  NOVA_MOBILE_NOW=1000 info state >/dev/null
  [ "$(NOVA_MOBILE_NOW=1100 info state)" = starting ]
  [ ! -e "$state/stopped" ]
}

@test "stopped, and turned on by something else: a fresh try, not still failed" {
  echo x >"$state/sim-seen"
  locked_by_maker
  network_manager
  echo noenable >"$state/stopped"
  echo blocked >"$SCRATCH/wwan"
  [ "$(info state)" = failed ]
  echo unblocked >"$SCRATCH/wwan"
  [ "$(NOVA_MOBILE_NOW=1000 info state)" = starting ]
  [ ! -e "$state/stopped" ]
}

@test "on: a modem that cannot be powered up is said at once, and left off" {
  echo x >"$state/sim-seen"
  echo very >"$SCRATCH/profiles"
  locked_by_maker
  network_manager disconnected
  echo blocked >"$SCRATCH/wwan"
  run "$helper" on
  [ "$status" -eq 1 ]
  [[ $output == *"the modem could not be turned on, so mobile data is off again"* ]]
  grep -qx "mmcli -m 0 --enable" "$CALLS"
  [ "$(cat "$state/stopped")" = noenable ]
  [ "$(cat "$SCRATCH/wwan")" = blocked ]
  fails grep -q "connection up" "$CALLS"
}

@test "on: a locked SIM is said at once, and so is one ModemManager could not read" {
  echo very >"$SCRATCH/profiles"
  network_manager disconnected
  modem "modem.generic.state                              : locked" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  run "$helper" on
  [ "$status" -eq 1 ]
  [[ $output == *"the SIM needs its PIN: Settings > Mobile Data asks for it"* ]]
  modem "modem.generic.state                              : failed" \
    "modem.generic.state-failed-reason               : sim-error" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  run "$helper" on
  [[ $output == *"the SIM could not be read"* ]]
  [ "$(info state)" = failed ] && [ "$(info why)" = sim-error ]
}

@test "an eSIM with no plan on it is no SIM, and the modem is switched off" {
  modem "modem.generic.state                              : failed" \
    "modem.generic.state-failed-reason               : esim-without-profiles" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  [ "$(info state)" = parked ]
  [ "$(cat "$state/parked")" = nosim ]
  run "$helper" status
  [[ $output == *"no SIM"* ]]
}

@test "a built-in eSIM with no plan, the modem on and searching or off: no SIM, and switched off" {
  modem "modem.generic.state                              : enabled" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  blank_esim
  [ "$(info state)" = parked ]
  [ "$(cat "$state/parked")" = nosim ]
  # Mobile data switched off, the modem in low power: the same.
  rm -f -- "$state/parked"
  echo unblocked >"$SCRATCH/wwan"
  modem "modem.generic.state                              : disabled" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  [ "$(info state)" = parked ]
}

@test "a SIM new in the slot has its APN looked up once it is on a network; the one set up keeps its own" {
  stub nmcli '
echo "nmcli $*" >>"$CALLS"
case "$*" in
  *"TYPE,NAME connection show"*) echo "gsm:very" ;;
  *"NAME connection show"*) echo "very" ;;
esac'
  modem "modem.generic.state                              : registered" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  sim_card 1
  # The SIM the profile was made for, before this was kept: taken as set up.
  "$helper" info >/dev/null
  [ -s "$state/sim" ]
  ! grep -q "gsm.apn" "$CALLS"
  "$helper" info >/dev/null
  ! grep -q "gsm.apn" "$CALLS"
  # Another SIM: its APN looked up, once.
  sim_card 2
  "$helper" info >/dev/null
  [ "$(grep -c "gsm.apn" "$CALLS")" -eq 1 ]
  "$helper" info >/dev/null
  [ "$(grep -c "gsm.apn" "$CALLS")" -eq 1 ]
  ! grep -q "899900000000000000" "$state/sim"
}

@test "a modem searching with a SIM on it, or one that will not say: still searching" {
  echo x >"$state/sim-seen"
  modem "modem.generic.state                              : enabled" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  [ "$(info state)" = searching ]
  printf '%s\n' "sim.properties.imsi           : --" \
    "sim.properties.iccid          : 8949020000012345678" >"$SCRATCH/sim"
  [ "$(info state)" = searching ]
}

# A locked SIM with <tries> left (3), which takes 1234 for its PIN and
# counts down otherwise. The PIN goes to it over the bus, from python's
# standard input: the stand-in notes its arguments and what came in.
sim_pin() {
  echo "${1:-3}" >"$SCRATCH/tries"
  modem "modem.generic.state                              : locked" \
    "modem.generic.unlock-required                    : sim-pin" \
    "modem.generic.unlock-retries.length              : 2" \
    "modem.generic.unlock-retries.value[1]            : sim-pin (${1:-3})" \
    "modem.generic.unlock-retries.value[2]            : sim-puk (10)" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  stub python3 '
IFS= read -r pin
echo "python3 args: $1 ${*:3}" >>"$CALLS"
echo "send-pin ${*: -1} stdin=$pin" >>"$CALLS"
[[ $pin == 1234 ]] && exit 0
tries=$(( $(cat "$SCRATCH/tries") - 1 )); echo "$tries" >"$SCRATCH/tries"
sed -i "s/sim-pin ([0-9]*)/sim-pin ($tries)/" "$SCRATCH/dump"
echo "org.freedesktop.ModemManager1.Error.MobileEquipment.IncorrectPassword: Incorrect password" >&2
exit 1'
}

@test "a SIM that needs its PIN: what it needs and the tries left, and a wrong PIN counts down" {
  network_manager disconnected
  sim_pin
  [ "$(info state)" = locked ]
  [ "$(info unlock)" = sim-pin ]
  [ "$(info pin_tries)" = 3 ]
  run "$helper" pin <<<"0000"
  [ "$status" -eq 1 ]
  [[ $output == *"that is not the PIN: 2 tries left"* ]]
  run "$helper" pin <<<"12"
  [[ $output == *"a PIN is 4 to 8 digits"* ]]
  # On standard input all the way to the bus, never among any arguments.
  grep -qx "send-pin /org/freedesktop/ModemManager1/SIM/0 stdin=0000" "$CALLS"
  fails grep -q "0000" <(grep -v "stdin=" "$CALLS")
}

@test "one try left: the PIN is not sent unless it is the last try given knowingly" {
  echo very >"$SCRATCH/profiles"
  network_manager connected
  sim_pin 1
  run "$helper" pin <<<"0000"
  [ "$status" -eq 1 ]
  [[ $output == *"one try is left, and a wrong PIN blocks the SIM"* ]]
  fails grep -q "send-pin" "$CALLS"
  run "$helper" pin --last-try <<<"1234"
  [ "$status" -eq 0 ]
  grep -qx "send-pin /org/freedesktop/ModemManager1/SIM/0 stdin=1234" "$CALLS"
}

@test "the right PIN unlocks the SIM, and mobile data comes on" {
  echo very >"$SCRATCH/profiles"
  network_manager connected
  sim_pin
  run "$helper" pin <<<"1234"
  [ "$status" -eq 0 ]
  [[ $output == *"The SIM is unlocked."* ]]
  grep -qx "send-pin /org/freedesktop/ModemManager1/SIM/0 stdin=1234" "$CALLS"
  grep -qx "nmcli radio wwan on" "$CALLS"
}

# mobile-broadband-provider-info, three networks: one with a carrier alone,
# its APN with a user and no password; one shared by two, neither primary;
# one shared, one of them primary.
providers() {
  export NOVA_MOBILE_PROVIDERS=$SCRATCH/providers.xml
  cat >"$NOVA_MOBILE_PROVIDERS" <<'XML'
<serviceproviders format="2.0">
<country code="it">
	<provider>
		<name>Alone</name>
		<gsm>
			<network-id mcc="222" mnc="88"/>
			<apn value="mms.alone">
				<usage type="mms"/>
			</apn>
			<apn value="web.alone">
				<usage type="internet"/>
				<username>web</username>
			</apn>
		</gsm>
	</provider>
	<provider>
		<name>Big</name>
		<gsm>
			<network-id mcc="222" mnc="10"/>
			<apn value="big.it"/>
		</gsm>
	</provider>
	<provider>
		<name>Small</name>
		<gsm>
			<network-id mcc="222" mnc="10"/>
			<apn value="small.it"/>
		</gsm>
	</provider>
	<provider>
		<name>Brand</name>
		<gsm>
			<network-id mcc="222" mnc="01"/>
			<apn value="brand.it"/>
		</gsm>
	</provider>
	<provider primary="true">
		<name>Owner</name>
		<gsm>
			<network-id mcc="222" mnc="01"/>
			<apn value="owner.it"><usage type="internet"/></apn>
		</gsm>
	</provider>
</country>
</serviceproviders>
XML
}

lib() {
  sed '/^usage() {/,$d' "$helper" >"$SCRATCH/mobile-data.sh"
  # shellcheck source=/dev/null
  source "$SCRATCH/mobile-data.sh"
}

@test "the APN for a SIM: its carrier's, the primary one's of a shared network, none for an unclear one" {
  providers
  lib
  [ "$(apn_for 222 88 | tr '\037' '|')" = "web.alone|web|" ]
  [ "$(apn_for 222 01 | tr '\037' '|')" = "owner.it||" ]
  fails apn_for 222 10
  fails apn_for 999 99
}

@test "on, with no profile yet: one is made with the APN looked up for the SIM's own network" {
  providers
  network_manager disconnected
  modem "modem.generic.state                              : registered" \
    "modem.3gpp.operator-code                         : 22210" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  stub mmcli '
case "$*" in
  -L) echo "    /org/freedesktop/ModemManager1/Modem/0 [foxconn] T99W175" ;;
  "-m 0 -K") cat "$SCRATCH/dump" ;;
  "-i /org/freedesktop/ModemManager1/SIM/0 -K") echo "sim.properties.operator-code                    : 22288" ;;
  *) exit 1 ;;
esac'
  run "$helper" on
  [ "$status" -eq 0 ]
  grep -q "nmcli connection add type gsm ifname \* con-name mobile connection.autoconnect yes" "$CALLS"
  grep -qx "nmcli connection modify mobile gsm.auto-config no gsm.apn web.alone gsm.username web gsm.password " "$CALLS"
  grep -q "connection up mobile" "$CALLS"
}

@test "on: the network refusing the APN exits 3, for Settings to ask for one" {
  echo very >"$SCRATCH/profiles"
  echo internet.it >"$SCRATCH/apn"
  echo 4 >"$SCRATCH/up-status"
  echo ON_TIMEOUT=1 >"$SCRATCH/config.tmp"
  mkdir -p "$XDG_CONFIG_HOME/nova-mobile-data" && mv "$SCRATCH/config.tmp" "$XDG_CONFIG_HOME/nova-mobile-data/config"
  network_manager disconnected
  modem "modem.generic.state                              : registered" \
    "modem.generic.sim                                : /org/freedesktop/ModemManager1/SIM/0"
  stub journalctl 'echo "Nov 16 ModemManager[1]: <wrn> [modem0] connection attempt #1 failed: Missing or unknown APN"'
  stub sleep 'exit 0'
  run "$helper" on
  [ "$status" -eq 3 ]
  [[ $output == *'the network does not know the APN "internet.it": Settings > Mobile Data takes another'* ]]
}
