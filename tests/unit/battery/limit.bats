#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export NOVA_POWER_SUPPLY="$SCRATCH/power_supply"
  export NOVA_BATTERY_LIMIT_STATE="$SCRATCH/state/battery-limit"
  export NOVA_BATTERY_LIMIT_APPLY="$REPO_ROOT/data/battery/nova-battery-limit-apply"
  mkdir -p "$NOVA_POWER_SUPPLY/AC" "$SCRATCH/bin"
  echo Mains >"$NOVA_POWER_SUPPLY/AC/type"
  # The CLI goes through pkexec, which here just runs the helper.
  printf '#!/bin/bash\nexec "$@"\n' >"$SCRATCH/bin/pkexec"
  chmod +x "$SCRATCH/bin/pkexec"
  export PATH="$SCRATCH/bin:$PATH"
  # shellcheck source=/dev/null
  source "$NOVA_BATTERY_LIMIT_APPLY"
  write() { firmware_write "$@"; }
}

teardown() { teardown_scratch; }

cli="$REPO_ROOT/data/battery/nova-battery-limit"
BAT="$BATS_TMPDIR/unset"

thinkpad() { # start end
  BAT=$NOVA_POWER_SUPPLY/BAT0
  mkdir -p "$BAT"
  echo "$1" >"$BAT/charge_control_start_threshold"
  echo "$2" >"$BAT/charge_control_end_threshold"
}

legion() { # charge_types
  BAT=$NOVA_POWER_SUPPLY/BAT0
  mkdir -p "$BAT"
  echo "$1" >"$BAT/charge_types"
}

# Stands in for the helper's write: thinkpad_acpi refuses a start at or above
# the end, and the reverse; charge_types brackets the type in force.
firmware_write() {
  local file=$1 value=$2 dir=${1%/*} start end
  case ${file##*/} in
    charge_control_start_threshold)
      end=$(<"$dir/charge_control_end_threshold")
      ((value < end)) || return 1
      ;;
    charge_control_end_threshold)
      if [[ -f $dir/charge_control_start_threshold ]]; then
        start=$(<"$dir/charge_control_start_threshold")
        ((start < value)) || return 1
      fi
      ;;
    charge_types)
      [[ -w $file ]] || return 1
      grep -qw "$value" "$file" || return 1
      sed -i -E "s/\[([A-Za-z_]+)\]/\1/; s/\b$value\b/[$value]/" "$file"
      return 0
      ;;
  esac
  printf '%s\n' "$value" >"$file"
}

# A bare `! cmd` never fails a bats test; this does.
fails() { if "$@"; then return 1; fi; }

@test "status: a computer without a battery has no limit" {
  run main status
  [ "$output" = '{"kind":"none","limit":null,"on":false}' ]
}

@test "status: a percentage, and 0 or 100 read as no limit" {
  thinkpad 75 80
  [ "$(main status)" = '{"kind":"threshold","limit":80,"on":true}' ]
  thinkpad 0 100
  [ "$(main status)" = '{"kind":"threshold","limit":100,"on":false}' ]
  thinkpad 0 0
  [ "$(main status)" = '{"kind":"threshold","limit":100,"on":false}' ]
}

@test "status: a Legion's switch, read from the bracketed type" {
  legion "[Standard] Long_Life"
  [ "$(main status)" = '{"kind":"switch","limit":null,"on":false}' ]
  legion "Standard [Long_Life]"
  [ "$(main status)" = '{"kind":"switch","limit":null,"on":true}' ]
}

@test "set: lowering the limit moves start first, so the firmware accepts both" {
  thinkpad 0 100
  main set 80
  [ "$(<"$BAT/charge_control_end_threshold")" = 80 ]
  [ "$(<"$BAT/charge_control_start_threshold")" = 75 ]
  main set 60
  [ "$(<"$BAT/charge_control_end_threshold")" = 60 ]
  [ "$(<"$BAT/charge_control_start_threshold")" = 55 ]
}

