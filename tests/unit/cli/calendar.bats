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

@test "open: on today's week, or the view and the day asked for" {
  "$REPO_ROOT/src/cli/bin/nova-calendar"
  [ "$(summoned)" = 'shell summon nova.calendar {"page":"","date":""}' ]
  "$REPO_ROOT/src/cli/bin/nova-calendar" month 2026-10-29
  [ "$(summoned)" = 'shell summon nova.calendar {"page":"month","date":"2026-10-29"}' ]
}

@test "open: a day in words, as date reads it" {
  "$REPO_ROOT/src/cli/bin/nova-calendar" next friday
  [ "$(summoned)" = "shell summon nova.calendar {\"page\":\"\",\"date\":\"$(date -d 'next friday' +%F)\"}" ]
}

@test "open: what is not a day is refused, and nothing opens" {
  run "$REPO_ROOT/src/cli/bin/nova-calendar" frobnicate
  [ "$status" -eq 2 ]
  [[ $output == *"not a day"* ]]
  [ ! -e "$SCRATCH/summoned" ]
}

@test "open: no shell to open it in says so" {
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/bin/nova-shell"
  run "$REPO_ROOT/src/cli/bin/nova-calendar"
  [ "$status" -eq 1 ]
  [[ $output == *"is the shell running"* ]]
}

@test "open: next week and next month are days, after the view or without one" {
  "$REPO_ROOT/src/cli/bin/nova-calendar" next week
  [ "$(summoned)" = "shell summon nova.calendar {\"page\":\"\",\"date\":\"$(date -d 'next week' +%F)\"}" ]
  "$REPO_ROOT/src/cli/bin/nova-calendar" month next month
  [ "$(summoned)" = "shell summon nova.calendar {\"page\":\"month\",\"date\":\"$(date -d 'next month' +%F)\"}" ]
}
