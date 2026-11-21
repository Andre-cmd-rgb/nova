#!/usr/bin/env bats

# nova bar: the bar's see-through look, written to shell.json and read back as the menu reads them, and the widgets placed by asking the
# shell, a stub that writes down each call and answers $ANSWER.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" NOVA_PATH="$SCRATCH/nova" CALLS="$SCRATCH/calls" ANSWER=ok
  mkdir -p "$HOME/.config/nova" "$NOVA_PATH/default" "$SCRATCH/bin"
  cp "$REPO_ROOT/data/defaults/shell.json" "$NOVA_PATH/default/shell.json"
  cat >"$SCRATCH/bin/nova-shell" <<'STUB'
#!/bin/bash
echo "$*" >>"$CALLS"
[[ $1 == -q ]] && exit 0
if [[ $ANSWER == absent ]]; then echo "nova-shell is not running" >&2; exit 1; fi
echo "$ANSWER"
STUB
  printf '#!/bin/bash\n' >"$SCRATCH/bin/sleep"
  chmod +x "$SCRATCH/bin/nova-shell" "$SCRATCH/bin/sleep"
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:$PATH"
}

teardown() { teardown_scratch; }

settings() { jq -cS "$1" "$HOME/.config/nova/shell.json"; }

@test "the bar is always at the top: no verb moves it, and a change drops an edge an older file names" {
  run nova-bar position bottom
  [ "$status" -eq 1 ]
  echo '{"version":1,"bar":{"position":"left","transparent":false}}' >"$HOME/.config/nova/shell.json"
  nova-bar transparent true
  [ "$(settings '.bar | has("position")')" = false ]
  [ "$(settings '[.version, .bar.transparent]')" = '[1,true]' ]
  grep -qx -- '-q shell reloadConfig' "$CALLS"
}

@test "see-through: off by default, toggled, set, and the result said" {
  [ "$(nova-bar transparent)" = off ]
  [ "$(nova-bar transparent toggle)" = 'The bar is see-through.' ]
  [ "$(nova-bar transparent)" = on ]
  [ "$(nova-bar transparent false)" = 'The bar is solid.' ]
  [ "$(nova-bar transparent)" = off ]
  run nova-bar transparent maybe
  [ "$status" -eq 1 ]
}

@test "the menu reads what the shell draws from, though the user's settings are not usable" {
  for broken in '[]' 'not json' '{"bar":{"transparent":true}}' '{"version":1,"bar":7}'; do
    echo "$broken" >"$HOME/.config/nova/shell.json"
    [ "$(nova-bar transparent)" = off ]
  done
  echo '{"version":1,"bar":{"transparent":true}}' >"$HOME/.config/nova/shell.json"
  [ "$(nova-bar transparent)" = on ]
}

@test "settings that cannot be read are never written over, and an empty file is" {
  for broken in 'not json' '{"version":1,"idle":{"lock":600},}' '{"bar":{"transparent":true}}'; do
    echo "$broken" >"$HOME/.config/nova/shell.json"
    run nova-bar transparent true
    [ "$status" -eq 1 ]
    [[ $output == *"is not a config Nova can read"* ]]
    [ "$(<"$HOME/.config/nova/shell.json")" = "$broken" ]
  done
  [ ! -e "$CALLS" ]
  printf '\n' >"$HOME/.config/nova/shell.json"
  nova-bar transparent true
  [ "$(nova-bar transparent)" = on ]
}

@test "with no NOVA_PATH, Nova's settings are read from /usr/share/nova" {
  run env -u NOVA_PATH bash -c 'source "$1"; echo "$DEFAULTS_FILE"' _ "$REPO_ROOT/src/cli/bin/nova-shell-config"
  [ "$status" -eq 0 ]
  [ "$output" = /usr/share/nova/default/shell.json ]
}

@test "settings without a bar have Nova's, and a change keeps its widgets" {
  echo '{"version":1,"idle":{"lock":600}}' >"$HOME/.config/nova/shell.json"
  nova-bar transparent true
  [ "$(settings '[.bar.transparent, .idle.lock]')" = '[true,600]' ]
  [ "$(settings .bar.layout)" = "$(jq -cS .bar.layout "$NOVA_PATH/default/shell.json")" ]
}

@test "defaults puts back the bar Nova ships, and the rest of the settings stay" {
  echo '{"version":1,"idle":{"lock":60},"bar":{"transparent":true}}' >"$HOME/.config/nova/shell.json"
  nova-bar defaults
  [ "$(settings .bar)" = "$(jq -cS .bar "$NOVA_PATH/default/shell.json")" ]
  [ "$(settings .idle.lock)" = 60 ]
}

