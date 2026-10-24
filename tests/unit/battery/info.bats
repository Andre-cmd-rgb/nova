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
  cat >"$SCRATCH/bin/upower" <<'STUB'
#!/bin/bash
case $1 in
  -e) echo /org/freedesktop/UPower/devices/battery_BAT0 ;;
  -i) printf '%s\n' '  native-path:          BAT0' '    state:               charging' \
        '    energy-full:         68 Wh' '    energy-rate:         20 W' '    percentage:          42%' \
        '    charge-start-threshold:        75%' '    charge-end-threshold:          80%' ;;
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
