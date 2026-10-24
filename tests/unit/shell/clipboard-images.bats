#!/usr/bin/env bats

# Clipboard images on disk: one no history entry names is deleted, unless it
# was written in the last minute and its entry may still be on its way; one
# copied again is fresh again. wl-paste is a stub that lists no types.

load ../test_helper

plugin="$REPO_ROOT/src/shell/plugins/clipboard"

setup() {
  setup_scratch
  export XDG_STATE_HOME=$SCRATCH/state
  images=$XDG_STATE_HOME/nova/clipboard-images
  mkdir -p "$images" "$SCRATCH/bin"
  printf '#!/bin/bash\nexit 0\n' >"$SCRATCH/bin/wl-paste"
  chmod +x "$SCRATCH/bin/wl-paste"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

@test "an image the history no longer names goes, a new one and a named one stay" {
  local name
  for name in kept.png dropped.png clipboard.AbC123; do
    echo "$name" >"$images/$name"
    touch -d '2 minutes ago' "$images/$name"
  done
  echo new >"$images/new.png"
  # Named by another spelling of the same directory.
  "$plugin/prune-images.sh" "$XDG_STATE_HOME//nova/clipboard-images/kept.png"
  [ "$(ls "$images" | paste -sd ' ')" = 'kept.png new.png' ]
}

@test "an image copied again is fresh again" {
  printf 'png bytes' >"$SCRATCH/copied"
  local hash
  hash=$(sha256sum "$SCRATCH/copied" | cut -d' ' -f1)
  cp "$SCRATCH/copied" "$images/$hash.png"
  touch -d '2 minutes ago' "$images/$hash.png"
  "$plugin/capture.sh" image/png <"$SCRATCH/copied" >/dev/null
  "$plugin/prune-images.sh"
  [ -e "$images/$hash.png" ]
}
