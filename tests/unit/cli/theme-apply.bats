#!/usr/bin/env bats

# nova-theme-apply with gsettings stubbed: which icon set and GTK theme a
# theme gets, the palette's files for GTK, that no window has title-bar
# buttons, and Flatpak apps shown GTK's folders.

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

@test "Adwaita's folders are made in the theme's accent, as the icon theme Nova" {
  write_file "$XDG_DATA_DIRS/icons/Adwaita/scalable/places/folder.svg" '<path fill="#62A0EA"/><path fill="#438de6"/><path fill="#9a9996"/>'
  write_file "$XDG_DATA_DIRS/icons/Adwaita/scalable/places/user-home.svg" '<path fill="#62a0ea"/>'
  write_file "$XDG_DATA_DIRS/icons/Adwaita/scalable/devices/computer.svg" '<path fill="#62a0ea"/>'
  write_file "$XDG_STATE_HOME/nova/current/theme/adwaita-folders.sed" 's/#62a0ea/#ff0000/gI
s/#438de6/#00ff00/gI'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ "$(icon_theme)" = Nova ]
  [ "$(cat "$XDG_DATA_HOME/icons/Nova/scalable/places/folder.svg")" = '<path fill="#ff0000"/><path fill="#00ff00"/><path fill="#9a9996"/>' ]
  [ "$(cat "$XDG_DATA_HOME/icons/Nova/scalable/places/user-home.svg")" = '<path fill="#ff0000"/>' ]
  [ ! -e "$XDG_DATA_HOME/icons/Nova/scalable/devices" ]
  grep -qx 'Inherits=Adwaita' "$XDG_DATA_HOME/icons/Nova/index.theme"
  # Again, on the next theme change.
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_DATA_HOME/icons/.Nova.tmp" ]
}

@test "the icon theme Nova has Nova's cursors, found there before the Adwaita it inherits" {
  write_file "$XDG_DATA_DIRS/icons/Adwaita/scalable/places/folder.svg" '<path fill="#62a0ea"/>'
  write_file "$XDG_DATA_DIRS/icons/Nova/cursors/default" 'cursor'
  write_file "$XDG_STATE_HOME/nova/current/theme/adwaita-folders.sed" 's/#62a0ea/#ff0000/gI'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ "$(readlink "$XDG_DATA_HOME/icons/Nova/cursors")" = "$XDG_DATA_DIRS/icons/Nova/cursors" ]
  [ "$(cat "$XDG_DATA_HOME/icons/Nova/cursors/default")" = cursor ]
  # Made again, without a link inside the link.
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_DATA_DIRS/icons/Nova/cursors/cursors" ]
}

@test "without Nova's cursors installed, the icon theme Nova links none" {
  write_file "$XDG_DATA_DIRS/icons/Adwaita/scalable/places/folder.svg" '<path fill="#62a0ea"/>'
  write_file "$XDG_STATE_HOME/nova/current/theme/adwaita-folders.sed" 's/#62a0ea/#ff0000/gI'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ -f "$XDG_DATA_HOME/icons/Nova/index.theme" ]
  [ ! -e "$XDG_DATA_HOME/icons/Nova/cursors" ] && [ ! -L "$XDG_DATA_HOME/icons/Nova/cursors" ]
}

@test "a theme's own icon set is not replaced by Nova" {
  echo Yaru-sage >"$XDG_STATE_HOME/nova/current/theme/icons.theme"
  write_file "$XDG_DATA_DIRS/icons/Yaru-sage/index.theme" '[Icon Theme]'
  write_file "$XDG_DATA_DIRS/icons/Adwaita/scalable/places/folder.svg" '<path fill="#62a0ea"/>'
  write_file "$XDG_STATE_HOME/nova/current/theme/adwaita-folders.sed" 's/#62a0ea/#ff0000/gI'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$(icon_theme)" = Yaru-sage ]
  [ ! -e "$XDG_DATA_HOME/icons/Nova" ]
}

# A GTK portal that runs, started at <date>; its restart takes a fifth of a
# second, logged as it begins and as it ends.
portal_started() { # date
  stub systemctl "case \$* in
  *' show '*) printf 'ActiveState=active\nExecMainStartTimestamp=%s\n' '$1' ;;
  *try-restart*) sleep 0.2; echo 'restarted' >>\"\$CALLS\" ;;
