#!/usr/bin/env bats

# The laptop's panel beside other displays: nova-hyprland-monitor-clamshell
# turns it off with the lid shut on a dock and brings it back at its scale,
# and nova-hyprland-monitor-internal and -mirror turn it off or mirror it by
# hand. (The passes as displays come and go are nova-sessiond's, tested in
# src/session/daemon.) Hyprland is a stub that answers `monitors` from $LIVE
# and logs every call; the lid and the DRM connectors are directories.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_RUNTIME_DIR="$SCRATCH/run" CALLS="$SCRATCH/calls" LIVE="$SCRATCH/live.json"
  export NOVA_LID_PATH="$SCRATCH/lid" NOVA_DRM_PATH="$SCRATCH/drm" NOVA_DMI_PATH="$SCRATCH/dmi"
  # Nova's shipped files are the repo's, never those installed here.
  export NOVA_PATH="$SCRATCH/nova"
  mkdir -p "$NOVA_PATH/default/hypr"
  ln -s "$REPO_ROOT/data/hypr/toggles" "$NOVA_PATH/default/hypr/toggles"
  unset HYPRLAND_INSTANCE_SIGNATURE XDG_STATE_HOME
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$SCRATCH/bin"
  # Without `all`, Hyprland leaves out the displays that are off or mirror
  # another. A reload takes up $SCRATCH/after-reload.json when there is one.
  stub hyprctl '
case $1 in
  monitors)
    if [[ ${2:-} == all ]]; then cat "$LIVE"; else jq "map(select(.disabled == false and .mirrorOf == \"none\"))" "$LIVE"; fi ;;
  reload) [[ ! -e $SCRATCH/after-reload.json ]] || mv "$SCRATCH/after-reload.json" "$LIVE" ;;
esac
exit 0'
  stub nova-notification-send
  : >"$CALLS"
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:/usr/bin"
  toggles=$HOME/.local/state/nova/toggles/hypr
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# A display as `monitors all -j` lists it: name scale on|off [mirror-of]
display() {
  jq -cn --arg name "$1" --argjson scale "$2" --argjson off "$([[ $3 == off ]] && echo true || echo false)" --arg mirror "${4:-none}" \
    '{name: $name, width: 2880, height: 1800, refreshRate: 60, scale: $scale, disabled: $off, focused: false, mirrorOf: $mirror}'
}
displays() { local IFS=,; echo "[$*]" >"${OUT:-$LIVE}"; }
after_reload() { OUT=$SCRATCH/after-reload.json displays "$@"; }

lid() { write_file "$NOVA_LID_PATH/LID0/state" "state:      $1"$'\n'; }
docked() { write_file "$NOVA_DRM_PATH/card1-eDP-1/status" $'connected\n'; write_file "$NOVA_DRM_PATH/card1-DP-2/status" $'connected\n'; }
panel_rule='hl.monitor({ output = "eDP-1", disabled = true })'
clamshell() { run nova-hyprland-monitor-clamshell; }

@test "clamshell: the lid shut on a dock turns the panel off, and keeps its scale for later" {
  displays "$(display eDP-1 1.6 on)" "$(display DP-2 1 on)"
  lid closed
  docked
  clamshell
  [ "$status" -eq 0 ]
  [ "$(cat "$toggles/internal-monitor-clamshell.lua")" = "$panel_rule" ]
  [ "$(cat "$toggles/internal-monitor-scale")" = 1.6 ]
  grep -qx "hyprctl reload" "$CALLS"
}

@test "clamshell: with nothing moved, Hyprland is asked once and told nothing" {
  displays "$(display eDP-1 1.6 off)" "$(display DP-2 1 on)"
  write_file "$toggles/internal-monitor-clamshell.lua" "$panel_rule"$'\n'
  lid closed
  docked
  clamshell
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "hyprctl monitors all -j" ]
}

