#!/usr/bin/env bats

# nova-battery-low, run by the shell's battery service at 10%: one warning
# that goes by itself, never a critical one that stays up after the charger is
# in, and the battery-low hooks either way.

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/bin"
  for cmd in nova-notification-send nova-hook; do
    # shellcheck disable=SC2016 # expanded when the stub runs
    printf '#!/bin/bash\necho "%s $*" >>"$SCRATCH/calls"\n' "$cmd" >"$SCRATCH/bin/$cmd"
    chmod +x "$SCRATCH/bin/$cmd"
  done
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

low="$REPO_ROOT/src/cli/bin/nova-battery-low"

@test "the warning says how much is left, plainly, and goes by itself" {
  run "$low" 10
  [ "$status" -eq 0 ]
  grep -q '^nova-notification-send .*-u normal Battery low 10% left. Plug in the charger soon. -t ' "$SCRATCH/calls"
  fails grep -q critical "$SCRATCH/calls"
  grep -qx 'nova-hook battery-low 10' "$SCRATCH/calls"
}

@test "the hooks run when the notification cannot be sent" {
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/bin/nova-notification-send"
  run "$low" 9
  [ "$status" -eq 0 ]
  grep -qx 'nova-hook battery-low 9' "$SCRATCH/calls"
}
