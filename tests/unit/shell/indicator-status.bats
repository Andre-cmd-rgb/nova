#!/usr/bin/env bats

# `nova battery indicator` and `nova screentime indicator` with no state: said
# from the bar layout in shell.json, the plugin there or not. Screen Time's is
# its widget (nova.screentime-today), apart from Screen Time itself.

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
  layout "$XDG_CONFIG_HOME/nova/shell.json" nova.tray nova.screentime-today nova.batterylife
  status_of batterylife
  [ "$output" = "The plugin is in the bar layout." ]
  status_of screentime
  [ "$output" = "Screen Time is on the bar." ]
  # The widget on the bar is not Screen Time on.
  run "$REPO_ROOT/src/shell/plugins/screentime/bin/screentime" enabled
  [ "$status" -ne 0 ]
}

@test "a plugin off the bar is said not to be" {
  layout "$XDG_CONFIG_HOME/nova/shell.json" nova.tray nova.power
  status_of batterylife
  [ "$output" = "The plugin is not in the bar layout." ]
  status_of screentime
  [ "$output" = "Screen Time is not on the bar." ]
}

@test "Screen Time records without its widget on the bar" {
  jq -n '{bar: {layout: {left: [], center: [], right: [{id: "nova.tray"}]}}, plugins: [{id: "nova.screentime"}]}' \
    >"$XDG_CONFIG_HOME/nova/shell.json"
  run "$REPO_ROOT/src/shell/plugins/screentime/bin/screentime" enabled
  [ "$status" -eq 0 ]
  status_of screentime
  [ "$output" = "Screen Time is not on the bar." ]
}

@test "an older file's Screen Time entry in the bar: it records, and its widget is not on the bar" {
  layout "$XDG_CONFIG_HOME/nova/shell.json" nova.tray nova.screentime
  run "$REPO_ROOT/src/shell/plugins/screentime/bin/screentime" enabled
  [ "$status" -eq 0 ]
  status_of screentime
  [ "$output" = "Screen Time is not on the bar." ]
}

@test "a plugin switched off keeps its place in the layout, and is said not to be on the bar" {
  jq -n '{bar: {layout: {left: [], center: [], right: [{id: "nova.tray"}, {id: "nova.screentime-today", off: true}, {id: "nova.screentime", off: true}, {id: "nova.batterylife", off: true}]}}}' \
    >"$XDG_CONFIG_HOME/nova/shell.json"
  status_of batterylife
  [ "$output" = "The plugin is not in the bar layout." ]
  status_of screentime
  [ "$output" = "Screen Time is not on the bar." ]
  # Nor is Screen Time on: an older file's entry switched off is off.
  run "$REPO_ROOT/src/shell/plugins/screentime/bin/screentime" enabled
  [ "$status" -ne 0 ]
}

@test "the widget on and off goes through the bar's verbs, for the widget alone" {
  printf '#!/bin/bash\necho "$*" >>"%s/calls"\n' "$SCRATCH" >"$SCRATCH/bin/nova"
  layout "$XDG_CONFIG_HOME/nova/shell.json" nova.tray
  run "$REPO_ROOT/src/shell/plugins/screentime/bin/screentime" indicator on
  [ "$status" -eq 0 ]
  [ "$output" = "Screen Time is on the bar, and shows once it is on: nova screentime on" ]
  jq -n '{bar: {layout: {right: [{id: "nova.screentime-today"}]}}, plugins: [{id: "nova.screentime"}]}' >"$XDG_CONFIG_HOME/nova/shell.json"
  run "$REPO_ROOT/src/shell/plugins/screentime/bin/screentime" indicator off
  [ "$output" = "Screen Time is off the bar. It still records." ]
  [ "$(cat "$SCRATCH/calls")" = $'bar put nova.screentime-today\nbar remove nova.screentime-today' ]
}

@test "a bare id in the bar is an entry, as the shell reads it, and a name where the shell does not look is none" {
  jq -n '{bar: {layout: {left: [], center: [], right: ["nova.tray", "nova.screentime", "nova.screentime-today", "nova.batterylife"]}}}' \
    >"$XDG_CONFIG_HOME/nova/shell.json"
  status_of batterylife
  [ "$output" = "The plugin is in the bar layout." ]
  status_of screentime
  [ "$output" = "Screen Time is on the bar." ]
  run "$REPO_ROOT/src/shell/plugins/screentime/bin/screentime" enabled
  [ "$status" -eq 0 ]
  # Plugins hold objects, disabledPlugins names plugins switched off, and
  # nothing else names a plugin on (services/Layout.js, named and find).
  jq -n '{bar: {layout: {right: ["nova.tray"]}, other: {id: "nova.batterylife"}}, plugins: ["nova.screentime"],
    disabledPlugins: ["nova.screentime"], other: {id: "nova.screentime"}}' >"$XDG_CONFIG_HOME/nova/shell.json"
  status_of batterylife
  [ "$output" = "The plugin is not in the bar layout." ]
  run "$REPO_ROOT/src/shell/plugins/screentime/bin/screentime" enabled
  [ "$status" -ne 0 ]
}

@test "Battery Life without a shell.json: the default layout" {
  layout "$NOVA_PATH/default/shell.json" nova.batterylife
  status_of batterylife
  [ "$output" = "The plugin is in the bar layout." ]
}
