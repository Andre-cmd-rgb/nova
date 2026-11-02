#!/usr/bin/env bats

# The laptop's panel beside other displays: nova-hyprland-monitor-clamshell
# turns it off with the lid shut on a dock and brings it back at its scale,
# nova-hyprland-monitor-internal and -mirror turn it off or mirror it by hand,
# and nova-hyprland-monitor-watch runs a clamshell pass when displays come and
# go. Hyprland is a stub that answers `monitors` from $LIVE and logs every
# call; the lid and the DRM connectors are directories.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_RUNTIME_DIR="$SCRATCH/run" CALLS="$SCRATCH/calls" LIVE="$SCRATCH/live.json"
  export NOVA_LID_PATH="$SCRATCH/lid" NOVA_DRM_PATH="$SCRATCH/drm" NOVA_DMI_PATH="$SCRATCH/dmi"
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

@test "mirror: the first external display shows the panel, and off takes it back" {
  displays "$(display eDP-1 2 on)" "$(display DP-2 1 on)" "$(display HDMI-A-1 1 on)"
  run nova-hyprland-monitor-internal-mirror on
  [ "$status" -eq 0 ]
  [ "$(cat "$toggles/internal-monitor-mirror.lua")" = 'hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, mirror = "eDP-1" })' ]
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

@test "watch: a display event runs a clamshell pass at once, whatever the locale's decimal separator" {
  # German writes 1,5: built here when the system has no such locale.
  if ! locale -a 2>/dev/null | grep -qix 'de_DE.utf-\?8'; then
    mkdir -p "$SCRATCH/locale"
    localedef -i de_DE -f UTF-8 "$SCRATCH/locale/de_DE.UTF-8" 2>/dev/null || skip "no German locale to try"
    export LOCPATH="$SCRATCH/locale"
  fi
  [[ $(LC_ALL=de_DE.UTF-8 bash -c 'echo "$EPOCHREALTIME"') == *,* ]] || skip "no comma in this bash's EPOCHREALTIME"
  export HYPRLAND_INSTANCE_SIGNATURE=test
  stub socat
  stub nova-hyprland-monitor-clamshell
  stub nova-hyprland-monitor-modeless 'exit 1'
  # The passes after a pause never come: the pause fails.
  stub sleep 'exit 1'
  LC_ALL=de_DE.UTF-8 run nova-hyprland-monitor-watch
  [ "$status" -eq 0 ]
  [ "$(grep -c '^nova-hyprland-monitor-clamshell' "$CALLS")" -eq 1 ]
}

@test "watch: outside a Hyprland session it says so" {
  run nova-hyprland-monitor-watch
  [ "$status" -eq 1 ]
  [ "$output" = "nova-hyprland-monitor-watch: not running inside a Hyprland session" ]
}