esac"
}

# GTK 3's palette, last changed at <date>.
gtk3_css_at() { # date
  write_file "$XDG_CONFIG_HOME/gtk-3.0/nova.css" 'three'
  ln -sfn nova.css "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
  touch -d "$1" "$XDG_CONFIG_HOME/gtk-3.0/nova.css"
}

restarts() { grep -c '^systemctl --user try-restart xdg-desktop-portal-gtk.service$' "$CALLS" || true; }

@test "the GTK portal, which keeps the gtk.css it started with, is started again when it changed since" {
  gtk3_css_at '2026-11-02 10:00'
  portal_started 'Sun 2026-11-01 10:00:00.000000 UTC'
  stub hyprctl "echo '[{\"class\": \"foot\"}]'"
  HYPRLAND_INSTANCE_SIGNATURE=test run "$REPO_ROOT/src/cli/bin/nova-theme-apply" portal
  [ "$status" -eq 0 ]
  [ "$(restarts)" -eq 1 ]
  grep -qx restarted "$CALLS"
}

@test "the GTK portal is left running when nothing it read as it started has changed" {
  # A theme change that leaves GTK 3's palette as it was (an adaptive theme's
  # new photo of the same colours) writes no new nova.css.
  write_file "$XDG_STATE_HOME/nova/current/theme/gtk3.css" 'three'
  gtk3_css_at '2026-11-01 10:00'
  portal_started 'Mon 2026-11-02 10:00:00.000000 UTC'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk portal
  [ "$status" -eq 0 ]
  [ "$(restarts)" -eq 0 ]
  [ "$(stat -c %Y "$XDG_CONFIG_HOME/gtk-3.0/nova.css")" = "$(date -d '2026-11-01 10:00' +%s)" ]
  grep -q 'color-scheme prefer-light' "$CALLS"
  # A new palette is written, and the portal, which has the old one, starts again.
  write_file "$XDG_STATE_HOME/nova/current/theme/gtk3.css" 'new three'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk portal
  [ "$(restarts)" -eq 1 ]
  [ "$(cat "$XDG_CONFIG_HOME/gtk-3.0/gtk.css")" = 'new three' ]
}

@test "the GTK portal is left running while an app keeps the screen on through it" {
  # The portal holds a Flatpak or GTK 4 player's request on nova-sessiond,
  # which lets go of it as the portal leaves the bus.
  gtk3_css_at '2026-11-02 10:00'
  portal_started 'Sun 2026-11-01 10:00:00.000000 UTC'
  write_file "$XDG_RUNTIME_DIR/nova/idle-inhibitors" $'org.example.Player\tPlaying video\n'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk portal
  [ "$status" -eq 0 ]
  [ "$(restarts)" -eq 0 ]
  grep -q 'color-scheme prefer-light' "$CALLS"
  # Let go: the next change starts it again.
  rm "$XDG_RUNTIME_DIR/nova/idle-inhibitors"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk portal
  [ "$(restarts)" -eq 1 ]
}

@test "a GTK portal that does not run is not started" {
  gtk3_css_at '2026-11-02 10:00'
  stub systemctl "case \$* in *' show '*) printf 'ActiveState=inactive\nExecMainStartTimestamp=\n' ;; esac"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" portal
  [ "$status" -eq 0 ]
  [ "$(restarts)" -eq 0 ]
}

@test "the GTK portal has started again before GTK's new light or dark, which it then hands on" {
  # The portal hands color-scheme on to apps (Chrome, T3 Code, libadwaita);
  # a change made while it restarts reaches none of them.
  write_file "$XDG_STATE_HOME/nova/current/theme/gtk3.css" 'three'
  portal_started 'Sun 2026-11-01 10:00:00.000000 UTC'
  stub hyprctl "echo '[]'"
  HYPRLAND_INSTANCE_SIGNATURE=test run "$REPO_ROOT/src/cli/bin/nova-theme-apply" portal gtk
  [ "$status" -eq 0 ]
  restarted=$(grep -nx 'restarted' "$CALLS" | cut -d: -f1)
  scheme=$(grep -n 'color-scheme' "$CALLS" | cut -d: -f1)
  [ -n "$restarted" ] && [ -n "$scheme" ]
  (( restarted < scheme ))
}

