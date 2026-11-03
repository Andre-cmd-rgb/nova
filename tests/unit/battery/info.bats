#!/usr/bin/env bats

# nova-battery-info, the power panel's battery line: the charge thresholds come
# from the kernel, not from UPower, whose own are what it would set if asked.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_POWER_SUPPLY_PATH="$SCRATCH/power_supply"
  BAT=$NOVA_POWER_SUPPLY_PATH/BAT0
  mkdir -p "$BAT" "$SCRATCH/bin"
  # UPower with its own 75-80% preset, as it reports on a ThinkPad.
  printf '%s\n' '  native-path:          BAT0' '    state:               charging' \
    '    energy-full:         68 Wh' '    energy-rate:         20 W' '    percentage:          42%' \
    '    charge-start-threshold:        75%' '    charge-end-threshold:          80%' >"$SCRATCH/report"
  cat >"$SCRATCH/bin/upower" <<'STUB'
#!/bin/bash
case $1 in
  -e) echo /org/freedesktop/UPower/devices/battery_BAT0 ;;
  -i) cat "$SCRATCH/report" ;;
esac
STUB
  chmod +x "$SCRATCH/bin/upower"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

info="$REPO_ROOT/src/cli/bin/nova-battery-info"

@test "no limit set: no threshold, whatever UPower would set" {
  echo 0 >"$BAT/charge_control_start_threshold"
  echo 100 >"$BAT/charge_control_end_threshold"
  run "$info" --shell
  [ "$status" -eq 0 ]
  [[ $output == *$'percentage\t42%'* ]]
  [[ $output != *threshold* ]]
}

@test "a limit set: the kernel's thresholds" {
  echo 55 >"$BAT/charge_control_start_threshold"
  echo 60 >"$BAT/charge_control_end_threshold"
  run "$info" --shell
  [[ $output == *$'threshold\t55-60%'* ]]
}

@test "a battery with no thresholds: none" {
  run "$info" --shell
  [ "$status" -eq 0 ]
  [[ $output != *threshold* ]]
}

# UPower's time in each of its units: seconds under a minute, minutes under an
# hour, hours under 60 hours, days after that.
time_shown() {
  sed -i '/time to/d' "$SCRATCH/report"
  printf '    time to %s:       %s\n' "$1" "$2" >>"$SCRATCH/report"
  "$info" --shell | sed -n 's/^time\t//p'
}

@test "the time left reads every unit UPower writes, to the nearest minute" {
  [ "$(time_shown full '45 seconds')" = '<1m' ]
  [ "$(time_shown full '5 seconds')" = '<1m' ]
  [ "$(time_shown full '1.5 minutes')" = 2m ]
  [ "$(time_shown empty '59.9 minutes')" = 1h ]
  [ "$(time_shown empty '1.0 hours')" = 1h ]
  [ "$(time_shown empty '1.2 hours')" = '1h 12m' ]
  [ "$(time_shown empty '3.5 hours')" = '3h 30m' ]
  [ "$(time_shown full '2.6 days')" = '62h 24m' ]
}

@test "the line says how long until full or empty" {
  time_shown full '1.2 hours' >/dev/null
  run "$info"
  [ "$output" = 'Battery 42%  ·  1h 12m to full  ·  20W / 68Wh' ]
}
