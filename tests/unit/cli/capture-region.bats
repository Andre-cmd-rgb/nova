#!/usr/bin/env bats

# nova-capture-region smart: a bare click takes what slurp was highlighting
# under it, the smallest rectangle there. Hyprland, slurp and hyprpicker are
# stubs: one 1000x800 monitor with a 200x200 window at 50,50.

load ../test_helper

setup() {
  setup_scratch
  export XDG_RUNTIME_DIR=$SCRATCH/run
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR"
  stub hyprctl 'case "$1 $2" in
  "monitors -j") echo "[{\"x\":0,\"y\":0,\"width\":1000,\"height\":800,\"scale\":1,\"transform\":0,\"focused\":true,\"activeWorkspace\":{\"id\":1},\"name\":\"eDP-1\"}]" ;;
  "clients -j") echo "[{\"at\":[50,50],\"size\":[200,200],\"workspace\":{\"id\":1},\"hidden\":false}]" ;;
esac'
  stub hyprpicker 'sleep 5'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

click() { # x y
  stub slurp "cat >/dev/null; echo '$1,$2 1x1'"
  run "$REPO_ROOT/src/cli/bin/nova-capture-region" smart
}

@test "a click inside a window takes the window, not its monitor" {
  click 100 100
  [ "$status" -eq 0 ]
  [ "$output" = '50,50 200x200' ]
}

@test "a click beside every window takes the monitor" {
  click 600 600
  [ "$status" -eq 0 ]
  [ "$output" = '0,0 1000x800' ]
}

@test "a dragged region stays as it was drawn" {
  stub slurp "cat >/dev/null; echo '10,10 300x300'"
  run "$REPO_ROOT/src/cli/bin/nova-capture-region" smart
  [ "$output" = '10,10 300x300' ]
}