@test "two theme changes at once: neither's settings fall inside the other's portal restart" {
  write_file "$XDG_STATE_HOME/nova/current/theme/gtk3.css" 'three'
  portal_started 'Sun 2026-11-01 10:00:00.000000 UTC'
  "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk portal & first=$!
  "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk portal & second=$!
  wait "$first"
  wait "$second"
  [ "$(restarts)" -eq 2 ]
  # Between a restart's start and its end, no setting changes.
  awk '/try-restart/ { inside = 1; next } /^restarted$/ { inside = 0; next }
    inside && /^gsettings/ { bad = 1 } END { exit bad }' "$CALLS"
}

@test "the GTK portal is left running while one of its windows is open" {
  gtk3_css_at '2026-11-02 10:00'
  portal_started 'Sun 2026-11-01 10:00:00.000000 UTC'
  stub hyprctl "echo '[{\"class\": \"xdg-desktop-portal-gtk\"}]'"
  HYPRLAND_INSTANCE_SIGNATURE=test run "$REPO_ROOT/src/cli/bin/nova-theme-apply" portal
  [ "$status" -eq 0 ]
  grep -q '^hyprctl -j clients' "$CALLS"
  [ "$(restarts)" -eq 0 ]
}

@test "no window gets title-bar buttons" {
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  grep -qx "gsettings set org.gnome.desktop.wm.preferences button-layout :" "$CALLS"
}

gtk_theme() { grep -oP '^gsettings set org.gnome.desktop.interface gtk-theme \K.*' "$CALLS"; }

@test "GTK 3 apps draw with adw-gtk3, light or dark as the theme is, where it is installed" {
  write_file "$XDG_DATA_DIRS/themes/adw-gtk3/gtk-3.0/gtk.css"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ "$(gtk_theme)" = adw-gtk3 ]
  : >"$CALLS"
  stub nova-theme 'echo dark'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$(gtk_theme)" = adw-gtk3-dark ]
  grep -q 'color-scheme prefer-dark' "$CALLS"
}

@test "without adw-gtk3, GTK's own Adwaita" {
  stub nova-theme 'echo dark'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ "$(gtk_theme)" = Adwaita-dark ]
}

# A Flatpak app is shown ~/.config/gtk-4.0 and nothing in ~/.local/state, so
# the palette is a file in the folder, not a link out of it.
@test "GTK's gtk.css links to nova.css beside it, a copy of the theme's palette" {
  write_file "$XDG_STATE_HOME/nova/current/theme/gtk3.css" 'three'
  write_file "$XDG_STATE_HOME/nova/current/theme/gtk4.css" 'four'
  # A link Nova made before, into the state folder.
  mkdir -p "$XDG_CONFIG_HOME/gtk-4.0"
  ln -s "$XDG_STATE_HOME/nova/current/theme/gtk4.css" "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  for v in 3 4; do
    [ "$(readlink "$XDG_CONFIG_HOME/gtk-$v.0/gtk.css")" = nova.css ]
    [ ! -L "$XDG_CONFIG_HOME/gtk-$v.0/nova.css" ]
  done
  [ "$(cat "$XDG_CONFIG_HOME/gtk-3.0/gtk.css")" = three ]
  [ "$(cat "$XDG_CONFIG_HOME/gtk-4.0/gtk.css")" = four ]
  [ -z "$(find "$XDG_CONFIG_HOME" -name '.nova.css.tmp')" ]
}

@test "a gtk.css of the user's own stays, and nova.css is there for it to import" {
  write_file "$XDG_STATE_HOME/nova/current/theme/gtk4.css" 'four'
  write_file "$XDG_STATE_HOME/nova/current/theme/gtk3.css" 'three'
  write_file "$XDG_CONFIG_HOME/gtk-4.0/gtk.css" '@import url("nova.css"); window { padding: 1px; }'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  [ ! -L "$XDG_CONFIG_HOME/gtk-4.0/gtk.css" ]
  grep -q 'padding' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
  [ "$(cat "$XDG_CONFIG_HOME/gtk-4.0/nova.css")" = four ]
}

