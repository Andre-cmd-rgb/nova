#!/usr/bin/env bats

# nova-session-first-unlock: a new account's first unlock opens the welcome,
# until the welcome is closed; an account without the marker from Nova's
# skel never sees it.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" XDG_RUNTIME_DIR="$SCRATCH/run" XDG_STATE_HOME="$SCRATCH/state"
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR"
  printf '#!/bin/bash\necho "b false"\n' >"$SCRATCH/bin/busctl"
  for name in systemctl logger; do
    printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n' "$name" >"$SCRATCH/bin/$name"
  done
  # The shell, which opens the welcome when asked.
  printf '#!/bin/bash\necho "nova-shell $*" >>"$CALLS"\necho ok\n' >"$SCRATCH/bin/nova-shell"
  ln -s "$REPO_ROOT/src/cli/bin/nova-welcome" "$SCRATCH/bin/nova-welcome"
  chmod +x "$SCRATCH"/bin/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

unlock() { "$REPO_ROOT/data/session/bin/nova-session-first-unlock"; }

@test "a new account is welcomed at each start until it closes the welcome" {
  mkdir -p "$XDG_STATE_HOME/nova"
  cp "$REPO_ROOT/data/skel/.local/state/nova/welcome-pending" "$XDG_STATE_HOME/nova/"
  run unlock
  [ "$status" -eq 0 ]
  grep -qx 'nova-shell shell summon nova.welcome {}' "$CALLS"
  # Not closed yet: the next start opens it again.
  : >"$CALLS"
  run unlock
  grep -qx 'nova-shell shell summon nova.welcome {}' "$CALLS"
  # Closed, on any page: never again.
  nova-welcome done
  [ ! -e "$XDG_STATE_HOME/nova/welcome-pending" ]
  : >"$CALLS"
  run unlock
  [ "$status" -eq 0 ]
  fails grep -q '^nova-shell' "$CALLS"
}

@test "an account made before the welcome existed is not welcomed" {
  run unlock
  [ "$status" -eq 0 ]
  grep -qx 'systemctl --user start --no-block nova-unlocked.target' "$CALLS"
  fails grep -q '^nova-shell' "$CALLS"
}

@test "a shell that cannot open the welcome leaves the unlock done, and the welcome for the next start" {
  mkdir -p "$XDG_STATE_HOME/nova"
  : >"$XDG_STATE_HOME/nova/welcome-pending"
  printf '#!/bin/bash\necho "nova-shell is not running" >&2\nexit 1\n' >"$SCRATCH/bin/nova-shell"
  run unlock
  [ "$status" -eq 0 ]
  [ -e "$XDG_RUNTIME_DIR/nova/unlocked-once" ]
  [ -e "$XDG_STATE_HOME/nova/welcome-pending" ]
}
