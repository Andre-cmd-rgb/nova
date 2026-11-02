#!/usr/bin/env bats

# nova-bar-text-color picks, for a transparent bar, the text color or the
# background color: whichever stands out more against the wallpaper behind the
# bar. magick is a stub that answers the wallpaper's average color there, from
# $SCRATCH/pixel, and records the strip it was asked for.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home CALLS=$SCRATCH/calls
  mkdir -p "$SCRATCH/bin" "$HOME/.local/state/nova/current"
  : >"$SCRATCH/wall.jpg"
  ln -s "$SCRATCH/wall.jpg" "$HOME/.local/state/nova/current/background"
  printf '#!/bin/bash\necho "magick $*" >>"$CALLS"\ncat "$SCRATCH/pixel"\n' >"$SCRATCH/bin/magick"
  chmod +x "$SCRATCH/bin/magick"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

color() { "$REPO_ROOT/src/cli/bin/nova-bar-text-color" "$@"; }

@test "on a light wallpaper the dark color, on a dark one the light" {
  echo 250,250,250 >"$SCRATCH/pixel"
  run color top 30 '#cdd6f4' '#1e1e2e' --screen 1920x1200
  [ "$output" = '#1e1e2e' ]
  grep -qF -- '-crop 1920x30+0+0' "$CALLS"
  echo 10,10,10 >"$SCRATCH/pixel"
  run color bottom 30 '#cdd6f4' '#1e1e2e' --screen 1920x1200
  [ "$output" = '#cdd6f4' ]
  grep -qF -- '-crop 1920x30+0+1170' "$CALLS"
}

@test "anything it cannot tell answers the text color" {
  echo junk >"$SCRATCH/pixel"
  run color top 30 '#ffffff' '#000000' --screen 800x600
  [ "$output" = '#ffffff' ]
  run color top 30 white '#000000' --screen 800x600
  [ "$output" = white ]
  run color middle 30 '#ffffff' '#000000' --screen 800x600
  [ "$output" = '#ffffff' ]
  rm "$HOME/.local/state/nova/current/background"
  run color top 30 '#ffffff' '#000000' --screen 800x600
  [ "$output" = '#ffffff' ]
}