@test "X11 apps are told the theme, where there is an X server" {
  stub nova-hyprland-x11-scale
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  fails grep -q '^nova-hyprland-x11-scale' "$CALLS"
  DISPLAY=:9 run "$REPO_ROOT/src/cli/bin/nova-theme-apply" gtk
  [ "$status" -eq 0 ]
  # After GSettings has the theme, which it reads.
  [ "$(tail -n 1 "$CALLS")" = "nova-hyprland-x11-scale " ]
}

@test "Flatpak apps are shown GTK's two folders, read-only, once" {
  export FLATPAK_USER_DIR=$SCRATCH/flatpak
  stub flatpak "mkdir -p \"\$FLATPAK_USER_DIR/overrides\"
printf '[Context]\nfilesystems=xdg-config/gtk-3.0:ro;xdg-config/gtk-4.0:ro;\n' >\"\$FLATPAK_USER_DIR/overrides/global\""
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" flatpak
  [ "$status" -eq 0 ]
  grep -qx 'flatpak override --user --filesystem=xdg-config/gtk-3.0:ro --filesystem=xdg-config/gtk-4.0:ro' "$CALLS"
  : >"$CALLS"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" flatpak
  [ "$status" -eq 0 ]
  fails grep -q '^flatpak' "$CALLS"
}

@test "a folder the user kept from Flatpak apps stays kept" {
  export FLATPAK_USER_DIR=$SCRATCH/flatpak
  write_file "$FLATPAK_USER_DIR/overrides/global" $'[Context]\nfilesystems=!xdg-config/gtk-4.0;\n'
  stub flatpak
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" flatpak
  [ "$status" -eq 0 ]
  grep -qx 'flatpak override --user --filesystem=xdg-config/gtk-3.0:ro' "$CALLS"
}

@test "VS Code keeps the user's settings, with Nova's theme and no title bar of its own" {
  mkdir -p "$HOME/.vscode/extensions"
  write_file "$XDG_STATE_HOME/nova/current/theme/vscode-theme.json" '{}'
  write_file "$XDG_CONFIG_HOME/Code/User/settings.json" '{"editor.fontSize": 15, "window.titleBarStyle": "custom"}'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" vscode
  [ "$status" -eq 0 ]
  run jq -c . "$XDG_CONFIG_HOME/Code/User/settings.json"
  [ "$output" = '{"editor.fontSize":15,"window.titleBarStyle":"native","workbench.colorTheme":"Nova","window.customTitleBarVisibility":"never"}' ]
}

@test "VS Code settings kept in a dotfiles repository stay a symlink, with their mode" {
  mkdir -p "$HOME/.vscode/extensions" "$XDG_CONFIG_HOME/Code/User"
  write_file "$XDG_STATE_HOME/nova/current/theme/vscode-theme.json" '{}'
  write_file "$HOME/dotfiles/settings.json" '{"editor.fontSize": 15}'
  chmod 640 "$HOME/dotfiles/settings.json"
  ln -s "$HOME/dotfiles/settings.json" "$XDG_CONFIG_HOME/Code/User/settings.json"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" vscode
  [ "$status" -eq 0 ]
  [ -L "$XDG_CONFIG_HOME/Code/User/settings.json" ]
  [ "$(jq -r '."workbench.colorTheme"' "$HOME/dotfiles/settings.json")" = Nova ]
  [ "$(stat -c %a "$HOME/dotfiles/settings.json")" = 640 ]
}

@test "a VS Code extensions.json that does not parse is left alone, and the settings still change" {
  mkdir -p "$HOME/.vscode/extensions"
  write_file "$HOME/.vscode/extensions/extensions.json" '[{"broken"'
  write_file "$XDG_STATE_HOME/nova/current/theme/vscode-theme.json" '{}'
  write_file "$XDG_CONFIG_HOME/Code/User/settings.json" '{}'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" vscode
  [ "$status" -eq 0 ]
  [[ $output == *"does not parse"* ]]
  [ "$(cat "$HOME/.vscode/extensions/extensions.json")" = '[{"broken"' ]
  [ -z "$(find "$HOME/.vscode/extensions" -name 'extensions.json.*')" ]
  [ "$(jq -r '."workbench.colorTheme"' "$XDG_CONFIG_HOME/Code/User/settings.json")" = Nova ]
}

