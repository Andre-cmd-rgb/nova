#!/usr/bin/env bats

# nova-airdrop-radio: the Wi-Fi card lent to AirDrop and given back. iw, ip,
# nmcli, sysctl and sleep are stubs that log, and the card is a folder made
# to look like its part of /sys: wlan0 on phy0, whose own address is
# 60:11:22:33:44:55 while the interface shows another (NetworkManager's, as
# during a scan).

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" NOVA_AIRDROP_RUN="$SCRATCH/run" NOVA_AIRDROP_SYS="$SCRATCH/sys"
  card="$SCRATCH/sys/class/net/wlan0"
  mkdir -p "$SCRATCH/bin" "$card/phy80211/rfkill0"
  echo 0 >"$card/phy80211/index"
  echo 60:11:22:33:44:55 >"$card/phy80211/macaddress"
  echo 0 >"$card/phy80211/rfkill0/soft"
  echo 0 >"$card/phy80211/rfkill0/hard"
  echo 5a:00:00:00:00:01 >"$card/address"
  : >"$CALLS"

  cat >"$SCRATCH/bin/iw" <<'STUB'
#!/bin/bash
echo "iw $*" >>"$CALLS"
case "$*" in
  dev) [[ -n ${NO_CARD:-} ]] || printf 'phy#0\n\tInterface wlan0\n\t\tifindex 3\n\t\ttype %s\n' "${TYPE:-managed}" ;;
  "phy phy0 info")
    printf '\tSupported interface modes:\n'
    for mode in ${MODES:-IBSS managed AP monitor}; do printf '\t\t * %s\n' "$mode"; done
    printf '\tBand 1:\n\t\tFrequencies:\n'
    [[ -n ${NO_SIX:-} ]] || printf '\t\t\t* 2437.0 MHz [6] %s\n' "${SIX:-(22.0 dBm)}"
    [[ -z ${FIVE:-} ]] || printf '\tBand 2:\n\t\tFrequencies:\n\t\t\t* 5745.0 MHz [149] %s\n' "$FIVE"
    printf '\tSupported commands:\n\t\t * monitor\n'
    ;;
  "reg get") printf 'global\ncountry DE: DFS-ETSI\n\nphy#0 (self-managed)\ncountry IT: DFS-UNSET\n' ;;
  "phy phy0 interface add nova-cell type ibss") [[ -z ${NO_SECOND:-} ]] ;;
  "dev nova-cell info" | "dev wlan0 info")
    joined=$(grep -o 'ibss join nova [0-9]*' "$CALLS" | tail -1)
    channel="6 (2437 MHz)"
    [[ $joined != *5745 ]] || channel="149 (5745 MHz)"
    [[ -n ${NO_CELL:-} ]] || printf '\ttype IBSS\n\tchannel %s, width: 20 MHz\n' "$channel"
    ;;
  "dev nova-cell ibss join nova 5745 "*) [[ " ${NO_WIDTH:-} " != *" ${7} "* ]] ;;
esac
STUB
  # The address a card is given is the address it shows.
  cat >"$SCRATCH/bin/ip" <<'STUB'
#!/bin/bash
echo "ip $*" >>"$CALLS"
[[ "$1 $2 $3 $4" != "link set wlan0 address" ]] || echo "$5" >"$NOVA_AIRDROP_SYS/class/net/wlan0/address"
STUB
  # Connected before, and again once it has been handed back and asked $BACK_AFTER times (never, at 0).
  cat >"$SCRATCH/bin/nmcli" <<'STUB'
#!/bin/bash
echo "nmcli $* (note: $([[ -e $NOVA_AIRDROP_RUN/wifi ]] && echo there || echo none))" >>"$CALLS"
case "$*" in
  "-g GENERAL.STATE device show wlan0")
    if ! grep -q 'managed yes' "$CALLS"; then
      echo "${STATE:-100 (connected)}"
    else
      asked=$(grep -c 'GENERAL.STATE' "$CALLS")
      before=$(sed -n '/managed yes/q;/GENERAL.STATE/p' "$CALLS" | wc -l)
      if ((${BACK_AFTER:-1} > 0 && asked - before >= ${BACK_AFTER:-1})); then echo "100 (connected)"; else echo "30 (disconnected)"; fi
    fi
    ;;
  "-g GENERAL.CON-UUID device show wlan0") echo 1111-2222 ;;
esac
STUB
  printf '#!/bin/bash\necho "sysctl $*" >>"$CALLS"\n' >"$SCRATCH/bin/sysctl"
  printf '#!/bin/bash\nexit 0\n' >"$SCRATCH/bin/sleep"
  chmod +x "$SCRATCH"/bin/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

radio() { "$REPO_ROOT/src/airdrop/bin/nova-airdrop-radio" "$@"; }

