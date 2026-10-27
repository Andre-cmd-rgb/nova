#!/usr/bin/env bats

# nova monitor, behind Settings → Displays: what it lists, a change applied
# live and kept or taken back, the arrangement, and the Lua it writes, whose
# strings come from the displays themselves. Hyprland is a stub that answers
# `monitors all -j` from $LIVE and logs every call.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_STATE_HOME="$SCRATCH/state" XDG_RUNTIME_DIR="$SCRATCH/run"
  export CALLS="$SCRATCH/calls" LIVE="$SCRATCH/live.json"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$SCRATCH/bin"
  live_two
  stub hyprctl '[[ $1 == monitors ]] && cat "$LIVE"; true'
  stub setsid
  stub nova-hyprland-monitor-internal
  export PATH="$SCRATCH/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/cli/bin/nova-monitor"
  rules=$XDG_STATE_HOME/nova/toggles/hypr/display-settings.lua
  saved=$XDG_STATE_HOME/nova/monitors.json
  pending=$XDG_RUNTIME_DIR/nova/monitors-pending.json
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# A P1's panel at scale 2, and a 1440p display to its right; [description].
live_two() {
  jq -n --arg desc "${1:-Dell Inc. DELL U2724D 7XQ1234}" '[
    {name: "eDP-1", description: "LG Display 0x06AA", make: "LG Display", model: "0x06AA",
     width: 3840, height: 2400, refreshRate: 60.0, x: 0, y: 0, scale: 2, transform: 0,
     disabled: false, focused: true, mirrorOf: "none", availableModes: ["3840x2400@60.00Hz"]},
    {name: "DP-2", description: $desc, make: "Dell Inc.", model: "DELL U2724D",
     width: 2560, height: 1440, refreshRate: 59.951, x: 1920, y: 0, scale: 1, transform: 0,
     disabled: false, focused: false, mirrorOf: "none",
     availableModes: ["2560x1440@59.95Hz", "2560x1440@120.00Hz", "1920x1080@60.00Hz"]}
  ]' >"$LIVE"
}

@test "list: each display with its label, its match, the resolutions and rates it has, and the scales it takes" {
  run cmd_list --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.displays[] | [.name, .label, .key, .internal]]' <<<"$output")" = \
    '[["eDP-1","Built-in Display","eDP-1",true],["DP-2","Dell Inc. DELL U2724D","desc:Dell Inc. DELL U2724D 7XQ1234",false]]' ]
  [ "$(jq -c '.displays[1].modes | map(.mode)' <<<"$output")" = '["2560x1440@120.00","2560x1440@59.95","1920x1080@60.00"]' ]
  [ "$(jq -c '.displays[0] | [.logicalWidth, .logicalHeight, .mode]' <<<"$output")" = '[1920,1200,"3840x2400@60"]' ]
  # 2560 / 1.5 is no whole number of pixels, so 1.5 is 1.6 here; 2 leaves
  # 720 lines, 2.5 too few.
  [ "$(jq -c '.displays[1].scales' <<<"$output")" = '[1,1.25,1.6,2]' ]
  [ "$(jq -c .pending <<<"$output")" = null ]
}

@test "list: two displays with one description are matched by their connectors" {
  jq '.[0].description = .[1].description | .[0].name = "DP-1"' "$LIVE" >"$LIVE.new" && mv "$LIVE.new" "$LIVE"
  run cmd_list --json
  [ "$(jq -c '[.displays[].key]' <<<"$output")" = '["DP-1","DP-2"]' ]
}

@test "set: applies a mode live, keeps nothing yet, and starts the clock back" {
  run cmd_set DP-2 mode 2560x1440@120.00
  [ "$status" -eq 0 ]
  grep -qF 'hyprctl eval hl.monitor({ output = "desc:Dell Inc. DELL U2724D 7XQ1234", mode = "2560x1440@120.00", position = "1920x0", scale = 1, transform = 0 })' "$CALLS"
  grep -q "^setsid -f .*nova-monitor revert --stamp $(jq -r .stamp "$pending") --after 15$" "$CALLS"
  [ "$(jq -r '.until - now | . > 0 and . <= 15' "$pending")" = true ]
  [ ! -e "$saved" ]
  [ ! -e "$rules" ]
}