t3_theme() { # appearance: the rendered theme, with two of its roles
  write_file "$XDG_STATE_HOME/nova/current/theme/t3code.json" \
    "{\"name\": \"Nova\", \"appearance\": \"$1\", \"canvas\": \"#faf4ed\", \"accent\": \"#d7827e\", \"colors\": {\"canvas\": \"#faf4ed\", \"text\": \"#575279\"}}"
}

@test "T3 Code gets Nova's theme as a file of its own, its colors for light and for dark, named in its settings" {
  mkdir -p "$HOME/.t3/userdata"
  t3_theme light
  write_file "$HOME/.t3/userdata/settings.json" '{"favorites": [], "idleCompaction": "onReturn"}'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  theme=$HOME/.t3/userdata/themes/nova.json
  [ ! -L "$theme" ]
  [ "$(jq -r .canvas "$theme")" = '#faf4ed' ]
  # The other appearance is the same palette, so T3 Code never shows its own.
  [ "$(jq -c '.variants | keys' "$theme")" = '["dark"]' ]
  [ "$(jq -c '.variants.dark == .colors' "$theme")" = true ]
  t3_theme dark
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code
  [ "$(jq -c '[.appearance, (.variants | keys), .variants.light == .colors]' "$theme")" = '["dark",["light"],true]' ]
  [ -z "$(find "$HOME/.t3/userdata" -name '.*.json.*')" ]
  run jq -c 'del(.defaultAppearanceSetAt, .defaultThemeSetAt)' "$HOME/.t3/userdata/settings.json"
  [ "$output" = '{"favorites":[],"idleCompaction":"onReturn","defaultTheme":"nova","defaultAppearance":"system"}' ]
  [[ $(jq -r .defaultAppearanceSetAt "$HOME/.t3/userdata/settings.json") =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\.[0-9]{3}Z$ ]]
  [ "$(jq -r .defaultThemeSetAt "$HOME/.t3/userdata/settings.json")" = "$(jq -r .defaultAppearanceSetAt "$HOME/.t3/userdata/settings.json")" ]
  # Set already, the settings are not written again.
  touch -d '2026-01-01' "$HOME/.t3/userdata/settings.json"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code
  [ "$(stat -c %Y "$HOME/.t3/userdata/settings.json")" = "$(date -d 2026-01-01 +%s)" ]
}

@test "a mode the user picked for T3 Code stays theirs, and its theme is Nova's again" {
  mkdir -p "$HOME/.t3/userdata"
  t3_theme light
  write_file "$HOME/.t3/userdata/settings.json" '{"defaultTheme": "dracula", "defaultThemeSetAt": "2026-11-01T10:00:00.000Z", "defaultAppearance": "dark", "defaultAppearanceSetAt": "2026-11-01T10:00:00.000Z"}'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code
  [ "$status" -eq 0 ]
  run jq -c 'del(.defaultThemeSetAt)' "$HOME/.t3/userdata/settings.json"
  [ "$output" = '{"defaultTheme":"nova","defaultAppearance":"dark","defaultAppearanceSetAt":"2026-11-01T10:00:00.000Z"}' ]
  # The theme's time is the change's, so that each window applies it once, as
  # after `t3 theme set nova`; not the other theme's, left contradicting it.
  [ "$(jq -r .defaultThemeSetAt "$HOME/.t3/userdata/settings.json")" \> 2026-11-02 ]
}

