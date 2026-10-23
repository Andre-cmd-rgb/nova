#!/usr/bin/env bats

# nova power undervolt and its root half, with pkexec, systemctl and the
# nova-undervolt tool stubbed. The tool's own logic (the mailbox, the holds)
# has Rust tests in src/power/undervolt.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" NOVA_UNDERVOLT_STATE="$SCRATCH/state"
  export NOVA_POWER_UNDERVOLT_APPLY="$REPO_ROOT/src/power/bin/nova-power-undervolt-apply"
  export NOVA_UNDERVOLT="$SCRATCH/bin/nova-undervolt"
  mkdir -p "$SCRATCH/bin"
  stub pkexec '"$@"'
  stub systemctl
  stub nova-undervolt 'echo "the status"'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

undervolt() { "$REPO_ROOT/src/cli/bin/nova-power-undervolt" "$@"; }

@test "with nothing else, it says what is set" {
  run undervolt
  [ "$status" -eq 0 ]
  [ "$output" = "the status" ]
  run undervolt status --json
  grep -qx 'nova-undervolt status --json' "$CALLS"
}

@test "set: the offset is written and applied as root, the old one off first" {
  mkdir -p "$NOVA_UNDERVOLT_STATE"
  echo "the reason" >"$NOVA_UNDERVOLT_STATE/held"
  run undervolt set -70
  [ "$status" -eq 0 ]
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = -70 ]
  [ ! -e "$NOVA_UNDERVOLT_STATE/held" ]
  [ "$(grep -v '^nova-undervolt' "$CALLS" | paste -sd '|')" = "pkexec $NOVA_POWER_UNDERVOLT_APPLY set -70|systemctl stop nova-undervolt.service|systemctl start nova-undervolt.service" ]
  [[ $output == *"the status"* ]]
}

@test "set takes only a whole number of millivolts from -150 to -1" {
  for bad in 70 -0 -070 -151 -1000 -7.5 abc ''; do
    run "$NOVA_POWER_UNDERVOLT_APPLY" set "$bad"
    [ "$status" -eq 1 ]
    [[ $output == *"from -150 to -1"* ]]
  done
  [ ! -e "$NOVA_UNDERVOLT_STATE/offset" ]
  ! grep -q systemctl "$CALLS"
  run "$NOVA_POWER_UNDERVOLT_APPLY" set -150
  [ "$status" -eq 0 ]
}

@test "on applies the offset again after a hold; with none set, it says so" {
  run undervolt on
  [ "$status" -eq 1 ]
  [[ $output == *"no undervolt is set"* ]]
  mkdir -p "$NOVA_UNDERVOLT_STATE"
  echo -70 >"$NOVA_UNDERVOLT_STATE/offset"
  echo "a freeze" >"$NOVA_UNDERVOLT_STATE/held"
  run undervolt on
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_UNDERVOLT_STATE/held" ]
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = -70 ]
  grep -qx 'systemctl start nova-undervolt.service' "$CALLS"
}

@test "off takes it off, then forgets it" {
  mkdir -p "$NOVA_UNDERVOLT_STATE"
  echo -70 >"$NOVA_UNDERVOLT_STATE/offset"
  run undervolt off
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_UNDERVOLT_STATE/offset" ]
  grep -qx 'systemctl stop nova-undervolt.service' "$CALLS"
  ! grep -q 'systemctl start' "$CALLS"
}

@test "a password not given changes nothing and says nothing more" {
  stub pkexec 'exit 126'
  run undervolt set -70
  [ "$status" -eq 126 ]
  [ ! -e "$NOVA_UNDERVOLT_STATE/offset" ]
  ! grep -q '^nova-undervolt' "$CALLS"
}

@test "anything else is a usage error" {
  run undervolt set
  [ "$status" -eq 2 ]
  run undervolt status --yaml
  [ "$status" -eq 2 ]
  run undervolt deeper
  [ "$status" -eq 2 ]
}
