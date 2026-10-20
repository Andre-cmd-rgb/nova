#!/usr/bin/env bats

# nova apps install against a stubbed AUR, pacman, git and makepkg: what it
# builds in each mode, and what it says.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" INSTALLED="$SCRATCH/installed" AUR_JSON="$SCRATCH/aur.json"
  mkdir -p "$SCRATCH/bin"
  : >"$INSTALLED"
  aur google-chrome 142.0-1 visual-studio-code-bin 1.142.0-1
  stub curl '[[ -s $AUR_JSON ]] || exit 7; cat "$AUR_JSON"'
  stub pacman '[[ $1 == -Q ]] || exit 1; grep "^$2 " "$INSTALLED" || exit 1'
  stub git 'mkdir -p "${@: -1}"'
  stub makepkg 'echo "built ${PWD##*/}" >>"$CALLS"'
  # Every repository's package list is there, unless a test removes one.
  export SYNC="$SCRATCH/db"
  mkdir -p "$SYNC/sync"
  touch "$SYNC/sync/nova.db" "$SYNC/sync/core.db" "$SYNC/sync/extra.db"
  stub pacman-conf 'case $1 in DBPath) echo "$SYNC/" ;; --repo-list) printf "%s\n" nova core extra ;; esac'
  stub sudo 'echo "sudo $*" >>"$CALLS"'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

aur() { # name version...: what the AUR answers
  local results=()
  while (($# > 0)); do results+=("{\"Name\":\"$1\",\"Version\":\"$2\"}"); shift 2; done
  printf '{"results":[%s]}' "$(IFS=,; echo "${results[*]}")" >"$AUR_JSON"
}

apps() { "$REPO_ROOT/src/cli/bin/nova-apps-install" "$@"; }
built() { cat "$CALLS" 2>/dev/null | paste -sd' '; }

@test "--check names the installed apps that are behind" {
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  echo "visual-studio-code-bin 1.142.0-1" >>"$INSTALLED"
  run apps --check
  [ "$status" -eq 0 ]
  [ "$output" = "apps google-chrome" ]
  [ -z "$(built)" ]
}

@test "--check says current when nothing installed is behind, missing ones aside" {
  echo "google-chrome 142.0-1" >>"$INSTALLED"
  run apps --check
  [ "$output" = current ]
}

@test "--check without the AUR says nothing and fails" {
  : >"$AUR_JSON"
  run apps --check
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "--update rebuilds what is behind and installs nothing new" {
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  run apps --update --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "built google-chrome" ]
  [[ $output == *"google-chrome 141.0-1 -> 142.0-1"* ]]
}

@test "a plain install adds what is missing and updates what is behind" {
  echo "visual-studio-code-bin 1.141.0-1" >>"$INSTALLED"
  run apps --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "built google-chrome built visual-studio-code-bin" ]
}

@test "up to date, nothing is built" {
  echo "google-chrome 142.0-1" >>"$INSTALLED"
  echo "visual-studio-code-bin 1.142.0-1" >>"$INSTALLED"
  run apps
  [ "$status" -eq 0 ]
  [ -z "$(built)" ]
  [[ $output == *"google-chrome is up to date (142.0-1)"* ]]
}

@test "without the AUR's versions, missing apps are still installed and the rest left alone" {
  : >"$AUR_JSON"
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  run apps --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "built visual-studio-code-bin" ]
  [[ $output == *"the AUR did not answer"* ]]
}

@test "a build that fails is named, and fails the run" {
  stub makepkg 'exit 1'
  run apps --noconfirm
  [ "$status" -eq 1 ]
  [[ $output == *"could not build google-chrome visual-studio-code-bin"* ]]
}

@test "a system without its repositories' package lists reads them once first" {
  rm "$SYNC/sync/core.db" "$SYNC/sync/extra.db"
  run apps --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "sudo pacman -Sy --noconfirm built google-chrome built visual-studio-code-bin" ]
}

@test "with every package list there, nothing is read before building" {
  run apps
  [ "$status" -eq 0 ]
  [ "$(built)" = "built google-chrome built visual-studio-code-bin" ]
}
