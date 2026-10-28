#!/usr/bin/env bats

# nova power gpu toggle, the menu's Toggle, Discrete GPU: switched at once
# through the GPU's polkit rule, and said in a notification. nova power and the
# root half are stubs; the card is a file saying on or off.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" CARD="$SCRATCH/card"
  mkdir -p "$SCRATCH/lib" "$SCRATCH/bin"
  cp "$REPO_ROOT/src/cli/bin/nova-power-gpu" "$SCRATCH/lib/"
  stub lib/nova-hw-detect 'echo thinkpad-p1-gen4i'
  stub lib/nova-power 'case $1 in
    status) printf "\n  power source   AC\n  discrete GPU   %s\n" "$(cat "$CARD")"
      [[ -z ${HELD:-} ]] || printf "  held by        %s\n" "$HELD"; echo ;;
  esac'
  # The root half: off only when nothing holds the card.
  stub bin/nova-power-gpu-mode-apply 'if [[ $(cat "$CARD") == off ]]; then echo on >"$CARD"
    elif [[ -z ${HELD:-} ]]; then echo off >"$CARD"; else exit 1; fi'
  stub bin/pkexec '"$@"'
  stub bin/nova-notification-send
  export NOVA_POWER_GPU_APPLY="$SCRATCH/bin/nova-power-gpu-mode-apply" PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # path [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "${1##*/}" "${2:-exit 0}" >"$SCRATCH/$1"
  chmod +x "$SCRATCH/$1"
}

toggle() { "$SCRATCH/lib/nova-power-gpu" toggle; }

@test "toggle: off to on, through the GPU's polkit rule, and said" {
  echo off >"$CARD"
  run toggle
  [ "$status" -eq 0 ]
  [ "$(cat "$CARD")" = on ]
  grep -qx "pkexec $NOVA_POWER_GPU_APPLY toggle" "$CALLS"
  grep -qx 'nova-notification-send -g 󰢮 The discrete GPU is on' "$CALLS"
}

@test "toggle: on to off" {
  echo on >"$CARD"
  run toggle
  [ "$(cat "$CARD")" = off ]
  grep -qx 'nova-notification-send -g 󰢮 The discrete GPU is off' "$CALLS"
}

@test "toggle: a card in use stays on, and says what holds it" {
  echo on >"$CARD"
  HELD="steam (4242)" run toggle
  [ "$status" -eq 0 ]
  [ "$(cat "$CARD")" = on ]
  grep -qx 'nova-notification-send -u normal -g 󰢮 The discrete GPU stays on In use by steam (4242): close it first.' "$CALLS"
}

@test "toggle: a dismissed authentication says nothing" {
  echo off >"$CARD"
  stub bin/pkexec 'exit 126'
  run toggle
  [ "$status" -eq 0 ]
  [ "$(cat "$CARD")" = off ]
  fails grep -q nova-notification-send "$CALLS"
}