@test "set: a mode the display does not have is refused, and nothing changes" {
  run cmd_set DP-2 mode 3840x2160@60.00
  [ "$status" -ne 0 ]
  [[ $output == *"DP-2 has no mode 3840x2160@60.00"* ]]
  fails grep -q "eval" "$CALLS"
  [ ! -e "$pending" ]
}

@test "set: a change Hyprland refuses goes back at once, and nothing waits to be kept" {
  stub hyprctl '[[ $1 == monitors ]] && cat "$LIVE"; [[ $1 != eval ]]'
  run cmd_set DP-2 mode 2560x1440@120.00
  [ "$status" -eq 1 ]
  [[ $output == *"did not take the change"* ]]
  grep -qx 'hyprctl reload' "$CALLS"
  ! grep -q '^setsid' "$CALLS"
  [ ! -e "$pending" ]
}

@test "keep: writes the change down, as a rule after monitors.lua's, without a reload" {
  cmd_set DP-2 mode 2560x1440@120.00
  run cmd_keep
  [ "$status" -eq 0 ]
  [ ! -e "$pending" ]
  [ "$(jq -r '."desc:Dell Inc. DELL U2724D 7XQ1234".mode' "$saved")" = 2560x1440@120.00 ]
  grep -qxF 'hl.monitor({ output = "desc:Dell Inc. DELL U2724D 7XQ1234", mode = "2560x1440@120.00", position = "1920x0", scale = 1, transform = 0 })' "$rules"
  fails grep -q "reload" "$CALLS"
}

@test "revert: the clock's own change goes back with a reload, and a later one's clock does not touch it" {
  cmd_set DP-2 rotate 90
  stamp=$(jq -r .stamp "$pending")
  run cmd_revert --stamp 123
  [ -e "$pending" ]
  fails grep -q reload "$CALLS"
  run cmd_revert --stamp "$stamp"
  [ ! -e "$pending" ]
  grep -qx "hyprctl reload" "$CALLS"
  [ ! -e "$saved" ]
}

@test "set: changes made before keeping add up" {
  cmd_set DP-2 scale 1.25
  cmd_set DP-2 rotate 270
  cmd_keep
  [ "$(jq -c '."desc:Dell Inc. DELL U2724D 7XQ1234" | [.scale, .transform]' "$saved")" = '[1.25,3]' ]
}

@test "set: a scale becomes one Hyprland takes for the mode" {
  cmd_set eDP-1 scale 1.3
  cmd_keep
  [ "$(jq -c '."eDP-1".scale' "$saved")" = 1.3333333333333333 ]
}

@test "position: edge to edge, and the arrangement moved to start at 0,0" {
  run cmd_set DP-2 position left-of eDP-1
  [ "$status" -eq 0 ]
  cmd_keep
  [ "$(jq -c '[."eDP-1".position, ."desc:Dell Inc. DELL U2724D 7XQ1234".position]' "$saved")" = '["2560x0","0x0"]' ]
  cmd_set DP-2 position below eDP-1
  cmd_keep
  [ "$(jq -c '[."eDP-1".position, ."desc:Dell Inc. DELL U2724D 7XQ1234".position]' "$saved")" = '["0x0","0x1200"]' ]
}

@test "position: needs another display that is on" {
  run cmd_set DP-2 position right-of DP-2
  [ "$status" -ne 0 ]
  run cmd_set DP-2 position beside eDP-1
  [ "$status" -ne 0 ]
}

