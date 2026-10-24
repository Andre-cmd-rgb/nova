#!/usr/bin/env bats

# nova-font-set: a family fontconfig lists is taken however long the list, and
# one it does not list is refused before anything is written. fc-list is a stub
# with the family first and a hundred thousand after it.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home
  mkdir -p "$SCRATCH/bin" "$HOME"
  stub fc-list "echo 'Noto Sans Mono,Noto Sans Mono Regular'; seq 100000 | sed 's/^/Family /'"
  local name
  for name in nova-restart-shell nova-hook nova-notification-send; do stub "$name" 'exit 0'; done
  stub pgrep 'exit 1'
  export PATH="$SCRATCH/bin:$PATH"
  config=$HOME/.config/fontconfig/conf.d/50-nova-monospace.conf
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

@test "a family early in a long list is taken" {
  run "$REPO_ROOT/src/cli/bin/nova-font-set" 'Noto Sans Mono'
  [ "$status" -eq 0 ]
  grep -Fq '<string>Noto Sans Mono</string></edit>' "$config"
}

@test "a family fontconfig does not list is refused, and nothing is written" {
  run "$REPO_ROOT/src/cli/bin/nova-font-set" 'Noto Sans'
  [ "$status" -eq 1 ]
  [[ $output == *"no font family named 'Noto Sans'"* ]]
  [ ! -e "$config" ]
}
