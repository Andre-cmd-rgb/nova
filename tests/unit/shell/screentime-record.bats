#!/usr/bin/env bats

# `screentime record`, as the shell service writes: each pair in the hour
# after its @, or in this one, added to what that hour already holds. The idle
# take-back is negative seconds in the hours they were written to.

load ../test_helper

setup() {
  setup_scratch
  export XDG_STATE_HOME=$SCRATCH/state XDG_CONFIG_HOME=$SCRATCH/config
  days=$XDG_STATE_HOME/nova-screentime/days
}

teardown() { teardown_scratch; }

record() { "$REPO_ROOT/src/shell/plugins/screentime/bin/screentime" record "$@"; }

@test "seconds go to the hour after their @, across days" {
  record foot=120@2026-10-23T23 foot=60@2026-10-24T00 code=30@2026-10-24T00
  [ "$(cat "$days/2026-10-23.tsv")" = "$(printf 'foot\t23\t120')" ]
  [ "$(cat "$days/2026-10-24.tsv")" = "$(printf 'code\t0\t30\nfoot\t0\t60')" ]
}

@test "the idle take-back comes off the hours it was counted in" {
  record foot=120@2026-10-23T23 foot=60@2026-10-24T00 foot=300@2026-10-24T01
  record foot=-90@2026-10-23T23 foot=-60@2026-10-24T00
  [ "$(cat "$days/2026-10-23.tsv")" = "$(printf 'foot\t23\t30')" ]
  [ "$(cat "$days/2026-10-24.tsv")" = "$(printf 'foot\t1\t300')" ]
}

@test "a pair without an hour is this hour's, and a malformed hour is dropped" {
  record foot=60 code=60@2026-10-24T24 code=60@yesterday
  [ "$(cat "$days/$(date +%F).tsv")" = "$(printf 'foot\t%d\t60' "$((10#$(date +%H)))")" ]
  [ "$(ls "$days")" = "$(date +%F).tsv" ]
}
