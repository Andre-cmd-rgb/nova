#!/usr/bin/env bats

# `nova battery indicator` and `nova screentime indicator` with no state: said
# from the bar layout in shell.json, the plugin there or not.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home XDG_CONFIG_HOME=$SCRATCH/config NOVA_PATH=$SCRATCH/nova
  mkdir -p "$SCRATCH/bin" "$XDG_CONFIG_HOME/nova" "$NOVA_PATH/default"
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/bin/nova"
  chmod +x "$SCRATCH/bin/nova"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

layout() { # file id...
  local file=$1
  shift
  jq -n '{bar: {layout: {left: [], center: [], right: ($ARGS.positional | map({id: .}))}}}' \
    --args "$@" >"$file"
}

status_of() { # plugin
  run "$REPO_ROOT/src/shell/plugins/$1/bin/$1" indicator
}

@test "a plugin on the bar is said to be there" {
  layout "$XDG_CONFIG_HOME/nova/shell.json" nova.tray nova.screentime nova.batterylife
  status_of batterylife
  [ "$output" = "The plugin is in the bar layout." ]
  status_of screentime
  [ "$output" = "The plugin is in the bar layout." ]
}

@test "a plugin off the bar is said not to be" {
  layout "$XDG_CONFIG_HOME/nova/shell.json" nova.tray nova.power
  status_of batterylife
  [ "$output" = "The plugin is not in the bar layout." ]
  status_of screentime
  [ "$output" = "The plugin is not in the bar layout." ]
}

@test "Battery Life without a shell.json: the default layout" {
  layout "$NOVA_PATH/default/shell.json" nova.batterylife
  status_of batterylife
  [ "$output" = "The plugin is in the bar layout." ]
}
