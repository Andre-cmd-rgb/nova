#!/usr/bin/env bats

# theme/cursor/build --tools, which make install runs first: the programs the
# cursor theme is drawn with, the missing ones named with their packages.

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/bin"
  local tool
  for tool in bash dirname; do ln -s "$(command -v "$tool")" "$SCRATCH/bin/$tool"; done
}

teardown() { teardown_scratch; }

tools() { PATH="$SCRATCH/bin" run "$REPO_ROOT/theme/cursor/build" --tools; }

@test "every missing program is named, with the package to install" {
  tools
  [ "$status" -eq 1 ]
  [[ $output == *"rsvg-convert xcursorgen hyprcursor-util, which are not installed: pacman -S librsvg xorg-xcursorgen hyprcursor"* ]]
}

@test "with the programs there, it passes" {
  local tool
  for tool in rsvg-convert xcursorgen hyprcursor-util; do
    printf '#!/bin/sh\n' >"$SCRATCH/bin/$tool"
    chmod +x "$SCRATCH/bin/$tool"
  done
  tools
  [ "$status" -eq 0 ]
  rm "$SCRATCH/bin/xcursorgen"
  tools
  [ "$status" -eq 1 ]
  [[ $output == *"xcursorgen, which is not installed: pacman -S xorg-xcursorgen" ]]
}

@test "make install asks for them before anything else" {
  run make -s -C "$REPO_ROOT" -n DESTDIR="$SCRATCH/root" install
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "theme/cursor/build --tools" ]]
}