@test "two applies at once leave T3 Code's and Claude Code's themes whole, and no temporary file" {
  mkdir -p "$HOME/.t3/userdata" "$HOME/.claude"
  t3_theme light
  printf '{"name": "nova"}\n' >"$XDG_STATE_HOME/nova/current/theme/claude.json"
  local pids=() i
  for i in 1 2 3 4 5 6; do
    "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code claude & pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i"; done
  jq -e .canvas "$HOME/.t3/userdata/themes/nova.json" >/dev/null
  jq -e .defaultTheme "$HOME/.t3/userdata/settings.json" >/dev/null
  [ "$(jq -r .name "$HOME/.claude/themes/nova.json")" = nova ]
  [ -z "$(find "$HOME/.t3" "$HOME/.claude" -name '.*.json.*' -o -name '*.tmp')" ]
}

@test "T3 Code with no settings yet gets them, and settings that do not parse are left alone" {
  mkdir -p "$HOME/.t3/userdata"
  t3_theme dark
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code
  [ "$(jq -c '[.defaultTheme, .defaultAppearance, .defaultThemeSetAt == .defaultAppearanceSetAt]' "$HOME/.t3/userdata/settings.json")" = '["nova","system",true]' ]
  write_file "$HOME/.t3/userdata/settings.json" '{"broken"'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code
  [ "$status" -eq 0 ]
  [[ $output == *"T3 Code's settings.json does not parse"* ]]
  [ "$(cat "$HOME/.t3/userdata/settings.json")" = '{"broken"' ]
  # The theme file is there all the same.
  [ "$(jq -r .appearance "$HOME/.t3/userdata/themes/nova.json")" = dark ]
}

@test "the theme change does not fail on T3 Code: not installed, or a folder it cannot write" {
  t3_theme light
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$HOME/.t3" ]
  mkdir -p "$HOME/.t3/userdata"
  chmod a-w "$HOME/.t3/userdata"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code
  chmod u+w "$HOME/.t3/userdata"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # A rendered theme that is not JSON leaves the file T3 Code has.
  mkdir -p "$HOME/.t3/userdata/themes"
  write_file "$HOME/.t3/userdata/themes/nova.json" '{"name": "Nova", "appearance": "dark"}'
  write_file "$XDG_STATE_HOME/nova/current/theme/t3code.json" '{"name": '
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" t3code
  [ "$status" -eq 0 ]
  [ "$(jq -r .appearance "$HOME/.t3/userdata/themes/nova.json")" = dark ]
  [ -z "$(find "$HOME/.t3/userdata" -name '.*.json.*')" ]
}

@test "the starting VS Code settings agree with what each theme change enforces" {
  run jq -r '[."workbench.colorTheme", ."window.titleBarStyle", ."window.customTitleBarVisibility"] | join(" ")' \
    "$REPO_ROOT/data/skel/.config/Code/User/settings.json"
  [ "$output" = "Nova native never" ]
}

# argv.json as VS Code reads it: its comments taken out, and the trailing
# commas it allows.
argv() { grep -vE '^[[:space:]]*//' "$1" | sed -E 's/,([[:space:]]*\})/\1/' | jq -r "$2"; }

@test "VS Code is told the login keyring is gnome-keyring's, in the argv.json it wrote" {
  mkdir -p "$HOME/.vscode"
  printf '%s\n' '// This configuration file allows you to pass permanent command line arguments to VS Code.' \
    '{' '	// "disable-hardware-acceleration": true,' '	"enable-crash-reporter": false,' \
    '	"crash-reporter-id": "d9f40467"' '}' >"$HOME/.vscode/argv.json"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" vscode
  [ "$status" -eq 0 ]
  [ "$(argv "$HOME/.vscode/argv.json" '."password-store" + " " + ."crash-reporter-id"')" = "gnome-libsecret d9f40467" ]
  grep -q 'disable-hardware-acceleration' "$HOME/.vscode/argv.json"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" vscode
  [ "$(grep -c '"password-store"' "$HOME/.vscode/argv.json")" -eq 1 ]
}

@test "a keyring the user picked for VS Code is theirs" {
  mkdir -p "$HOME/.vscode"
  printf '{\n\t"password-store": "basic"\n}\n' >"$HOME/.vscode/argv.json"
  cp "$HOME/.vscode/argv.json" "$SCRATCH/before"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" vscode
  [ "$status" -eq 0 ]
  cmp "$SCRATCH/before" "$HOME/.vscode/argv.json"
}

