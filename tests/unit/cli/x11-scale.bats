#!/usr/bin/env bats

# nova-hyprland-x11-scale: the scale X11 apps draw at, told to XWayland as
# XSETTINGS (nova-xsettings.service, xsettingsd) and as Xft.dpi in the X
# resources, and to Nova's Hyprland as xwayland:scale; and the theme, from
# GSettings, as XSETTINGS. Hyprland answers
# `monitors -j` from $LIVE, and `getoption xwayland:scale` as Nova's build
# when $SCRATCH/shrinks exists, else as Arch's; systemctl, xrdb and the
# service are stubs that log each call, xrdb with what it was given.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" LIVE="$SCRATCH/live.json" DISPLAY=:7
  unset GDK_SCALE NOVA_X11_SCALE
  mkdir -p "$SCRATCH/bin"
  stub hyprctl '
case $1 in
  monitors) cat "$LIVE" ;;
  getoption)
    if [[ -e $SCRATCH/shrinks ]]; then
      echo "{\"option\": \"xwayland:scale\", \"float\": 0.000000, \"set\": false }"
    else
      echo "no such option"
    fi
    ;;
esac'
  # The service is active once it was started.
  stub systemctl '
case $* in
  *is-active*) [[ -e $SCRATCH/active ]] ;;
  *reload-or-restart*) touch "$SCRATCH/active" ;;
esac'
  stub xrdb 'cat >>"$CALLS"'
  # GSettings as `list-recursively` prints it, from $SCRATCH/<schema>; none
  # when there is no such file. Not logged.
  printf '#!/bin/bash\n[[ $1 == list-recursively ]] && cat "$SCRATCH/$2" 2>/dev/null\nexit 0\n' >"$SCRATCH/bin/gsettings"
  chmod +x "$SCRATCH/bin/gsettings"
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