@test "set: raising it moves end first" {
  thinkpad 55 60
  main set 90
  [ "$(<"$BAT/charge_control_end_threshold")" = 90 ]
  [ "$(<"$BAT/charge_control_start_threshold")" = 85 ]
  main set off
  [ "$(<"$BAT/charge_control_end_threshold")" = 100 ]
  [ "$(<"$BAT/charge_control_start_threshold")" = 0 ]
}

@test "set: remembers the value, and restore puts it back" {
  thinkpad 0 100
  main set 080
  [ "$(<"$NOVA_BATTERY_LIMIT_STATE")" = 80 ]
  thinkpad 0 100 # the firmware forgot it
  main restore
  [ "$(<"$BAT/charge_control_end_threshold")" = 80 ]
}

@test "set: only an end threshold is enough" {
  BAT=$NOVA_POWER_SUPPLY/BAT1
  mkdir -p "$BAT"
  echo 100 >"$BAT/charge_control_end_threshold"
  main set 70
  [ "$(<"$BAT/charge_control_end_threshold")" = 70 ]
  [ ! -e "$BAT/charge_control_start_threshold" ]
}

@test "set: an end the battery refuses fails, and is not remembered" {
  thinkpad 0 100
  write() { return 1; }
  run main set 80
  [ "$status" -eq 1 ]
  [[ $output == *"did not accept a limit of 80%"* ]]
  [ ! -e "$NOVA_BATTERY_LIMIT_STATE" ]
}

@test "set: rejects anything but 50-100, on and off" {
  thinkpad 0 100
  for bad in 49 101 0 1000 abc "" "80 " "80;id" -80 8.5 ON; do
    run main set "$bad"
    [ "$status" -eq 1 ]
  done
  [ "$(<"$BAT/charge_control_end_threshold")" = 100 ]
  [ ! -e "$NOVA_BATTERY_LIMIT_STATE" ]
}

@test "set: a percentage battery refuses on, a switch refuses a percentage" {
  thinkpad 0 100
  run main set on
  [[ $output == *"takes a percentage"* ]]
  legion "[Standard] Long_Life"
  rm -r "$NOVA_POWER_SUPPLY/BAT0/charge_control_start_threshold" "$NOVA_POWER_SUPPLY/BAT0/charge_control_end_threshold"
  run main set 80
  [[ $output == *"is a switch"* ]]
}

@test "set: a Legion switches between Standard and Long_Life" {
  legion "[Standard] Long_Life Fast"
  main set on
  [ "$(<"$BAT/charge_types")" = "Standard [Long_Life] Fast" ]
  main set off
  [ "$(<"$BAT/charge_types")" = "[Standard] Long_Life Fast" ]
}

@test "restore: nothing remembered, nothing written; a corrupt value is refused" {
  thinkpad 0 100
  main restore
  [ "$(<"$BAT/charge_control_end_threshold")" = 100 ]
  mkdir -p "${NOVA_BATTERY_LIMIT_STATE%/*}"
  echo "100; reboot" >"$NOVA_BATTERY_LIMIT_STATE"
  run main restore
  [ "$status" -eq 1 ]
}

@test "set on no battery says so" {
  run main set 80
  [ "$status" -eq 1 ]
  [[ $output == *"no battery charge limit"* ]]
}

@test "the CLI sets, reads back and describes the limit" {
  thinkpad 0 100
  run "$cli" 80
  [ "$status" -eq 0 ]
  [ "$output" = "Charging stops at 80%." ]
  run "$cli" --json
  [ "$output" = '{"kind":"threshold","limit":80,"on":true}' ]
  run "$cli" off
  [[ $output == "No charge limit"* ]]
}

@test "the CLI reports a failed write and refuses extra arguments" {
  run "$cli" 30
  [ "$status" -eq 1 ]
  run "$cli" 80 90
  [ "$status" -eq 2 ]
  run "$cli" --bogus
  [ "$status" -eq 2 ]
  run "$cli"
  [ "$output" = "This computer has no battery charge limit." ]
}