@test "off: never the only display on, and the laptop's panel through its own switch" {
  run cmd_set DP-2 off
  [ "$status" -eq 0 ]
  grep -qF 'hyprctl eval hl.monitor({ output = "desc:Dell Inc. DELL U2724D 7XQ1234", disabled = true })' "$CALLS"
  jq '.[0].disabled = true' "$LIVE" >"$LIVE.new" && mv "$LIVE.new" "$LIVE"
  run cmd_set DP-2 off
  [ "$status" -ne 0 ]
  [[ $output == *"the only display on"* ]]
  run main set eDP-1 on
  grep -qx "nova-hyprland-monitor-internal on" "$CALLS"
}

@test "on: a display off since it was plugged in comes back at its preferred mode" {
  jq '.[1].disabled = true' "$LIVE" >"$LIVE.new" && mv "$LIVE.new" "$LIVE"
  run cmd_set DP-2 on
  [ "$status" -eq 0 ]
  grep -qF 'mode = "preferred", position = "auto", scale = "auto", transform = 0 })' "$CALLS"
}

@test "rules: a description is written as escapes, never as code" {
  local hostile='Evil "]] }) os.execute("touch pwned") --'$'\n''é'
  live_two "$hostile"
  cmd_set DP-2 rotate 180
  cmd_keep
  luac -p "$rules"
  if command -v lua >/dev/null; then
    out=$(cd "$SCRATCH" && lua -e 'hl = { monitor = function(t) io.write(t.output, "\0") end }' "$rules")
    [ "$out" = "desc:$hostile"$'\0'"" ] || [ "$(printf '%s' "$out" | tr -d '\0')" = "desc:$hostile" ]
    [ ! -e "$SCRATCH/pwned" ]
  fi
}

@test "rules: a hand-edited entry that is not what Nova writes is left out" {
  mkdir -p "$(dirname "$saved")"
  echo '{"DP-2": {"mode": "1x1@1\"); os.exit(1) --", "position": "0x0", "scale": 1, "transform": 0},
         "eDP-1": {"mode": "3840x2400@60", "position": "0x0", "scale": 2, "transform": 0}}' >"$saved"
  write_rules
  [ "$(grep -c '^hl.monitor' "$rules")" = 1 ]
  grep -q '"eDP-1"' "$rules"
}

@test "reset: a display back to monitors.lua, at once" {
  cmd_set DP-2 scale 1.25
  cmd_keep
  cmd_set eDP-1 scale 1.6
  cmd_keep
  run cmd_reset DP-2
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys' "$saved")" = '["eDP-1"]' ]
  fails grep -q DELL "$rules"
  grep -qx "hyprctl reload" "$CALLS"
}

@test "the lid watcher brings the panel back as Settings keeps it, over monitors.lua" {
  mkdir -p "$HOME/.config/hypr" "$(dirname "$saved")"
  echo 'hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 2 })' >"$HOME/.config/hypr/monitors.lua"
  echo '{"eDP-1": {"mode": "3840x2400@60", "position": "2560x0", "scale": 1.6, "transform": 0}}' >"$saved"
  stub nova-hyprland-monitor-laptop 'echo eDP-1'
  stub nova-hyprland-monitor-internal-mirror
  stub nova-hw-clamshell 'exit 1'
  run "$REPO_ROOT/src/cli/bin/nova-hyprland-monitor-clamshell"
  [ "$status" -eq 0 ]
  grep -qxF 'hyprctl eval hl.monitor({ output = "eDP-1", mode = "preferred", position = "2560x0", scale = 1.6 })' "$CALLS"
}

@test "remember: the bar's scale is kept for a display Settings has settings for, and only then" {
  run cmd_remember eDP-1 scale 1.6
  [ ! -e "$saved" ]
  cmd_set eDP-1 scale 2
  cmd_keep
  cmd_remember eDP-1 scale 1.6
  [ "$(jq '."eDP-1".scale' "$saved")" = 1.6 ]
  grep -qF 'scale = 1.6,' "$rules"
}