@test "defaults and edits keep Screen Time recording on an un-migrated shell.json, matching Layout.js" {
  # Before 1.0.0-rc.15 Screen Time was named in bar.layout for both recording
  # and its widget; defaults replaces .bar, so the migration must move it to
  # plugins first.
  cat >"$HOME/.config/nova/shell.json" <<'JSON'
{"version":1,"bar":{"layout":{"left":[],"center":[],"right":[{"id":"nova.tray"},{"id":"nova.screentime","showTotal":false,"indicator":true},{"id":"nova.network"}]}},"plugins":[]}
JSON
  nova-bar transparent true
  [ "$(settings .bar.layout.right)" = '[{"id":"nova.tray"},{"id":"nova.screentime-today","off":true,"showTotal":false},{"id":"nova.network"}]' ]
  [ "$(settings .plugins)" = '[{"id":"nova.screentime"}]' ]

  # Resetting the bar on an un-migrated file still keeps Screen Time recording.
  cat >"$HOME/.config/nova/shell.json" <<'JSON'
{"version":1,"bar":{"layout":{"left":[],"center":[],"right":[{"id":"nova.tray"},{"id":"nova.screentime","indicator":true}]}},"plugins":[]}
JSON
  nova-bar defaults
  [ "$(settings .bar)" = "$(jq -cS .bar "$NOVA_PATH/default/shell.json")" ]
  [ "$(settings .plugins)" = '[{"id":"nova.screentime"}]' ]

  # One switched off stays off.
  echo '{"version":1,"bar":{"layout":{"right":[{"id":"nova.screentime","off":true}]}}}' >"$HOME/.config/nova/shell.json"
  nova-bar defaults
  [ "$(settings .plugins)" = '[]' ]

  # One beside the widget already keeps the widget once and Screen Time once.
  echo '{"version":1,"bar":{"layout":{"right":[{"id":"nova.screentime"},{"id":"nova.screentime-today"}]}},"plugins":[{"id":"nova.screentime"}]}' >"$HOME/.config/nova/shell.json"
  nova-bar transparent true
  [ "$(settings '[.bar.layout.right, .plugins]')" = '[[{"id":"nova.screentime-today"}],[{"id":"nova.screentime"}]]' ]

  # A bare-string entry is on too.
  echo '{"version":1,"bar":{"layout":{"right":["nova.screentime"]}}}' >"$HOME/.config/nova/shell.json"
  nova-bar defaults
  [ "$(settings .plugins)" = '[{"id":"nova.screentime"}]' ]

  # The shell's Layout.js and the CLI's nova-shell-config carry the exact same
  # split-plugin map.
  local js_split cli_split
  js_split=$(sed -n 's/^var SPLIT = //p' "$REPO_ROOT/src/shell/services/Layout.js" | jq -cS .)
  cli_split=$(sed -n "s/^SHELL_CONFIG_SPLIT='\(.*\)'/\1/p" "$REPO_ROOT/src/cli/bin/nova-shell-config" | jq -cS .)
  [ -n "$js_split" ]
  [ "$js_split" = "$cli_split" ]
}

@test "put, move and set ask the shell, with only the placement given" {
  nova-bar put nova.weather left --index 2
  nova-bar put nova.weather --after nova.clock
  nova-bar move nova.media right
  nova-bar move nova.clock --from-section left --from-index 1 --section center
  nova-bar set nova.clock format HH:mm
  nova-bar set nova.batterylife indicator true --json --section right
  nova-bar remove nova.weather
  [ "$(cat "$CALLS")" = 'shell putBarWidget nova.weather {"section":"left","index":2}
shell putBarWidget nova.weather {"after":"nova.clock"}
shell moveBarWidget nova.media {"section":"right"}
shell moveBarWidget nova.clock {"section":"center","fromSection":"left","fromIndex":1}
shell setBarWidget nova.clock format "HH:mm" {}
shell setBarWidget nova.batterylife indicator true {"section":"right"}
shell setPluginEnabled nova.weather false' ]
}

@test "a placement that cannot be is refused before the shell is asked" {
  for args in "put" "put nova.weather middle" "put nova.weather left --section right" \
    "put nova.weather --before a --after b" "put nova.weather --from-index 1" \
    "move nova.media left --index 0" "move nova.media --index -1" "set nova.clock" \
    "set nova.clock format x --before a" "set nova.clock format {bad --json" "remove a b" "bogus"; do
    # shellcheck disable=SC2086 # the words of each case
    run nova-bar $args
    [ "$status" -eq 1 ]
  done
  [ ! -e "$CALLS" ]
}

@test "put: a widget the shell does not know is refused; no shell at all is no failure" {
  ANSWER=unknown run nova-bar put nova.nothing
  [ "$status" -eq 1 ]
  NOVA_SHELL_ABSENT_ATTEMPTS=2 ANSWER=absent run nova-bar put nova.weather
  [ "$status" -eq 0 ]
  [[ $output == *'not running'* ]]
}
