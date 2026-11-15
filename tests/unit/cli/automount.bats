#!/usr/bin/env bats

# nova-automount, which the lock screen runs: udiskie frozen under the lock,
# started and thawed once somebody unlocks.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

systemctl_stub() { # body, run after the call is logged
  printf '#!/bin/bash\necho "systemctl $*" >>"$CALLS"\n%s\n' "${1:-exit 0}" >"$SCRATCH/bin/systemctl"
  chmod +x "$SCRATCH/bin/systemctl"
}

helper="$REPO_ROOT/src/cli/bin/nova-automount"

@test "on starts it, and thaws it if the lock froze it" {
  systemctl_stub
  run "$helper" on
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "$(printf 'systemctl --user start nova-automount.service\nsystemctl --user thaw nova-automount.service')" ]
}

@test "on: a unit that was not frozen is no failure" {
  systemctl_stub 'case "$*" in *thaw*) exit 1 ;; esac'
  run "$helper" on
  [ "$status" -eq 0 ]
}

@test "off freezes it, so what was plugged in waits for the unlock" {
  systemctl_stub
  run "$helper" off
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "systemctl --user freeze nova-automount.service" ]
}

@test "off stops it where it cannot be frozen" {
  systemctl_stub 'case "$*" in *freeze*) exit 1 ;; esac'
  run "$helper" off
  [ "$status" -eq 0 ]
  grep -qx 'systemctl --user stop nova-automount.service' "$CALLS"
}

@test "anything else is a usage error" {
  run "$helper" maybe
  [ "$status" -eq 2 ]
}