# The line number of the first call that matches.
line() { grep -n -m1 -- "$1" "$CALLS" | cut -d: -f1; }

@test "a card that can do it, switched on, passes the check" {
  run radio check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the check says in plain words why not" {
  NO_CARD=1 run radio check
  [ "$status" -eq 1 ]
  [[ $output == *"no Wi-Fi card"* ]]

  TYPE=AP run radio check
  [ "$status" -eq 1 ]
  [[ $output == *"busy as something else"* ]]

  echo 1 >"$SCRATCH/sys/class/net/wlan0/phy80211/rfkill0/soft"
  run radio check
  [ "$status" -eq 1 ]
  [[ $output == "The Wi-Fi is switched off."* ]]
  echo 0 >"$SCRATCH/sys/class/net/wlan0/phy80211/rfkill0/soft"

  # "monitor" among the commands is not the mode.
  MODES="managed AP" run radio check
  [ "$status" -eq 1 ]
  [[ $output == *"cannot do what AirDrop needs"* ]]

  SIX="(disabled)" run radio check
  [ "$status" -eq 1 ]
  [[ $output == *"may not send on channel 6"* ]]
  # A card with no channel 6 at all (5 GHz only) is told the same, not left silent.
  NO_SIX=1 run radio check
  [ "$status" -eq 1 ]
  [[ $output == *"may not send on channel 6"* ]]
  # And none of it touched anything.
  fails grep -qE '^(ip|sysctl) |nmcli device set|interface add|ibss' "$CALLS"
}

@test "up notes the way back before it changes anything, and makes the cell and the monitor under one address" {
  run radio up
  [ "$status" -eq 0 ]
  grep -qx 'nmcli device set wlan0 managed no (note: there)' "$CALLS"
  [ "$(sed -n 1p "$NOVA_AIRDROP_RUN/wifi")" = wlan0 ]
  [ "$(sed -n 2p "$NOVA_AIRDROP_RUN/wifi")" = connected ]
  [ "$(sed -n 3p "$NOVA_AIRDROP_RUN/wifi")" = 1111-2222 ]
  # The card's own country over the system's.
  [ "$(<"$NOVA_AIRDROP_RUN/env")" = $'NOVA_AIRDROP_COUNTRY=IT\nNOVA_AIRDROP_CHANNEL=6' ]
  [ -e "$NOVA_AIRDROP_RUN/busy" ]

  grep -qx 'iw dev nova-cell ibss join nova 2437 HT20 fixed-freq 00:25:00:ff:94:73 beacon-interval 10000' "$CALLS"
  cell=$(grep -m1 '^ip link set dev nova-cell address ' "$CALLS" | awk '{print $NF}')
  monitor=$(grep -m1 '^ip link set dev nova-mon address ' "$CALLS" | awk '{print $NF}')
  [ "$cell" = "$monitor" ]
  # Locally administered, unicast.
  [[ $cell =~ ^[0-9a-f][26ae](:[0-9a-f]{2}){5}$ ]]
  # The station is down before the cell is made, and the cell joined before the monitor is.
  [ "$(line '^ip link set wlan0 down')" -lt "$(line 'interface add nova-cell')" ]
  [ "$(line 'ibss join')" -lt "$(line 'interface add nova-mon type monitor')" ]
}

@test "where the card may send on channel 149, the cell is there, as wide as the card lets it be" {
  FIVE="(22.0 dBm)" run radio up
  [ "$status" -eq 0 ]
  grep -qx 'iw dev nova-cell ibss join nova 5745 80MHz fixed-freq 00:25:00:ff:94:73 beacon-interval 10000' "$CALLS"
  grep -q '^NOVA_AIRDROP_CHANNEL=149$' "$NOVA_AIRDROP_RUN/env"
  [[ $output == *"up on channel 149 (80MHz)"* ]]

  : >"$CALLS"
  radio down >/dev/null
  NO_WIDTH="80MHz" FIVE="(22.0 dBm)" run radio up
  [ "$status" -eq 0 ]
  grep -q 'ibss join nova 5745 HT40+ ' "$CALLS"
  [[ $output == *"up on channel 149 (HT40+)"* ]]
}

@test "channel 149 closed to the card, or asked against, is channel 6" {
  FIVE="(22.0 dBm) (no IR)" run radio up
  [ "$status" -eq 0 ]
  grep -q 'ibss join nova 2437 HT20 ' "$CALLS"
  grep -q '^NOVA_AIRDROP_CHANNEL=6$' "$NOVA_AIRDROP_RUN/env"
  radio down >/dev/null

  : >"$CALLS"
  NOVA_AIRDROP_CHANNEL=6 FIVE="(22.0 dBm)" run radio up
  [ "$status" -eq 0 ]
  grep -q 'ibss join nova 2437 HT20 ' "$CALLS"
  radio down >/dev/null

  # Asked for 149 where the card may not: said, not taken for 6.
  NOVA_AIRDROP_CHANNEL=149 run radio check
  [ "$status" -eq 1 ]
  [[ $output == *"may not send on channel 149"* ]]
}

