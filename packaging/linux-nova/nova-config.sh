#!/bin/bash
# Nova's kernel configuration deltas, applied on top of Arch's unmodified config.
#
#   nova-config.sh apply [.config]   set the deltas (run before `make olddefconfig`)
#   nova-config.sh check [.config]   assert the resolved config (run after it)
#
# Run from the kernel source tree: it uses ./scripts/config. This file is the whole
# list of differences between Arch's configuration and Nova's, so a reviewer can read
# the delta here instead of diffing 12,000 lines.
set -euo pipefail

mode=${1:-}
config=${2:-.config}

# Options Nova wants, in "SYMBOL=value" form (y, n or a number). `apply` sets them;
# `check` fails the build if the resolved config disagrees, which catches a Kconfig
# change that silently drops one of them.
WANTED=(
  # The BORE scheduler (added by the BORE patch; its Kconfig default is y).
  SCHED_BORE=y

  # 1000 Hz tick. Arch already builds with this; stated here so an upstream change
  # cannot silently take it away.
  HZ_1000=y
  HZ=1000

  # Full preemption, selectable at boot (preempt=none|voluntary|full). Arch already
  # builds with this too.
  PREEMPT=y
  PREEMPT_DYNAMIC=y
)

# Options that must end up off for the ones above to hold (they live in the same
# Kconfig choice groups).
UNWANTED=(
  HZ_100 HZ_250 HZ_300
  PREEMPT_NONE PREEMPT_VOLUNTARY
)

die() { printf 'nova-config: %s\n' "$*" >&2; exit 1; }

[[ -x scripts/config ]] || die "run from the kernel source tree (scripts/config not found)"
[[ -f $config ]] || die "no such config: $config"

apply() {
  local item sym val
  for item in "${WANTED[@]}"; do
    sym=${item%%=*}
    val=${item#*=}
    case $val in
      y) scripts/config --file "$config" --enable "$sym" ;;
      n) scripts/config --file "$config" --disable "$sym" ;;
      *) scripts/config --file "$config" --set-val "$sym" "$val" ;;
    esac
  done
  for sym in "${UNWANTED[@]}"; do
    scripts/config --file "$config" --disable "$sym"
  done
}

check() {
  local item sym val got failed=0
  for item in "${WANTED[@]}"; do
    sym=${item%%=*}
    val=${item#*=}
    got=$(scripts/config --file "$config" --state "$sym")
    # --state prints y, n, m, undef, or the value
    if [[ $got != "$val" ]]; then
      printf 'nova-config: CONFIG_%s is %s, expected %s\n' "$sym" "$got" "$val" >&2
      failed=1
    fi
  done
  for sym in "${UNWANTED[@]}"; do
    got=$(scripts/config --file "$config" --state "$sym")
    if [[ $got == y || $got == m ]]; then
      printf 'nova-config: CONFIG_%s is %s, expected it off\n' "$sym" "$got" >&2
      failed=1
    fi
  done
  (( failed == 0 )) || die "resolved config does not match Nova's deltas"
  printf 'nova-config: %d options verified\n' "$(( ${#WANTED[@]} + ${#UNWANTED[@]} ))"
}

case $mode in
  apply) apply ;;
  check) check ;;
  *) die "usage: nova-config.sh apply|check [.config]" ;;
esac
