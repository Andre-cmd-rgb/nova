#!/usr/bin/env bats

# nova-theme-apply's GTK step, with gsettings stubbed: which icon set a theme
# gets.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" HOME="$SCRATCH/home"
  export XDG_STATE_HOME="$SCRATCH/state" XDG_CONFIG_HOME="$SCRATCH/config"
  export XDG_DATA_HOME="$SCRATCH/data" XDG_DATA_DIRS="$SCRATCH/share"
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
  write_file "$XDG_STATE_HOME/nova/current/theme/colors.toml" 'background = "#ffffff"'
  mkdir -p "$SCRATCH/bin" "$HOME"
  stub nova-theme 'echo light'
  stub gsettings
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

icon_theme() { grep -oP '^gsettings set org.gnome.desktop.interface icon-theme \K.*' "$CALLS"; }

@test "a theme without an icons.theme gets Adwaita" {
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ "$(icon_theme)" = Adwaita ]
  grep -q 'color-scheme prefer-light' "$CALLS"
}

@test "a theme's icon set is used where it is installed" {
  echo Yaru-sage >"$XDG_STATE_HOME/nova/current/theme/icons.theme"
  write_file "$XDG_DATA_DIRS/icons/Yaru-sage/index.theme" '[Icon Theme]'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ "$(icon_theme)" = Yaru-sage ]
}

@test "the user's own icon directory counts as installed" {
  echo Mine >"$XDG_STATE_HOME/nova/current/theme/icons.theme"
  write_file "$XDG_DATA_HOME/icons/Mine/index.theme" '[Icon Theme]'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$(icon_theme)" = Mine ]
}

@test "an icon set that is not installed falls back to Adwaita" {
  echo Yaru-sage >"$XDG_STATE_HOME/nova/current/theme/icons.theme"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ "$(icon_theme)" = Adwaita ]
}
