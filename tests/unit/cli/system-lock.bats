#!/usr/bin/env bats

# nova-system-lock against stubs: the shell's lock first, then the
# screensaver stopped, the first keyboard layout, and 1Password locked when it
# runs, one lock of it at a time.

load ../test_helper

setup() {
  setup_scratch
  export CALLS=$SCRATCH/calls XDG_RUNTIME_DIR=$SCRATCH/run
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR"
  stub nova-shell
  stub nova-screensaver
  stub hyprctl
  stub nova-session-pgrep 'exit 1'
  stub 1password
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

lock() { "$REPO_ROOT/src/cli/bin/nova-system-lock"; }

@test "the lock, then the screensaver off and the first layout; no 1Password running, none locked" {
  run lock
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "$(printf '%s\n' 'nova-shell lock lock' 'nova-screensaver stop' 'hyprctl switchxkblayout all 0' "nova-session-pgrep -x 1password")" ]
}

@test "a shell that will not lock fails it, and nothing else is done" {
  stub nova-shell 'exit 1'
  run lock
  [ "$status" -ne 0 ]
  [ "$(cat "$CALLS")" = 'nova-shell lock lock' ]
}

@test "1Password running is locked too, in the background, and a lock of it under way is not doubled" {
  stub nova-session-pgrep 'exit 0'
  run lock
  [ "$status" -eq 0 ]
  for _ in {1..20}; do grep -q '^1password' "$CALLS" && break; sleep 0.1; done
  grep -qx '1password --lock' "$CALLS"
  # One still under way holds the lock.
  : >"$CALLS"
  exec {held}>"$XDG_RUNTIME_DIR/nova-1password-lock.lock"
  flock -n "$held"
  run lock
  sleep 0.3
  exec {held}>&-
  fails grep -q '^1password' "$CALLS"
}
