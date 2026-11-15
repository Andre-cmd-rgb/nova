#!/usr/bin/env bats

# Clipboard text as the history keeps it: an entry for what was copied, and
# none for text too big to hold. wl-paste is a stub that lists no types.

load ../test_helper

plugin="$REPO_ROOT/src/shell/plugins/clipboard"

setup() {
  setup_scratch
  export XDG_STATE_HOME=$SCRATCH/state
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/bash\nexit 0\n' >"$SCRATCH/bin/wl-paste"
  chmod +x "$SCRATCH/bin/wl-paste"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

@test "text copied is an entry" {
  run "$plugin/capture.sh" text <<<"hello"
  [ "$output" = '{"type":"text","text":"hello\n"}' ]
}

@test "text over 1 MiB is no entry, and 1 MiB itself still is" {
  run bash -c "head -c \$((1 << 20)) /dev/zero | tr '\\0' a | '$plugin/capture.sh' text"
  [ "$(jq -r '.text | length' <<<"$output")" = $((1 << 20)) ]
  run bash -c "head -c \$(((1 << 20) + 1)) /dev/zero | tr '\\0' a | '$plugin/capture.sh' text"
  [ -z "$output" ]
}
