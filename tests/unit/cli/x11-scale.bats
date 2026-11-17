#!/usr/bin/env bats

# nova-hyprland-x11-scale: the scale X11 apps draw at, told to XWayland as
# XSETTINGS (nova-xsettings.service, xsettingsd) and as Xft.dpi in the X
# resources. Hyprland answers `monitors -j` from $LIVE; systemctl, xrdb and
# the service are stubs that log each call, xrdb with what it was given.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" LIVE="$SCRATCH/live.json" DISPLAY=:7
  unset GDK_SCALE NOVA_X11_SCALE
  mkdir -p "$SCRATCH/bin"
  stub hyprctl '[[ $1 != monitors ]] || cat "$LIVE"'
  # The service is active once it was started.
  stub systemctl '
case $* in
  *is-active*) [[ -e $SCRATCH/active ]] ;;
  *reload-or-restart*) touch "$SCRATCH/active" ;;
esac'
  stub xrdb 'cat >>"$CALLS"'
  : >"$CALLS"
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:/usr/bin"
  config=$XDG_RUNTIME_DIR/nova/xsettingsd.conf
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# The displays: name:scale or name:scale:off, as `monitors -j` lists them.
displays() {
  local word name scale off list=()
  for word in "$@"; do
    IFS=: read -r name scale off <<<"$word"
    list+=("$(jq -cn --arg name "$name" --argjson scale "$scale" --argjson off "$([[ $off == off ]] && echo true || echo false)" \
      '{name: $name, scale: $scale, disabled: $off}')")
  done
  local IFS=,
  echo "[${list[*]}]" >"$LIVE"
}

# The scale told, as the settings xsettingsd was given and the resources.
told() { # scale
  [ "$(cat "$config")" = "$(printf 'Gdk/WindowScalingFactor %d\nGdk/UnscaledDPI 98304' "$1")" ]
  [ "$(tail -n 1 "$CALLS")" = "$(printf 'Xft.dpi:\t%d' $(($1 * 96)))" ]
}

# No Xft/DPI in the XSETTINGS: Qt would follow it, and draw a window open
# through the change wrong.
@test "the built-in panel's scale: GTK's scale and unscaled text as XSETTINGS, and Xft.dpi merged into the resources" {
  displays eDP-1:2 DP-1:1
  run nova-hyprland-x11-scale
  [ "$status" -eq 0 ]
  told 2
  grep -qx 'systemctl --user --no-block reload-or-restart nova-xsettings.service' "$CALLS"
  grep -qx 'xrdb -nocpp -merge' "$CALLS"
}

@test "rounded to a whole scale, never under 1, and the largest display's without a panel on" {
  displays eDP-1:1.6
  nova-hyprland-x11-scale
  told 2
  displays eDP-1:1.25 DP-1:2
  nova-hyprland-x11-scale
  told 1
  displays eDP-1:2:off DP-1:1 HDMI-A-1:1.5
  nova-hyprland-x11-scale
  told 2
  displays DP-1:3
  nova-hyprland-x11-scale
  told 3
  displays DP-1:0.5
  nova-hyprland-x11-scale
  told 1
}

@test "xsettingsd is told only a new scale; the resources are set every time" {
  displays eDP-1:2
  nova-hyprland-x11-scale
  : >"$CALLS"
  nova-hyprland-x11-scale
  fails grep -q reload-or-restart "$CALLS"
  told 2
  # A service that stopped is started again, with the same scale.
  rm "$SCRATCH/active"
  nova-hyprland-x11-scale
  grep -q reload-or-restart "$CALLS"
  : >"$CALLS"
  displays eDP-1:1
  nova-hyprland-x11-scale
  grep -q reload-or-restart "$CALLS"
  told 1
}

@test "NOVA_X11_SCALE is the scale, whatever the displays" {
  displays eDP-1:2
  NOVA_X11_SCALE=1 nova-hyprland-x11-scale
  told 1
  fails grep -q '^hyprctl' "$CALLS"
}

@test "a GDK_SCALE of yours, or no XWayland, leaves X11 apps as they are" {
  displays eDP-1:2
  GDK_SCALE=2 run nova-hyprland-x11-scale
  [ "$status" -eq 0 ]
  unset DISPLAY
  run nova-hyprland-x11-scale
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [ ! -e "$config" ]
}

@test "Hyprland not answering changes nothing" {
  stub hyprctl 'exit 1'
  run nova-hyprland-x11-scale
  [ "$status" -ne 0 ]
  [ ! -e "$config" ]
  fails grep -q -e '^systemctl' -e '^xrdb' "$CALLS"
}

@test "the service runs xsettingsd on the settings written, ends with the session, and comes back after XWayland" {
  unit=$REPO_ROOT/data/systemd/user/nova-xsettings.service
  grep -qx 'ExecStart=/usr/bin/xsettingsd -c %t/nova/xsettingsd.conf' "$unit"
  grep -qx 'ExecReload=/usr/bin/kill -HUP $MAINPID' "$unit"
  grep -qx 'PartOf=graphical-session.target' "$unit"
  grep -qx 'Restart=on-failure' "$unit"
}
