#!/usr/bin/env bats

# nova bar: the bar's edge and see-through look, written to shell.json and
# read back as the menu reads them, and the widgets placed by asking the
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

@test "the edge: top by default, set, read back, and nothing else taken" {
  [ "$(nova-bar position)" = top ]
  nova-bar position bottom
  [ "$(nova-bar position)" = bottom ]
  [ "$(settings .version)" = 1 ]
  grep -qx -- '-q shell reloadConfig' "$CALLS"
  run nova-bar position middle
  [ "$status" -eq 1 ]
  [ "$(nova-bar position)" = bottom ]
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
  for broken in '[]' 'not json' '{"bar":{"position":"left","transparent":true}}' '{"version":1,"bar":7}'; do
    echo "$broken" >"$HOME/.config/nova/shell.json"
    [ "$(nova-bar position)" = top ]
    [ "$(nova-bar transparent)" = off ]
  done
  echo '{"version":1,"bar":{"position":"left","transparent":true}}' >"$HOME/.config/nova/shell.json"
  [ "$(nova-bar position)" = left ]
  [ "$(nova-bar transparent)" = on ]
}

@test "defaults puts back the bar Nova ships, and the rest of the settings stay" {
  echo '{"version":1,"idle":{"lock":60},"bar":{"position":"left"}}' >"$HOME/.config/nova/shell.json"
  nova-bar defaults
  [ "$(settings .bar)" = "$(jq -cS .bar "$NOVA_PATH/default/shell.json")" ]
  [ "$(settings .idle.lock)" = 60 ]
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
