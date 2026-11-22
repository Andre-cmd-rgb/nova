#!/usr/bin/env bats

# The install probe's memory budgets are the 4 GB test machine's: judged
# there, only said on a computer with more; and what the kernel keeps aside
# is judged against the reserve at rest, not while the full one is held.
load ../test_helper

probe_says() { # memtotal-kb function args...: the probe's lines, then its failures
  local memtotal=$1
  shift
  bash -c 'source "$1"; memtotal_kb=$2; shift 2; "$@"; echo "failures ${probe_failures:-0}"' _ \
    "$REPO_ROOT/tests/install/probe" "$memtotal" "$@"
}

@test "the probe judges a memory budget on the 4 GB test machine" {
  run probe_says 3900000 within_budget "the computer at rest" 1244 1100
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "probe: FAIL the computer at rest fits its memory budget (1244 of 1100 MB)" ]
  [ "${lines[-1]}" = "failures 1" ]
  run probe_says 3900000 within_budget "the computer at rest" 842 1100
  [ "${lines[0]}" = "probe: ok   the computer at rest fits its memory budget (842 of 1100 MB)" ]
  [ "${lines[-1]}" = "failures 0" ]
}

@test "the probe only says a memory figure on a computer with more than 4 GB" {
  run probe_says 32000000 within_budget "the computer at rest" 1244 1100
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "probe:      the computer at rest: 1244 MB (its budget, 1100 MB, is the 4 GB test machine's)" ]
  [ "${lines[-1]}" = "failures 0" ]
}

@test "what the kernel keeps aside is judged at rest, and only said with the full reserve held" {
  run probe_says 32000000 kept_aside 950 20 20
  [ "${lines[0]}" = "probe: FAIL the kernel keeps aside no more than its setting allows (950 of 900 MB)" ]
  [ "${lines[-1]}" = "failures 1" ]
  run probe_says 32000000 kept_aside 1700 125 20
  [ "${lines[0]}" = "probe:      the kernel keeps aside 1700 MB, the full reserve held (vm.watermark_scale_factor 125, at rest 20)" ]
  [ "${lines[-1]}" = "failures 0" ]
}