@test "VS Code with no argv.json yet gets one, and VS Code never run gets none" {
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" vscode
  [ ! -e "$HOME/.vscode" ]
  mkdir -p "$HOME/.vscode"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" vscode
  [ "$status" -eq 0 ]
  [ "$(argv "$HOME/.vscode/argv.json" '."password-store"')" = gnome-libsecret ]
}

@test "the starting argv.json uses the login keyring, as each session start enforces" {
  [ "$(argv "$REPO_ROOT/data/skel/.vscode/argv.json" '."password-store"')" = gnome-libsecret ]
}

# A test's session, or any in a home of its own, has a theme that is nobody's
# login screen: the greeter's mirror (and Chrome's colour, made from it)
# belongs to the computer, and only the account's own home writes it.
@test "a session in a home of its own leaves the login screen alone" {
  export NOVA_GREETER_DIR=$SCRATCH/greeter
  mkdir -p "$NOVA_GREETER_DIR"
  echo 'background = "#000000"' >"$NOVA_GREETER_DIR/colors.toml"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" greeter
  [ "$status" -eq 0 ]
  [ "$(cat "$NOVA_GREETER_DIR/colors.toml")" = 'background = "#000000"' ]
  [ "$(ls -A "$NOVA_GREETER_DIR")" = colors.toml ]
}

# The account's own session mirrors the background and the lock's backdrop
# (nova-theme makes it) for the greeter, which draws the backdrop in its first
# frame; a background without one takes the old backdrop away, so that the
# greeter never shows another picture's.
@test "the greeter's mirror has the lock's backdrop, or none" {
  export NOVA_GREETER_DIR=$SCRATCH/greeter
  mkdir -p "$NOVA_GREETER_DIR"
  stub getent "echo \"user:x:$UID:$UID::$HOME:/bin/bash\""
  write_file "$SCRATCH/photo.jpg" 'a photo'
  ln -s "$SCRATCH/photo.jpg" "$XDG_STATE_HOME/nova/current/background"
  write_file "$XDG_STATE_HOME/nova/current/backdrop.ppm" 'P6 the backdrop'
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" greeter
  [ "$status" -eq 0 ]
  [ "$(cat "$NOVA_GREETER_DIR/background")" = 'a photo' ]
  [ "$(cat "$NOVA_GREETER_DIR/backdrop.ppm")" = 'P6 the backdrop' ]

  rm "$XDG_STATE_HOME/nova/current/backdrop.ppm"
  run "$REPO_ROOT/src/cli/bin/nova-theme-apply" greeter
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_GREETER_DIR/backdrop.ppm" ]
  [ "$(ls -A "$NOVA_GREETER_DIR" | sort | tr '\n' ' ')" = 'background colors.toml ' ]
}

# The greeter runs as a user of its own: what is mirrored for it is readable
# by all, whatever the mode of the file it comes from or the umask.
@test "the greeter's mirror is readable by all, from a photo kept private" {
  export NOVA_GREETER_DIR=$SCRATCH/greeter
  mkdir -p "$NOVA_GREETER_DIR"
  stub getent "echo \"user:x:$UID:$UID::$HOME:/bin/bash\""
  write_file "$SCRATCH/photo.jpg" 'a photo'
  chmod 600 "$SCRATCH/photo.jpg"
  ln -s "$SCRATCH/photo.jpg" "$XDG_STATE_HOME/nova/current/background"
  write_file "$XDG_STATE_HOME/nova/current/backdrop.ppm" 'P6 the backdrop'
  chmod 600 "$XDG_STATE_HOME/nova/current/backdrop.ppm" "$XDG_STATE_HOME/nova/current/theme/colors.toml"
  run bash -c 'umask 077; exec "$0" greeter' "$REPO_ROOT/src/cli/bin/nova-theme-apply"
  [ "$status" -eq 0 ]
  for file in background backdrop.ppm colors.toml; do
    [ "$(stat -c %a "$NOVA_GREETER_DIR/$file")" = 644 ]
  done
  [ "$(ls -A "$NOVA_GREETER_DIR" | sort | tr '\n' ' ')" = 'backdrop.ppm background colors.toml ' ]
}