@test "down gives the card its own address back, not the one the interface showed, and says when the Wi-Fi is back" {
  radio up
  run radio down
  [ "$status" -eq 0 ]
  grep -qx 'ip link set wlan0 address 60:11:22:33:44:55' "$CALLS"
  fails grep -q 'address 5a:00:00:00:00:01' "$CALLS"
  [ "$(line '^iw dev nova-mon del')" -lt "$(line '^iw dev nova-cell del')" ]
  [ "$(line '^iw dev wlan0 set type managed')" -lt "$(line '^ip link set wlan0 address')" ]
  [ "$(line '^ip link set wlan0 up')" -lt "$(line '^nmcli device set wlan0 managed yes')" ]
  [[ $output == "The Wi-Fi is back: connected "*" s after AirDrop ended." ]]
  [ "$(<"$NOVA_AIRDROP_RUN/last")" = "$output" ]
  [ ! -e "$NOVA_AIRDROP_RUN/wifi" ]
  [ ! -e "$NOVA_AIRDROP_RUN/busy" ]
  [ ! -e "$NOVA_AIRDROP_RUN/env" ]
  # The Wi-Fi's own interface is never deleted.
  fails grep -q 'iw dev wlan0 del' "$CALLS"
}

@test "down asked a second time leaves the Wi-Fi alone" {
  radio up
  radio down
  : >"$CALLS"
  run radio down
  [ "$status" -eq 0 ]
  fails grep -q 'wlan0' "$CALLS"
}

@test "a Wi-Fi that does not come back is said plainly, after NetworkManager was asked outright" {
  radio up
  BACK_AFTER=0 NOVA_AIRDROP_BACK_TRIES=45 run radio down
  [ "$status" -eq 0 ]
  grep -q '^nmcli --wait 0 connection up uuid 1111-2222 ifname wlan0' "$CALLS"
  [[ $output == "The Wi-Fi has not reconnected in "*"Try: nmcli device connect wlan0" ]]
}

@test "a Wi-Fi that was not connected is handed back without the wait" {
  STATE="30 (disconnected)" radio up
  [ -z "$(sed -n 2p "$NOVA_AIRDROP_RUN/wifi")" ]
  run radio down
  [[ $output == *"it was not connected before AirDrop either." ]]
  grep -q '^nmcli device set wlan0 managed yes' "$CALLS"
}

@test "a cell that does not start undoes everything and says why" {
  NO_CELL=1 NOVA_AIRDROP_CELL_TRIES=3 run radio up
  [ "$status" -eq 1 ]
  [[ $output == *"did not start AirDrop's cell on channel 6"* ]]
  [[ $(<"$NOVA_AIRDROP_RUN/why") == *"did not start AirDrop's cell"* ]]
  grep -qx 'ip link set wlan0 address 60:11:22:33:44:55' "$CALLS"
  grep -q '^nmcli device set wlan0 managed yes' "$CALLS"
  [ ! -e "$NOVA_AIRDROP_RUN/wifi" ]
  [ ! -e "$NOVA_AIRDROP_RUN/busy" ]
}

@test "on a card with no room for a second interface the station becomes the cell, and is turned back, never deleted" {
  NO_SECOND=1 run radio up
  [ "$status" -eq 0 ]
  grep -qx 'iw dev wlan0 set type ibss' "$CALLS"
  grep -q '^iw dev wlan0 ibss join nova 2437' "$CALLS"
  # The kernel's IPv6 is not turned off on the Wi-Fi's own interface: that would outlast AirDrop.
  fails grep -q '^sysctl' "$CALLS"
  run radio down
  grep -qx 'iw dev wlan0 ibss leave' "$CALLS"
  grep -qx 'iw dev wlan0 set type managed' "$CALLS"
  fails grep -q 'iw dev wlan0 del' "$CALLS"
}

@test "a run that never got to undo is undone before the next" {
  radio up
  : >"$CALLS"
  run radio up
  [ "$status" -eq 0 ]
  [ "$(line '^ip link set wlan0 address 60:11:22:33:44:55')" -lt "$(line 'interface add nova-cell')" ]
  [ -e "$NOVA_AIRDROP_RUN/wifi" ]
}

@test "anything else is a usage error" {
  run radio
  [ "$status" -eq 2 ]
  run radio up now
  [ "$status" -eq 2 ]
}
