#!/usr/bin/env bats

# The night light's schedule and warmth, written to shell.json and said back,
# and the place its sunset is for: the weather's, else the time zone's, from
# time zone tables the test writes. The shell and the toggle are stubs that
# write down each call.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" NOVA_PATH="$SCRATCH/nova" CALLS="$SCRATCH/calls" XDG_STATE_HOME="$SCRATCH/state"
  export NOVA_ZONEINFO="$SCRATCH/zoneinfo" NOVA_LOCALTIME="$SCRATCH/localtime"
  mkdir -p "$HOME/.config/nova" "$NOVA_PATH/default" "$SCRATCH/bin" "$NOVA_ZONEINFO"
  cp "$REPO_ROOT/data/defaults/shell.json" "$NOVA_PATH/default/shell.json"
  stub nova-shell
  # The night light is on when $SCRATCH/on exists.
  stub nova-toggle-nightlight '[[ $1 == --status ]] && { [[ -e $SCRATCH/on ]] && echo "{\"enabled\":true}" || echo "{\"enabled\":false}"; }; exit 0'
  : >"$CALLS"
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

settings() { jq -c "$1" "$HOME/.config/nova/shell.json"; }

@test "schedule: off at first, sunset to sunrise, and set hours, each said back" {
  [ "$(nova-nightlight-schedule)" = "Off: the night light comes on only by hand." ]
  [ "$(nova-nightlight-schedule sunset)" = "From sunset to sunrise." ]
  [ "$(settings .nightlight)" = '{"schedule":"sunset"}' ]
  grep -qx 'nova-shell -q shell reloadConfig' "$CALLS"
  [ "$(nova-nightlight-schedule hours)" = "From 22:00 to 07:00, every day." ]
  [ "$(nova-nightlight-schedule 21:30 6:05)" = "From 21:30 to 06:05, every day." ]
  [ "$(settings .nightlight)" = '{"from":"21:30","schedule":"hours","to":"06:05"}' ]
  nova-nightlight-schedule off
  nova-nightlight-schedule hours
  [ "$(nova-nightlight-schedule)" = "From 21:30 to 06:05, every day." ]
  [ "$(settings .bar.position)" = '"top"' ]
}

@test "schedule: hours that are no times, or the same time twice, are refused and nothing is written" {
  nova-nightlight-schedule 22:00 07:00
  for wrong in "24:00 07:00" "22:00" "22 7" "22:00 07:00 08:00" "sunrise" "off now"; do
    # shellcheck disable=SC2086 # the words are the arguments
    run nova-nightlight-schedule $wrong
    [ "$status" -eq 1 ]
    [[ $output == *"usage: nova nightlight schedule"* ]]
  done
  run nova-nightlight-schedule 7:00 07:00
  [ "$status" -eq 1 ]
  [[ $output == *"start and end at different times"* ]]
  for wrong in "from" "from 25:00" "to 7" "from 21:00 22:00" "at 21:00"; do
    # shellcheck disable=SC2086 # the words are the arguments
    run nova-nightlight-schedule $wrong
    [ "$status" -eq 1 ]
  done
  run nova-nightlight-schedule from 7:00
  [[ $output == *"start and end at different times"* ]]
  [ "$(settings .nightlight)" = '{"from":"22:00","schedule":"hours","to":"07:00"}' ]
}

@test "schedule: one end at a time, the other as kept, as Settings sends two picks in a row" {
  [ "$(nova-nightlight-schedule to 06:30)" = "From 22:00 to 06:30, every day." ]
  nova-nightlight-schedule sunset
  nova-nightlight-schedule from 21:00
  nova-nightlight-schedule to 6:00
  [ "$(settings .nightlight)" = '{"from":"21:00","schedule":"hours","to":"06:00"}' ]
  echo '{"version":1,"nightlight":{"schedule":"hours","from":"soon","to":7}}' >"$HOME/.config/nova/shell.json"
  [ "$(nova-nightlight-schedule from 23:00)" = "From 23:00 to 07:00, every day." ]
}

@test "warmth: 4000 K at first, set in kelvin, kept beside the schedule, and taken at once by a night light on" {
  [ "$(nova-nightlight-warmth)" = "4000 K" ]
  nova-nightlight-schedule sunset
  nova-nightlight-warmth 3400
  [ "$(nova-nightlight-warmth)" = "3400 K" ]
  [ "$(settings .nightlight)" = '{"schedule":"sunset","temperature":3400}' ]
  ! grep -qx 'nova-toggle-nightlight on' "$CALLS"
  touch "$SCRATCH/on"
  nova-nightlight-warmth 2500
  grep -qx 'nova-toggle-nightlight on' "$CALLS"
  for wrong in 2499 5501 6500 warm "3000 K"; do
    run nova-nightlight-warmth "$wrong"
    [ "$status" -eq 1 ]
  done
  [ "$(nova-nightlight-warmth)" = "2500 K" ]
  echo '{"version":1,"nightlight":{"temperature":9000}}' >"$HOME/.config/nova/shell.json"
  [ "$(nova-nightlight-warmth)" = "4000 K" ]
}

@test "place: the weather's where it has coordinates, else the time zone's" {
  printf '# a comment\nIT\t+4154+01229\tEurope/Rome\nUS\t+404251-0740023\tAmerica/New_York\n' >"$NOVA_ZONEINFO/zone1970.tab"
  printf 'LI\t+4709+00931\tEurope/Vaduz\n' >"$NOVA_ZONEINFO/zone.tab"
  ln -s /usr/share/zoneinfo/Europe/Rome "$NOVA_LOCALTIME"
  [ "$(nova-nightlight-place)" = '{"latitude":41.9,"longitude":12.4833,"name":"Rome"}' ]
  ln -sfn ../usr/share/zoneinfo/posix/America/New_York "$NOVA_LOCALTIME"
  [ "$(nova-nightlight-place)" = '{"latitude":40.7142,"longitude":-74.0064,"name":"New York"}' ]
  ln -sfn /usr/share/zoneinfo/Europe/Vaduz "$NOVA_LOCALTIME"
  [ "$(nova-nightlight-place)" = '{"latitude":47.15,"longitude":9.5167,"name":"Vaduz"}' ]
  mkdir -p "$XDG_STATE_HOME/nova/settings"
  echo '{"name":"Malibu"}' >"$XDG_STATE_HOME/nova/settings/weather.json"
  [ "$(nova-nightlight-place)" = '{"latitude":47.15,"longitude":9.5167,"name":"Vaduz"}' ]
  echo '{"name":"Malibu","latitude":34.03,"longitude":-118.78}' >"$XDG_STATE_HOME/nova/settings/weather.json"
  [ "$(nova-nightlight-place)" = '{"latitude":34.03,"longitude":-118.78,"name":"Malibu"}' ]
}

@test "place: none for a zone that is no place, or with no tables" {
  printf 'IT\t+4154+01229\tEurope/Rome\n' >"$NOVA_ZONEINFO/zone1970.tab"
  ln -s /usr/share/zoneinfo/UTC "$NOVA_LOCALTIME"
  run nova-nightlight-place
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  ln -sfn /usr/share/zoneinfo/Europe/Rome "$NOVA_LOCALTIME"
  rm "$NOVA_ZONEINFO/zone1970.tab"
  run nova-nightlight-place
  [ "$status" -eq 1 ]
  rm "$NOVA_LOCALTIME"
  touch "$NOVA_LOCALTIME"
  run nova-nightlight-place
  [ "$status" -eq 1 ]
}
