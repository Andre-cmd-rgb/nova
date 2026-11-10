#!/usr/bin/env bats

# nova-power-profile against a busctl that plays power-profiles-daemon and
# UPower: plugged in it is always performance, and on battery it starts in
# power-saver, with a mode chosen there kept only until the next plug-in.

load ../test_helper

setup() {
  setup_scratch
  export XDG_RUNTIME_DIR="$SCRATCH/run" ACTIVE="$SCRATCH/active" CALLS="$SCRATCH/calls"
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
  chosen="$XDG_RUNTIME_DIR/nova/power-profile"
}

teardown() { teardown_scratch; }

@test "plugged in: always performance, whatever was chosen on battery" {
  write_file "$chosen" $'power-saver\n'
  run "$profile" restore
  [ "$status" -eq 0 ]
  [ "$(cat "$ACTIVE")" = performance ]
}

@test "plugged in: nothing to choose, and nothing kept for the battery" {
  run "$profile" list --active-state
  [ "$status" -eq 1 ]
  [[ $output == *"always full power"* ]]
  run "$profile" set balanced
  [ "$status" -eq 1 ]
  [[ $output == *"starts in power-saver"* ]]
  [ ! -e "$chosen" ]
  [ "$(cat "$ACTIVE")" = balanced ]
  [ ! -s "$CALLS" ]
}

@test "on battery: a mode chosen lasts until the next plug-in" {
  export ON_BATTERY=1
  run "$profile" list --active-state
  [ "$output" = $'power-saver\t0\nbalanced\t1\nperformance\t0' ]
  "$profile" set performance
  [ "$(cat "$ACTIVE")" = performance ]
  # The shell starting again on battery keeps it.
  echo balanced >"$ACTIVE"
  "$profile" restore
  [ "$(cat "$ACTIVE")" = performance ]
  # A plug-in ends it, and the next unplug starts in power-saver.
  ON_BATTERY=0 "$profile" restore
  [ "$(cat "$ACTIVE")" = performance ]
  [ ! -e "$chosen" ]
  "$profile" restore
  [ "$(cat "$ACTIVE")" = power-saver ]
}

@test "on battery with no mode chosen: power-saver, whatever was active" {
  export ON_BATTERY=1
  echo performance >"$ACTIVE"
  "$profile" restore
  [ "$(cat "$ACTIVE")" = power-saver ]
}

@test "on battery, a chosen mode power-profiles-daemon no longer offers: power-saver" {
  export ON_BATTERY=1
  write_file "$chosen" $'turbo\n'
  "$profile" restore
  [ "$(cat "$ACTIVE")" = power-saver ]
}

@test "a mode power-profiles-daemon does not offer is refused" {
  export ON_BATTERY=1
  run "$profile" set turbo
  [ "$status" -eq 1 ]
  [ ! -e "$chosen" ]
}
