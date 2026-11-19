#!/usr/bin/env bats

# nova-session-pgrep: the user's processes of this session alone, those
# started with this HOME and this XDG_RUNTIME_DIR. Three copies of one
# program run: one of this session, one with a home of its own (a test's),
# one with a runtime folder of its own (a nested session's).

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home
  mkdir -p "$HOME" "$SCRATCH/bin" "$SCRATCH/other-home" "$SCRATCH/other-run"
  cp "$(command -v sleep)" "$SCRATCH/bin/novasleeper"
  PGREP=$REPO_ROOT/src/cli/bin/nova-session-pgrep
  "$SCRATCH/bin/novasleeper" 300 3>&- &
  ours=$!
  HOME=$SCRATCH/other-home "$SCRATCH/bin/novasleeper" 300 3>&- &
  other_home=$!
  XDG_RUNTIME_DIR=$SCRATCH/other-run "$SCRATCH/bin/novasleeper" 300 3>&- &
  other_runtime=$!
}

teardown() {
  kill "$ours" "$other_home" "$other_runtime" 2>/dev/null || true
  teardown_scratch
}

@test "finds this session's process alone" {
  run "$PGREP" -x novasleeper
  [ "$status" -eq 0 ]
  [ "$output" = "$ours" ]
}

@test "signals this session's process alone" {
  run "$PGREP" --signal TERM -x novasleeper
  [ "$status" -eq 0 ]
  for ((i = 0; i < 50; i++)); do running "$ours" || break; sleep 0.1; done
  fails running "$ours"
  running "$other_home"
  running "$other_runtime"
}

@test "with none in this session, finds nothing and says so as pgrep does" {
  kill "$ours"
  for ((i = 0; i < 50; i++)); do running "$ours" || break; sleep 0.1; done
  run "$PGREP" -x novasleeper
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "passes pgrep's options through, and never finds itself" {
  run "$PGREP" -f "novasleeper 300"
  [ "$status" -eq 0 ]
  [ "$output" = "$ours" ]
}

# What a test or a nested session did through a bare pgrep or pkill reached
# the user's own apps: it recoloured his terminals and ended his clipboard's
# watchers. Every lookup by name goes through nova-session-pgrep. Allowed: by
# parent (-P); the greeter's account ending its own Hyprland; nova update
# looking for root's update, whose environment no user can read.
@test "Nova reaches running apps by name only through nova-session-pgrep" {
  cd "$REPO_ROOT"
  run bash -c "git grep -nE '(^|[^-[:alnum:]_])(pgrep|pkill|killall)([^-[:alnum:]_]|\$)' -- src data installer \
      ':!src/cli/bin/nova-session-pgrep' ':!data/session/bin/nova-greeter-session' |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//)' |
    grep -vE 'pgrep (-n )?-P ' |
    grep -v 'nova-update-apply'"
  [ -z "$output" ] || { echo "$output"; false; }
}
