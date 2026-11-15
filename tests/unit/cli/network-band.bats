#!/usr/bin/env bats

# nova-network-band, the network panel's Wi-Fi band: what it reads from
# NetworkManager and iw, and how it pins a band and puts the old one back when
# the connection does not come up on the new. nmcli and iw are stubs: wlan0 is
# connected to "Home" on 5 GHz through the profile "Home", whose band is
# $SCRATCH/band, and NetworkManager's last scan is $SCRATCH/scan.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  printf '%s\n' '2412 MHz:Home' '5180 MHz:Home' '5955 MHz:Neighbour' '2437 MHz:Café:5G' >"$SCRATCH/scan"
  : >"$SCRATCH/band"
  echo 'wlan0:wifi:connected' >"$SCRATCH/devices"
  printf 'Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: Home\n\tfreq: 5180.0\n' >"$SCRATCH/link"
  cat >"$SCRATCH/bin/nmcli" <<'STUB'
#!/bin/bash
[[ $1 == -e ]] && shift 2
case "$*" in
  "-g DEVICE,TYPE,STATE device status") cat "$SCRATCH/devices" ;;
  "-g FREQ,SSID dev wifi list ifname wlan0 --rescan no") cat "$SCRATCH/scan" ;;
  "-g GENERAL.CONNECTION device show wlan0") echo Home ;;
  "-g 802-11-wireless.band connection show Home") cat "$SCRATCH/band" ;;
  "connection modify Home 802-11-wireless.band "*) echo "modify ${5:-}" >>"$CALLS"; echo "${5:-}" >"$SCRATCH/band" ;;
  "connection up Home") echo "up $(cat "$SCRATCH/band")" >>"$CALLS"; [[ ! -e $SCRATCH/up-fails-on-$(cat "$SCRATCH/band") ]] ;;
  *) echo "unexpected nmcli $*" >>"$CALLS"; exit 1 ;;
esac
STUB
  # shellcheck disable=SC2016 # expanded by the stub
  printf '#!/bin/bash\ncat "$SCRATCH/link"\n' >"$SCRATCH/bin/iw"
  chmod +x "$SCRATCH/bin/nmcli" "$SCRATCH/bin/iw"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

band() { "$REPO_ROOT/src/cli/bin/nova-network-band" "$@"; }

@test "the band in use, the bands the network answers on, and the one pinned" {
  echo a >"$SCRATCH/band"
  run band
  [ "$status" -eq 0 ]
  [ "$output" = $'band\t5\navailable\t2.4 5\nselected\t5' ]
}

@test "the band in use is offered though the last scan missed it" {
  echo '2412 MHz:Home' >"$SCRATCH/scan"
  run band
  [ "$output" = $'band\t5\navailable\t2.4 5\nselected\tauto' ]
}

@test "a network with colons in its name is matched whole" {
  printf 'Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: Café:5G\n\tfreq: 2437\n' >"$SCRATCH/link"
  run band
  [ "$output" = $'band\t2.4\navailable\t2.4\nselected\tauto' ]
}

@test "no Wi-Fi connected: nothing to say, and nothing to pin" {
  echo 'eth0:ethernet:connected' >"$SCRATCH/devices"
  run band
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run band 5
  [ "$status" -eq 1 ]
  [ ! -e "$CALLS" ]
}

@test "a band the network does not answer on is refused" {
  run band 6
  [ "$status" -eq 1 ]
  [ ! -e "$CALLS" ]
}

@test "a band is pinned and the connection brought up on it; auto unpins" {
  band 2.4
  [ "$(cat "$CALLS")" = $'modify bg\nup bg' ]
  : >"$CALLS"
  band auto
  [ "$(cat "$CALLS")" = $'modify \nup ' ]
}

@test "the band already pinned is left as it is" {
  echo a >"$SCRATCH/band"
  band 5
  [ ! -e "$CALLS" ]
}

@test "a connection that does not come up on the new band gets the old one back" {
  echo a >"$SCRATCH/band"
  touch "$SCRATCH/up-fails-on-bg"
  run band 2.4
  [ "$status" -eq 1 ]
  [ "$(cat "$CALLS")" = $'modify bg\nup bg\nmodify a\nup a' ]
}

@test "anything else is refused" {
  for args in 3 "5 6" auto6; do
    # shellcheck disable=SC2086 # the words of each case
    run band $args
    [ "$status" -eq 1 ]
  done
  [ ! -e "$CALLS" ]
}
