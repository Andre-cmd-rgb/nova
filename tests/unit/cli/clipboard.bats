#!/usr/bin/env bats

# The clipboard's paste and open helpers take the history entry the shell
# picked: by its index, and only while the md5 of its key is the one sent. A
# copy made in between moves every entry down one. wl-copy and the editor are
# stubs that record what they were given.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home XDG_STATE_HOME=$SCRATCH/home/.local/state CALLS=$SCRATCH/calls
  mkdir -p "$SCRATCH/bin" "$HOME/.local/state/nova"
  stub wl-copy 'printf "wl-copy %s\n" "$(cat)" >>"$CALLS"'
  stub nova-launch-editor 'printf "editor %s\n" "$(cat "$1")" >>"$CALLS"'
  export PATH="$SCRATCH/bin:$PATH"
  # The shell picked "picked" at index 0; a copy since put "newer" before it.
  jq -n '[{type: "text", text: "newer"}, {type: "text", text: "picked"}]' \
    >"$HOME/.local/state/nova/clipboard-history.json"
  picked=$(printf 'text:picked' | md5sum | cut -d' ' -f1)
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

@test "paste: an entry moved since it was picked is not taken" {
  run "$REPO_ROOT/src/cli/bin/nova-clipboard-paste-text" --copy-only --history-index 0 --history-md5 "$picked"
  [ "$status" -eq 1 ]
  [ ! -e "$CALLS" ]
}

@test "paste: the entry picked, where it still is" {
  run "$REPO_ROOT/src/cli/bin/nova-clipboard-paste-text" --copy-only --history-index 1 --history-md5 "$picked"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = 'wl-copy picked' ]
}

@test "open: an entry moved since it was picked is not opened, the one picked is" {
  run "$REPO_ROOT/src/cli/bin/nova-clipboard-open" --history-index 0 --history-md5 "$picked"
  [ "$status" -eq 1 ]
  [ ! -e "$CALLS" ]
  run "$REPO_ROOT/src/cli/bin/nova-clipboard-open" --history-index 1 --history-md5 "$picked"
  [ "$(cat "$CALLS")" = 'editor picked' ]
}

@test "open: of a text with web addresses, the first is opened in the browser" {
  stub nova-launch-browser 'printf "browser %s|" "$@" >>"$CALLS"'
  # Two on one line: the browser was once given both, as one argument.
  jq -n '[{type: "text", text: "see https://example.com/a?b=1 and http://two.org"}]' \
    >"$HOME/.local/state/nova/clipboard-history.json"
  run "$REPO_ROOT/src/cli/bin/nova-clipboard-open" --history-index 0
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = 'browser https://example.com/a?b=1|' ]
}

@test "open: a text that is only a domain and a path is opened as https" {
  stub nova-launch-browser 'printf "browser %s|" "$@" >>"$CALLS"'
  jq -n '[{type: "text", text: "  example.org/docs  "}]' >"$HOME/.local/state/nova/clipboard-history.json"
  run "$REPO_ROOT/src/cli/bin/nova-clipboard-open" --history-index 0
  [ "$(cat "$CALLS")" = 'browser https://example.org/docs|' ]
}
