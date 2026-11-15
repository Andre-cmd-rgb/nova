#!/usr/bin/env bats

# nova-hyprland-monitor-scaling, behind the scale keys: the focused display's
# scale shown, set, or stepped through the presets, always to one Hyprland
# takes for the mode, kept in monitors.lua while it is on Nova's catch-all
# rule, and logged with who asked. Hyprland is a stub that answers `monitors`
# from $LIVE and logs every call.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" CALLS="$SCRATCH/calls" LIVE="$SCRATCH/live.json"
  unset HYPRLAND_INSTANCE_SIGNATURE XDG_STATE_HOME
  mkdir -p "$HOME" "$SCRATCH/bin"
  stub hyprctl '[[ $1 != monitors ]] || cat "$LIVE"'
  stub nova-monitor
  : >"$CALLS"
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:/usr/bin"
  focused eDP-1 2880 1800 1.25
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# The focused display, beside one that is not: name width height scale
focused() {
  jq -n --arg name "$1" --argjson w "$2" --argjson h "$3" --argjson s "$4" '[
    {name: "DP-9", width: 1920, height: 1080, refreshRate: 60, scale: 1, focused: false},
    {name: $name, width: $w, height: $h, refreshRate: 59.951, scale: $s, focused: true}]' >"$LIVE"
}

set_to() { # scale as Hyprland is told it
  grep -qxF "hyprctl eval hl.monitor({ output = \"eDP-1\", mode = \"2880x1800@59.951\", position = \"auto\", scale = $1 })" "$CALLS"
}

@test "the focused display's scale, as a plain number" {
  focused eDP-1 2880 1800 1.60000
  run nova-hyprland-monitor-scaling
  [ "$status" -eq 0 ]
  [ "$output" = 1.6 ]
}

@test "up and down step through the presets" {
  run nova-hyprland-monitor-scaling up
  [ "$status" -eq 0 ]
  set_to 1.6
  grep -qx "nova-monitor remember eDP-1 scale 1.6" "$CALLS"
  : >"$CALLS"
  focused eDP-1 2880 1800 1
  run nova-hyprland-monitor-scaling down
  set_to 1
}

@test "a scale goes up to the next one that divides the mode into whole pixels" {
  focused eDP-1 2560 1440 1
  run nova-hyprland-monitor-scaling 1.3
  [ "$status" -eq 0 ]
  grep -qF 'scale = 1.33333 })' "$CALLS"
}

@test "anything but a scale from 1 to 4 is the usage, and nothing changes" {
  for scale in 0.5 4.5 abc 1,5 -2; do
    run nova-hyprland-monitor-scaling "$scale"
    [ "$status" -eq 1 ]
    [ "$output" = "Usage: nova-hyprland-monitor-scaling [up|down|SCALE]" ]
  done
  fails grep -q eval "$CALLS"
}

@test "a display name that is not a plain connector name is refused, a space in it too" {
  for name in 'DP-1"' 'DP 1' ''; do
    focused "$name" 2560 1440 1
    run nova-hyprland-monitor-scaling 2
    [ "$status" -eq 1 ]
    [ "$output" = "Refusing unsafe monitor name" ]
  done
  fails grep -q eval "$CALLS"
}

@test "monitors.lua on Nova's catch-all keeps the scale, and GTK's whole one" {
  write_file "$HOME/.config/hypr/monitors.lua" 'local nova_monitor_scale = 1.25
local nova_gdk_scale = 1
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = nova_monitor_scale })
'
  nova-hyprland-monitor-scaling 1.6
  grep -qx "local nova_monitor_scale = 1.6" "$HOME/.config/hypr/monitors.lua"
  grep -qx "local nova_gdk_scale = 2" "$HOME/.config/hypr/monitors.lua"
  write_file "$HOME/.config/hypr/monitors.lua" 'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
hl.env("GDK_SCALE", "1")
'
  nova-hyprland-monitor-scaling 2
  grep -qxF 'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 2 })' "$HOME/.config/hypr/monitors.lua"
  grep -qxF 'hl.env("GDK_SCALE", "2")' "$HOME/.config/hypr/monitors.lua"
}

@test "each change is logged, with the time, the scales and the processes that asked" {
  nova-hyprland-monitor-scaling up
  log=$HOME/.local/state/nova/monitor-scaling.log
  [ "$(wc -l <"$log")" -eq 1 ]
  IFS=$'\t' read -r -a field <"$log"
  [[ ${field[0]} =~ ^at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]]
  [ "${field[*]:1:4}" = "requested=up current=1.25 new=1.6 monitor=eDP-1" ]
  [[ ${field[5]} =~ ^pid=[0-9]+$ ]]
  [ "${field[6]}" = "ppid=$BASHPID" ]
  [[ ${field[7]} == parent=?* && ${field[8]} =~ ^gppid=[0-9]+$ && ${field[9]} == grandparent=* ]]
}
