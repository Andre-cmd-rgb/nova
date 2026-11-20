#!/usr/bin/env bats

# nova-automount, which the lock screen runs: the switch nova-sessiond mounts
# drives by, which names the session it was turned on in. The daemon's side
# is tested with it in src/session/daemon (automount.rs).

load ../test_helper

setup() {
  setup_scratch
  export HYPRLAND_INSTANCE_SIGNATURE=this-session
}

teardown() { teardown_scratch; }

helper="$REPO_ROOT/src/cli/bin/nova-automount"
switch() { echo "$XDG_RUNTIME_DIR/nova/automount"; }

@test "on writes this session's instance into the switch, whole and private" {
  run "$helper" on
  [ "$status" -eq 0 ]
  [ "$(cat "$(switch)")" = this-session ]
  [ "$(stat -c %a "$XDG_RUNTIME_DIR/nova")" = 700 ]
  # Written aside and moved in: nothing half-written is left.
  [ "$(ls -A "$XDG_RUNTIME_DIR/nova")" = automount ]
}

@test "on takes over a switch an earlier session left" {
  mkdir -p "$XDG_RUNTIME_DIR/nova"
  echo an-earlier-session >"$(switch)"
  run "$helper" on
  [ "$status" -eq 0 ]
  [ "$(cat "$(switch)")" = this-session ]
}

@test "off removes the switch, and is no failure when it is not there" {
  "$helper" on
  run "$helper" off
  [ "$status" -eq 0 ]
  [ ! -e "$(switch)" ]
  run "$helper" off
  [ "$status" -eq 0 ]
}

@test "outside a Hyprland session on turns nothing on" {
  unset HYPRLAND_INSTANCE_SIGNATURE
  run "$helper" on
  [ "$status" -eq 1 ]
  [ "$output" = "nova-automount: not running inside a Hyprland session" ]
  [ ! -e "$(switch)" ]
  HYPRLAND_INSTANCE_SIGNATURE=../elsewhere run "$helper" on
  [ "$status" -eq 1 ]
  [ ! -e "$(switch)" ]
}

@test "anything else is a usage error" {
  run "$helper" maybe
  [ "$status" -eq 2 ]
  run "$helper"
  [ "$status" -eq 2 ]
  run "$helper" on off
  [ "$status" -eq 2 ]
}
