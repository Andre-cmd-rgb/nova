#!/usr/bin/env bats

# nova welcome: opens the welcome whenever asked; `first` only while the
# account has the marker its skel gave it, which `done` takes away.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" CALLS="$SCRATCH/calls"
  mkdir -p "$HOME" "$SCRATCH/bin"
  printf '#!/bin/bash\necho "$*" >>"$CALLS"\necho "${SHELL_ANSWER:-ok}"\n' >"$SCRATCH/bin/nova-shell"
  chmod +x "$SCRATCH/bin/nova-shell"
  export PATH="$SCRATCH/bin:$PATH"
  marker=$HOME/.local/state/nova/welcome-pending
}

teardown() { teardown_scratch; }

welcome() { "$REPO_ROOT/src/cli/bin/nova-welcome" "$@"; }

@test "nova welcome opens it, marker or not" {
  run welcome
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = 'shell summon nova.welcome {}' ]
}

@test "first opens it only while the marker from the skel is there, and done takes the marker away" {
  run welcome first
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS" ]
  mkdir -p "${marker%/*}"
  cp "$REPO_ROOT/data/skel/.local/state/nova/welcome-pending" "$marker"
  run welcome first
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = 'shell summon nova.welcome {}' ]
  run welcome done
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  # Done twice, or with no marker at all, is done.
  run welcome done
  [ "$status" -eq 0 ]
}

@test "the marker is under XDG_STATE_HOME when it is set" {
  export XDG_STATE_HOME="$SCRATCH/state"
  mkdir -p "$XDG_STATE_HOME/nova"
  : >"$XDG_STATE_HOME/nova/welcome-pending"
  run welcome first
  [ "$(cat "$CALLS")" = 'shell summon nova.welcome {}' ]
  welcome done
  [ ! -e "$XDG_STATE_HOME/nova/welcome-pending" ]
}

@test "a shell that will not open it is an error, and the marker stays" {
  mkdir -p "${marker%/*}"
  : >"$marker"
  SHELL_ANSWER=unknown run welcome first
  [ "$status" -eq 1 ]
  [[ $output == *"could not open the welcome"* ]]
  [ -e "$marker" ]
}

@test "anything else is a usage error" {
  run welcome again
  [ "$status" -eq 2 ]
  [[ $output == "Usage: nova welcome"* ]]
}