@test "clamshell: the lid opened, the rule goes and the panel comes back at the scale monitors.lua sets" {
  write_file "$HOME/.config/hypr/monitors.lua" $'hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x0", scale = 1.5 })\n'
  write_file "$toggles/internal-monitor-clamshell.lua" "$panel_rule"$'\n'
  displays "$(display eDP-1 2 off)" "$(display DP-2 1 on)"
  after_reload "$(display eDP-1 2 on)" "$(display DP-2 1 on)"
  lid open
  docked
  clamshell
  [ "$status" -eq 0 ]
  [ ! -e "$toggles/internal-monitor-clamshell.lua" ]
  [ "$(grep -v '^hyprctl monitors' "$CALLS")" = 'hyprctl reload
hyprctl eval hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x0", scale = 1.5 })
hyprctl dispatch hl.dsp.dpms({ action = "enable", monitor = "eDP-1" })' ]
}

@test "clamshell: undocked with the lid still shut, the panel is not lit: it is the lid shutting now" {
  # An update or Caffeine holding the lid keeps logind from sleeping, and the
  # lid did not move, so no bind runs: the pass runs the lid bind's command.
  stub nova-caffeine
  write_file "$toggles/internal-monitor-clamshell.lua" "$panel_rule"$'\n'
  displays "$(display eDP-1 2 off)"
  after_reload "$(display eDP-1 2 on)"
  lid closed
  clamshell
  [ "$status" -eq 0 ]
  [ ! -e "$toggles/internal-monitor-clamshell.lua" ]
  grep -qx "nova-caffeine close" "$CALLS"
  fails grep -q 'action = "enable"' "$CALLS"
}

@test "clamshell: what Settings keeps for the panel wins over monitors.lua" {
  write_file "$HOME/.config/hypr/monitors.lua" $'hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x0", scale = 1.5 })\n'
  write_file "$HOME/.local/state/nova/monitors.json" '{"eDP-1": {"scale": 1.25, "position": "1920x0"}}'
  displays "$(display eDP-1 2 on)"
  lid open
  clamshell
  grep -qxF 'hyprctl eval hl.monitor({ output = "eDP-1", mode = "preferred", position = "1920x0", scale = 1.25 })' "$CALLS"
}

@test "clamshell: a scale through a local, and commented-out rules that do not count" {
  write_file "$HOME/.config/hypr/monitors.lua" 'local nova_monitor_scale = 1.6 -- the panel
-- hl.monitor({ output = "eDP-1", scale = 3 })
--[[ hl.monitor({ output = "eDP-1", scale = 3 }) ]] hl.monitor({ output = "", mode = "preferred", position = "auto", scale = nova_monitor_scale })
'
  displays "$(display eDP-1 2 on)"
  lid open
  clamshell
  grep -qxF 'hyprctl eval hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1.6 })' "$CALLS"
}

@test "clamshell: a scale left to Hyprland is not touched, and a panel still off gets the one it had" {
  cp "$REPO_ROOT/data/skel/.config/hypr/monitors.lua" "$HOME/.config/hypr/monitors.lua" 2>/dev/null ||
    write_file "$HOME/.config/hypr/monitors.lua" "$(cat "$REPO_ROOT/data/skel/.config/hypr/monitors.lua")"
  displays "$(display eDP-1 1.75 on)"
  lid open
  clamshell
  fails grep -q eval "$CALLS"
  write_file "$toggles/internal-monitor-scale" $'1.6\n'
  displays "$(display eDP-1 1.75 off)" "$(display DP-2 1 on)"
  clamshell
  grep -qxF 'hyprctl eval hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1.6 })' "$CALLS"
}

@test "clamshell: a panel turned off by hand stays off while another display is on" {
  write_file "$toggles/internal-monitor-disable.lua" "$panel_rule"$'\n'
  displays "$(display eDP-1 2 off)" "$(display DP-2 1 on)"
  lid open
  docked
  clamshell
  [ "$status" -eq 0 ]
  [ -e "$toggles/internal-monitor-disable.lua" ]
  fails grep -q 'eval\|dispatch\|reload' "$CALLS"
}

@test "clamshell: the panel off by hand, or mirrored, comes back when the other display goes" {
  write_file "$toggles/internal-monitor-disable.lua" "$panel_rule"$'\n'
  write_file "$toggles/internal-monitor-mirror.lua" $'x\n'
  displays "$(display eDP-1 2 off)"
  lid open
  clamshell
  [ "$status" -eq 0 ]
  [ ! -e "$toggles/internal-monitor-disable.lua" ]
  [ ! -e "$toggles/internal-monitor-mirror.lua" ]
}

@test "clamshell: a panel name that is not a plain connector name is refused" {
  displays "$(display 'eDP-1"x' 2 on)" "$(display DP-2 1 on)"
  lid closed
  docked
  clamshell
  [ "$status" -eq 1 ]
  [ "$output" = "Refusing unsafe internal monitor name" ]
  [ ! -e "$toggles/internal-monitor-clamshell.lua" ]
  fails grep -q 'eval\|reload' "$CALLS"
}

@test "internal off: never the only display, and with another one on, a rule and a reload" {
  displays "$(display eDP-1 2 on)"
  run nova-hyprland-monitor-internal off
  [ "$status" -eq 1 ]
  grep -qF "nova-notification-send -g 󰍹 Can't disable the only active display" "$CALLS"
  displays "$(display eDP-1 2 on)" "$(display DP-2 1 on)"
  run nova-hyprland-monitor-internal off
  [ "$status" -eq 0 ]
  [ "$(cat "$toggles/internal-monitor-disable.lua")" = "$panel_rule" ]
  grep -qx "hyprctl reload" "$CALLS"
  run nova-hyprland-monitor-internal on
  [ ! -e "$toggles/internal-monitor-disable.lua" ]
  grep -qxF 'hyprctl dispatch hl.dsp.dpms({ action = "enable" })' "$CALLS"
}

@test "internal toggle: off when on, on when off; off while mirrored is left as it is" {
  displays "$(display eDP-1 2 on)" "$(display DP-2 1 on)"
  run nova-hyprland-monitor-internal toggle
  [ "$status" -eq 0 ]
  [ "$(cat "$toggles/internal-monitor-disable.lua")" = "$panel_rule" ]
  run nova-hyprland-monitor-internal toggle
  [ ! -e "$toggles/internal-monitor-disable.lua" ]
  grep -qF "Laptop display enabled" "$CALLS"
  write_file "$toggles/internal-monitor-mirror.lua" $'x\n'
  : >"$CALLS"
  run nova-hyprland-monitor-internal off
  [ "$status" -eq 0 ]
  [ ! -e "$toggles/internal-monitor-disable.lua" ]
  fails grep -q 'reload\|notification' "$CALLS"
}

@test "internal off: no panel, or one whose name cannot go into Lua, is said and refused" {
  displays "$(display DP-2 1 on)" "$(display HDMI-A-1 1 on)"
  run nova-hyprland-monitor-internal off
  [ "$status" -eq 1 ]
  grep -qF "nova-notification-send -g 󰍹 No laptop display found" "$CALLS"
  displays "$(display 'eDP-1"x' 2 on)" "$(display DP-2 1 on)"
  run nova-hyprland-monitor-internal off
  [ "$status" -eq 1 ]
  grep -qF "nova-notification-send -g 󰍹 Refusing unsafe monitor name" "$CALLS"
  [ ! -e "$toggles/internal-monitor-disable.lua" ]
}

@test "internal recover: the panel back only when it was off by hand and nothing else is on" {
  write_file "$toggles/internal-monitor-disable.lua" "$panel_rule"$'\n'
  displays "$(display eDP-1 2 off)" "$(display DP-2 1 on)"
  run nova-hyprland-monitor-internal recover
  [ "$status" -eq 0 ]
  [ -e "$toggles/internal-monitor-disable.lua" ]
  fails grep -q 'dispatch\|reload\|notification' "$CALLS"
  displays "$(display eDP-1 2 off)"
  run nova-hyprland-monitor-internal recover
  [ "$status" -eq 0 ]
  [ ! -e "$toggles/internal-monitor-disable.lua" ]
  [ "$(grep -v '^hyprctl monitors' "$CALLS")" = 'hyprctl reload
hyprctl dispatch hl.dsp.dpms({ action = "enable" })' ]
  # Nothing off by hand: nothing done, and no wake.
  : >"$CALLS"
  run nova-hyprland-monitor-internal recover
  fails grep -q 'dispatch\|reload' "$CALLS"
}

@test "mirror: the first external display shows the panel, and off takes it back" {
  displays "$(display eDP-1 2 on)" "$(display DP-2 1 on)" "$(display HDMI-A-1 1 on)"
  run nova-hyprland-monitor-internal-mirror on
  [ "$status" -eq 0 ]
  [ "$(cat "$toggles/internal-monitor-mirror.lua")" = 'hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, mirror = "eDP-1" })' ]
  # One reload takes the rule up: the panel was on, so there was none to drop.
  [ "$(grep -c '^hyprctl reload' "$CALLS")" -eq 1 ]
  grep -qF "Mirroring enabled (DP-2)" "$CALLS"
  run nova-hyprland-monitor-internal-mirror toggle
  [ ! -e "$toggles/internal-monitor-mirror.lua" ]
  grep -qF "Extended mode restored" "$CALLS"
}

@test "internal and mirror: a wrong action is the usage, before Hyprland is asked" {
  for script in nova-hyprland-monitor-internal nova-hyprland-monitor-internal-mirror; do
    run "$script" sideways
    [ "$status" -eq 1 ]
    [ "$output" = "Usage: $script {on|off|toggle|recover}" ]
  done
  [ ! -s "$CALLS" ]
}
