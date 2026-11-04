#!/usr/bin/env bats

# nova-power-profile against a busctl that plays power-profiles-daemon and
# UPower: plugged in it is always performance, and the modes are the
# battery's.

load ../test_helper

setup() {
  setup_scratch
  export XDG_STATE_HOME="$SCRATCH/state" ACTIVE="$SCRATCH/active" CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  echo balanced >"$ACTIVE"
  : >"$CALLS"
  cat >"$SCRATCH/bin/busctl" <<'EOF'
#!/bin/bash
case "$*" in
  *OnBattery) if [[ ${ON_BATTERY:-} == 1 ]]; then echo "b true"; else echo "b false"; fi ;;
  *get-property*' Profiles')
    echo '{"type":"aa{sv}","data":[{"Profile":{"type":"s","data":"power-saver"}},{"Profile":{"type":"s","data":"balanced"}},{"Profile":{"type":"s","data":"performance"}}]}' ;;
  *get-property*' ActiveProfile') printf '{"type":"s","data":"%s"}\n' "$(cat "$ACTIVE")" ;;
  *set-property*) echo "${*: -1}" >"$ACTIVE"; echo "set ${*: -1}" >>"$CALLS" ;;
esac
EOF
  chmod +x "$SCRATCH/bin/busctl"
  export PATH="$SCRATCH/bin:$PATH"
  profile="$REPO_ROOT/src/cli/bin/nova-power-profile"
  remembered="$XDG_STATE_HOME/nova/power-profile/battery"
}

teardown() { teardown_scratch; }

@test "plugged in: always performance, whatever the battery's mode" {
  write_file "$remembered" $'power-saver\n'
  run "$profile" restore
  [ "$status" -eq 0 ]
  [ "$(cat "$ACTIVE")" = performance ]
}

@test "plugged in: nothing to choose, and a choice is kept for the battery" {
  run "$profile" list --active-state
  [ "$status" -eq 1 ]
  [[ $output == *"always full power"* ]]
  run "$profile" set power-saver
  [ "$status" -eq 0 ]
  [ "$(cat "$remembered")" = power-saver ]
  [ "$(cat "$ACTIVE")" = balanced ]
  [ ! -s "$CALLS" ]
}

@test "on battery: the mode chosen, kept, and put back at the next unplug" {
  export ON_BATTERY=1
  run "$profile" list --active-state
  [ "$output" = $'power-saver\t0\nbalanced\t1\nperformance\t0' ]
  "$profile" set performance
  [ "$(cat "$ACTIVE")" = performance ]
  [ "$(cat "$remembered")" = performance ]
  echo balanced >"$ACTIVE"
  "$profile" restore
  [ "$(cat "$ACTIVE")" = performance ]
}

@test "on battery with no mode chosen yet: balanced" {
  export ON_BATTERY=1
  echo performance >"$ACTIVE"
  "$profile" restore
  [ "$(cat "$ACTIVE")" = balanced ]
}

@test "a mode power-profiles-daemon does not offer is refused" {
  run "$profile" set turbo
  [ "$status" -eq 1 ]
  [ ! -e "$remembered" ]
}
