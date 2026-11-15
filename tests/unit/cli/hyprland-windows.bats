#!/usr/bin/env bats

# The Hyprland helpers behind the window and workspace keys: settings turned
# on and off as files the config loads, a window's width kept and put back,
# a workspace's layout switched, an app's window focused, and whether a
# session lock was left with no one to own it. Hyprland is a stub that
# answers its queries from files under $SCRATCH/hypr and logs every call.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" CALLS="$SCRATCH/calls" HYPR="$SCRATCH/hypr" NOVA_PATH="$SCRATCH/nova"
  unset HYPRLAND_INSTANCE_SIGNATURE
  mkdir -p "$HOME" "$SCRATCH/bin" "$HYPR"
  # A query is answered from $HYPR/<query>.json. A relative resize moves the
  # window's width in clients.json by the step times $HYPR/side (1 or -1).
  stub hyprctl '
if [[ $1 == -j ]]; then shift; fi
case $1 in
  clients | activewindow | activeworkspace | monitors) cat "$HYPR/$1.json" ;;
  dispatch)
    if [[ $2 =~ x\ =\ (-?[0-9]+),\ y\ =\ 0,\ relative ]]; then
      step=$((BASH_REMATCH[1] * $(cat "$HYPR/side")))
      jq --argjson step "$step" "map(.size[0] += \$step)" "$HYPR/clients.json" >"$HYPR/new" && mv "$HYPR/new" "$HYPR/clients.json"
    fi ;;
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

@test "toggle: on is a copy of Nova's own file, off is none, and Hyprland reloads each time" {
  write_file "$NOVA_PATH/default/hypr/toggles/window-no-gaps.lua" $'hl.config({ general = { gaps_out = 0 } })\n'
  run nova-hyprland-toggle window-no-gaps
  [ "$output" = on ]
  cmp "$NOVA_PATH/default/hypr/toggles/window-no-gaps.lua" "$toggles/window-no-gaps.lua"
  nova-hyprland-toggle-enabled window-no-gaps
  fails nova-hyprland-toggle-disabled window-no-gaps
  run nova-hyprland-toggle window-no-gaps
  [ "$output" = off ]
  [ ! -e "$toggles/window-no-gaps.lua" ]
  nova-hyprland-toggle window-no-gaps off
  [ "$(grep -c '^hyprctl reload' "$CALLS")" -eq 3 ]
}

@test "toggle: a flag Nova does not ship, or a wrong action, changes nothing" {
  run nova-hyprland-toggle nope on
  [ "$status" -eq 1 ]
  [ "$output" = "Flag not found: nope" ]
  run nova-hyprland-toggle nope sideways
  [ "$status" -eq 1 ]
  [ "$output" = "Usage: nova-hyprland-toggle <flag-name> [on|off|toggle]" ]
  run nova-hyprland-toggle-enabled
  [ "$status" -eq 2 ]
  [ ! -s "$CALLS" ]
}

# The focused window, a kitty on workspace 2, and the side of its shared edge.
window() { # width [side]
  echo "{\"address\": \"0xa\", \"class\": \"kitty\", \"size\": [$1, 900], \"workspace\": {\"id\": 2}}" >"$HYPR/activewindow.json"
  echo "[{\"address\": \"0xa\", \"size\": [$1, 900]}]" >"$HYPR/clients.json"
  echo "${2:-1}" >"$HYPR/side"
}

@test "window width: kept for the app on its workspace, and put back from either side" {
  window 1200
  run nova-hyprland-window-width save
  [ "$status" -eq 0 ]
  [ "$output" = "Saved width for kitty on workspace 2" ]
  [ "$(cat "$HOME/.local/state/nova/windows/workspace-2-kitty.width")" = 1200 ]
  window 900
  nova-hyprland-window-width restore
  [ "$(jq '.[0].size[0]' "$HYPR/clients.json")" -eq 1200 ]
  # A window on the other side shrinks as the shared edge moves right.
  window 1500 -1
  nova-hyprland-window-width restore
  [ "$(jq '.[0].size[0]' "$HYPR/clients.json")" -eq 1200 ]
}

@test "window width: nothing kept for this app here is said, and fails" {
  window 900
  run nova-hyprland-window-width restore
  [ "$status" -eq 1 ]
  grep -qF "No saved width found for kitty on workspace 2" "$CALLS"
  run nova-hyprland-window-width
  [ "$status" -eq 1 ]
  [ "$output" = "Usage: nova-hyprland-window-width save|restore" ]
}

@test "workspace layout: switched, and kept as a rule the config loads again" {
  echo '{"id": 3, "tiledLayout": "dwindle"}' >"$HYPR/activeworkspace.json"
  nova-hyprland-workspace-layout-toggle
  rule='hl.workspace_rule({ workspace = "3", layout = "scrolling" })'
  [ "$(cat "$HOME/.local/state/nova/workspace-layouts/3.lua")" = "$rule" ]
  grep -qxF "hyprctl eval $rule" "$CALLS"
  echo '{"id": 3, "tiledLayout": "scrolling"}' >"$HYPR/activeworkspace.json"
  nova-hyprland-workspace-layout-toggle
  grep -qF 'layout = "dwindle"' "$HOME/.local/state/nova/workspace-layouts/3.lua"
}

@test "focus app: the window of the app used last" {
  echo '[{"address": "0xa", "class": "google-chrome", "focusHistoryID": 3},
         {"address": "0xb", "class": "Google-chrome", "focusHistoryID": 1},
         {"address": "0xc", "class": "kitty", "focusHistoryID": 0}]' >"$HYPR/clients.json"
  nova-hyprland-focus-app chrome
  grep -qxF 'hyprctl dispatch hl.dsp.focus({ window = "address:0xb" })' "$CALLS"
}

@test "session lock: stranded only while no other locker runs" {
  echo '[{"name": "eDP-1", "solitaryBlockedBy": ["LOCK"]}]' >"$HYPR/monitors.json"
  stub pgrep 'echo 100'
  run nova-hyprland-session-lock-stranded 100
  [ "$status" -eq 0 ]
  stub pgrep 'printf "100\n200\n"'
  run nova-hyprland-session-lock-stranded 100
  [ "$status" -eq 2 ]
  echo '[{"name": "eDP-1", "solitaryBlockedBy": ["WINDOWED"]}]' >"$HYPR/monitors.json"
  run nova-hyprland-session-lock-stranded 100
  [ "$status" -eq 1 ]
}
