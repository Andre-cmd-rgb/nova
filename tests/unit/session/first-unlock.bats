#!/usr/bin/env bats

# nova-session-first-unlock: a new account's first unlock shows the welcome,
# once; an account without the marker from Nova's skel never sees it.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" XDG_RUNTIME_DIR="$SCRATCH/run" XDG_STATE_HOME="$SCRATCH/state"
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR"
  printf '#!/bin/bash\necho "b false"\n' >"$SCRATCH/bin/busctl"
  for name in systemctl logger nova-notification-send; do
    printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n' "$name" >"$SCRATCH/bin/$name"
  done
  chmod +x "$SCRATCH"/bin/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

unlock() { "$REPO_ROOT/data/session/bin/nova-session-first-unlock"; }

@test "a new account is welcomed at its first unlock, and only then" {
  mkdir -p "$XDG_STATE_HOME/nova"
  cp "$REPO_ROOT/data/skel/.local/state/nova/welcome-pending" "$XDG_STATE_HOME/nova/"
  run unlock
  [ "$status" -eq 0 ]
  grep -q 'nova-notification-send .*Welcome to Nova.*Super+Space.*--exec nova-menu-keybindings' <(tr '\n' ' ' <"$CALLS")
  [ ! -e "$XDG_STATE_HOME/nova/welcome-pending" ]
  : >"$CALLS"
  run unlock
  fails grep -q '^nova-notification-send' "$CALLS"
}

@test "an account made before the welcome existed is not welcomed" {
  run unlock
  [ "$status" -eq 0 ]
  grep -qx 'systemctl --user start --no-block nova-unlocked.target' "$CALLS"
  fails grep -q '^nova-notification-send' "$CALLS"
}