# What Nova's Hyprland was told last, and the file a reload reads it back from.
hyprland_told() { # scale
  [ "$(grep '^hyprctl eval' "$CALLS" | tail -n 1)" = "hyprctl eval hl.config({ xwayland = { scale = $1 } })" ]
  [ "$(cat "$XDG_RUNTIME_DIR/nova/x11-scale")" = "$1" ]
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

@test "a Hyprland that cannot shrink X11 windows: rounded to the nearest whole scale, never under 1, and the largest display's without a panel on" {
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
  # Nothing is asked of Hyprland that it does not have.
  fails grep -q '^hyprctl eval' "$CALLS"
  [ ! -e "$XDG_RUNTIME_DIR/nova/x11-scale" ]
}

# Nova's Hyprland shrinks X11 windows on a display of a lower scale, and never
# enlarges them: the largest display's scale, rounded up, panel or not.
@test "Nova's Hyprland: the largest display's scale rounded up, told to Hyprland first" {
  touch "$SCRATCH/shrinks"
  displays eDP-1:2 DP-1:1.5
  nova-hyprland-x11-scale
  told 2
  hyprland_told 2
  # Hyprland is told before the toolkits are.
  [ "$(grep -n -m1 '^hyprctl eval' "$CALLS" | cut -d: -f1)" -lt "$(grep -n -m1 '^systemctl --user --no-block' "$CALLS" | cut -d: -f1)" ]
  displays eDP-1:1.25 DP-1:1
  nova-hyprland-x11-scale
  told 2
  hyprland_told 2
  displays eDP-1:1 DP-1:1.5
  nova-hyprland-x11-scale
  told 2
  displays eDP-1:2:off DP-1:1
  nova-hyprland-x11-scale
  told 1
  hyprland_told 1
  displays DP-1:3 HDMI-A-1:1.6
  nova-hyprland-x11-scale
  told 3
  hyprland_told 3
  # Hyprland's floats: 1.0000001 is 1, not 2.
  displays DP-1:1.0000001 HDMI-A-1:0.5
  nova-hyprland-x11-scale
  told 1
  hyprland_told 1
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

@test "NOVA_X11_SCALE is the scale, whatever the displays, and Nova's Hyprland is told it" {
  displays eDP-1:2
  NOVA_X11_SCALE=1 nova-hyprland-x11-scale
  told 1
  fails grep -q '^hyprctl monitors' "$CALLS"
  touch "$SCRATCH/shrinks"
  NOVA_X11_SCALE=3 nova-hyprland-x11-scale
  told 3
  hyprland_told 3
  fails grep -q '^hyprctl monitors' "$CALLS"
}

@test "a GDK_SCALE of yours, or no XWayland, leaves X11 apps and Hyprland as they are" {
  displays eDP-1:2
  touch "$SCRATCH/shrinks"
  GDK_SCALE=2 run nova-hyprland-x11-scale
  [ "$status" -eq 0 ]
  unset DISPLAY
  run nova-hyprland-x11-scale
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [ ! -e "$config" ]
  [ ! -e "$XDG_RUNTIME_DIR/nova/x11-scale" ]
}

# GSettings as Nova's theme leaves it, a dark one.
theme_settings() {
  cat >"$SCRATCH/org.gnome.desktop.interface" <<'EOF'
org.gnome.desktop.interface color-scheme 'prefer-dark'
org.gnome.desktop.interface cursor-size 24
org.gnome.desktop.interface cursor-theme 'default'
org.gnome.desktop.interface font-antialiasing 'grayscale'
org.gnome.desktop.interface font-hinting 'slight'
org.gnome.desktop.interface font-name 'Adwaita Sans 11'
org.gnome.desktop.interface font-rgba-order 'rgb'
org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark'
org.gnome.desktop.interface icon-theme 'Adwaita'
org.gnome.desktop.interface text-scaling-factor 1.0
EOF
  cat >"$SCRATCH/org.gnome.desktop.wm.preferences" <<'EOF'
org.gnome.desktop.wm.preferences action-double-click-titlebar 'toggle-maximize'
org.gnome.desktop.wm.preferences button-layout ':'
EOF
}

@test "X11 apps are told the theme with the scale: GTK theme, icons, cursor, font and its drawing, and no title-bar buttons" {
  theme_settings
  displays eDP-1:2
  nova-hyprland-x11-scale
  [ "$(cat "$config")" = 'Gdk/WindowScalingFactor 2
Net/ThemeName "adw-gtk3-dark"
Net/IconThemeName "Adwaita"
Gtk/CursorThemeName "default"
Gtk/CursorThemeSize 24
Gtk/FontName "Adwaita Sans 11"
Gtk/DecorationLayout ":"
Xft/Antialias 1
Xft/RGBA "none"
Xft/Hinting 1
Xft/HintStyle "hintslight"
Gdk/UnscaledDPI 98304' ]
}

@test "a new theme alone is told to xsettingsd; the text size reaches GTK as its DPI" {
  theme_settings
  displays eDP-1:2
  nova-hyprland-x11-scale
  : >"$CALLS"
  sed -i "s/'adw-gtk3-dark'/'adw-gtk3'/; s/text-scaling-factor 1.0/text-scaling-factor 1.25/" "$SCRATCH/org.gnome.desktop.interface"
  nova-hyprland-x11-scale
  grep -q reload-or-restart "$CALLS"
  grep -qx 'Net/ThemeName "adw-gtk3"' "$config"
  grep -qx "Gdk/UnscaledDPI $((96 * 1024 * 5 / 4))" "$config"
}

@test "fonts drawn as GSettings says: subpixel in its order, or without antialiasing or hinting" {
  theme_settings
  sed -i "s/'grayscale'/'rgba'/; s/'rgb'/'bgr'/; s/'slight'/'none'/" "$SCRATCH/org.gnome.desktop.interface"
  displays eDP-1:1
  nova-hyprland-x11-scale
  grep -qx 'Xft/Antialias 1' "$config"
  grep -qx 'Xft/RGBA "bgr"' "$config"
  grep -qx 'Xft/Hinting 0' "$config"
  grep -qx 'Xft/HintStyle "hintnone"' "$config"
}

@test "with a GDK_SCALE of yours, X11 apps are told the theme and nothing of the scale" {
  theme_settings
  displays eDP-1:2
  touch "$SCRATCH/shrinks"
  GDK_SCALE=2 run nova-hyprland-x11-scale
  [ "$status" -eq 0 ]
  grep -qx 'Net/ThemeName "adw-gtk3-dark"' "$config"
  fails grep -q '^Gdk/' "$config"
  fails grep -q -e '^hyprctl' -e '^Xft.dpi' "$CALLS"
  [ ! -e "$XDG_RUNTIME_DIR/nova/x11-scale" ]
  grep -qx 'systemctl --user --no-block reload-or-restart nova-xsettings.service' "$CALLS"
}

@test "Hyprland not answering changes nothing" {
  stub hyprctl 'exit 1'
  run nova-hyprland-x11-scale
  [ "$status" -ne 0 ]
  [ ! -e "$config" ]
  [ ! -e "$XDG_RUNTIME_DIR/nova/x11-scale" ]
  fails grep -q -e '^systemctl' -e '^xrdb' -e '^hyprctl eval' "$CALLS"
}

@test "the service runs xsettingsd on the settings written, ends with the session, and comes back after XWayland" {
  unit=$REPO_ROOT/data/systemd/user/nova-xsettings.service
  grep -qx 'ExecStart=/usr/bin/xsettingsd -c %t/nova/xsettingsd.conf' "$unit"
  grep -qx 'ExecReload=/usr/bin/kill -HUP $MAINPID' "$unit"
  grep -qx 'PartOf=graphical-session.target' "$unit"
  grep -qx 'Restart=on-failure' "$unit"
}
