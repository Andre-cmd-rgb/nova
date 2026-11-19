#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/bash\necho "$*" >"%s/summoned"\n' "$SCRATCH" >"$SCRATCH/bin/nova-shell"
  chmod +x "$SCRATCH/bin/nova-shell"
  PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

summoned() { cat "$SCRATCH/summoned"; }

@test "open: empty, or with the expression asked for, its words as one" {
  "$REPO_ROOT/src/cli/bin/nova-calculator"
  [ "$(summoned)" = 'shell summon nova.calculator {"expression":""}' ]
  "$REPO_ROOT/src/cli/bin/nova-calculator" 5 km in miles
  [ "$(summoned)" = 'shell summon nova.calculator {"expression":"5 km in miles"}' ]
}

@test "open: quotes and backslashes reach the window as typed" {
  "$REPO_ROOT/src/cli/bin/nova-calculator" '2*(3+4) "x" \ y'
  [ "$(summoned)" = 'shell summon nova.calculator {"expression":"2*(3+4) \"x\" \\ y"}' ]
}

@test "open: a leading minus is the expression, not an option" {
  "$REPO_ROOT/src/cli/bin/nova-calculator" -5 - 2
  [ "$(summoned)" = 'shell summon nova.calculator {"expression":"-5 - 2"}' ]
}

@test "help: --help says how it is used, and opens nothing" {
  run "$REPO_ROOT/src/cli/bin/nova-calculator" --help
  [ "$status" -eq 0 ]
  [[ $output == "Usage: nova calculator [expression]" ]]
  [ ! -e "$SCRATCH/summoned" ]
}

@test "open: no shell to open it in says so" {
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/bin/nova-shell"
  run "$REPO_ROOT/src/cli/bin/nova-calculator"
  [ "$status" -eq 1 ]
  [[ $output == *"is the shell running"* ]]
}
