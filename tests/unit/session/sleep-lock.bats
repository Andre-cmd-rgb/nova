#!/usr/bin/env bats

# nova-system-sleep-lock against a stubbed shell: a lock that is up in time,
# one that is slow (the screens go off while it is waited for), one that is
# not up before logind suspends anyway (the screens stay off after the wake
# until it is), and the wake side of that.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" XDG_RUNTIME_DIR="$SCRATCH/run" POLLS="$SCRATCH/polls"
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR"
  : >"$POLLS"
  # The lock is secure from the SECURE_AFTER'th status call on.
  stub nova-shell 'if [[ $1 == lock && $2 == status ]]; then
      echo x >>"$POLLS"
      if (( $(wc -l <"$POLLS") > ${SECURE_AFTER:-0} )); then echo "{\"secure\":true}"; else echo "{\"requested\":true}"; fi
    fi'
  stub nova-brightness-display
  stub nova-notification-send
  stub nova-hyprland-monitor-clamshell
  stub busctl 'echo "t 45000000"'
  export PATH="$SCRATCH/bin:$PATH"
  lock="$REPO_ROOT/src/cli/bin/nova-system-sleep-lock"
  marker="$XDG_RUNTIME_DIR/nova/sleep-unsecured"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

@test "a lock up in time: nothing turned off, nothing left behind" {
  run "$lock" 3000
  [ "$status" -eq 0 ]
  fails grep -q nova-brightness-display "$CALLS"
  [ ! -e "$marker" ]
}

@test "logind's shipped window gives a slow lock 36 seconds" {
  grep -qx 'InhibitDelayMaxSec=45' "$REPO_ROOT/data/systemd/logind.conf.d/10-nova.conf"
  # The budget is logind's window less a fifth: asked with no lock coming,
  # the script would wait it out, so it is read from the code instead.
  grep -qx 'budget_cap_ms=36000' "$lock"
}

@test "a slow lock: the screens go off while it is waited for, and come back on it" {
  # About 2.5 seconds of polling before it is secure.
  SECURE_AFTER=25 run "$lock" 6000
  [ "$status" -eq 0 ]
  grep -qx 'nova-brightness-display off' "$CALLS"
  [ "$(tail -n 1 "$CALLS")" = 'nova-brightness-display on' ]
  [ ! -e "$marker" ]
}

@test "no lock before logind suspends: the screens stay off, and the wake is told" {
  SECURE_AFTER=100000 run "$lock" 2500
  [ "$status" -eq 1 ]
  [[ $output == *"suspending without a secure lock"* ]]
  [ -e "$marker" ]
  grep -qx 'nova-brightness-display off' "$CALLS"
  fails grep -qx 'nova-brightness-display on' "$CALLS"
  grep -q '^nova-notification-send .*Screen did not lock before suspend' "$CALLS"
}

@test "woken after that: the screens stay off until the lock is up, then come on" {
  mkdir -p "${marker%/*}"
  : >"$marker"
  SECURE_AFTER=5 run "$lock" --resumed
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  # Off from the first poll, on only once secure.
  [ "$(grep -m1 -n 'nova-brightness-display' "$CALLS" | cut -d: -f2)" = 'nova-brightness-display off' ]
  [ "$(tail -n 1 "$CALLS")" = 'nova-brightness-display on' ]
  [ "$(wc -l <"$POLLS")" -eq 6 ]
}

@test "woken after a suspend that was locked: nothing to do" {
  run "$lock" --resumed
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "the monitor starts the wake side once, when the marker says so" {
  mkdir -p "${marker%/*}"
  : >"$marker"
  grep -q 'sleep-unsecured' "$REPO_ROOT/src/cli/bin/nova-system-sleep-monitor"
  # Two at once: the second finds the first holding it.
  SECURE_AFTER=30 "$lock" --resumed &
  local first=$!
  sleep 0.5
  run "$lock" --resumed
  [ "$status" -eq 0 ]
  wait "$first"
  [ "$(grep -c 'nova-brightness-display on' "$CALLS")" -eq 1 ]
}
