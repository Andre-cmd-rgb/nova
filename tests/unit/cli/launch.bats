#!/usr/bin/env bats

# The launch helpers behind the app keys: a terminal app started in the
# default terminal under an app id of its own, or its window focused when it
# is open already, and the default editor opened where it runs. What would
# start something is a stub that logs its arguments to $CALLS, one quoted
# word each.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" CALLS="$SCRATCH/calls" CLIENTS="$SCRATCH/clients.json"
  unset HYPRLAND_INSTANCE_SIGNATURE
  mkdir -p "$HOME" "$SCRATCH/bin"
  stub hyprctl '[[ $1 != clients ]] || cat "$CLIENTS"'
  stub setsid
  stub uwsm-app
  echo '[{"address": "0xa", "class": "org.nova.btop", "title": "btop"}]' >"$CLIENTS"
  : >"$CALLS"
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:/usr/bin"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name 'arg'..." to $CALLS, then runs body
  printf '#!/bin/bash\n{ printf %%s %s; printf " %%q" "$@"; echo; } >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

@test "tui: the app id is org.nova. and the command's own name, unless given" {
  nova-launch-tui /usr/bin/htop -d 5
  nova-launch-tui --app-id=x.y nvim -- "a b"
  [ "$(cat "$CALLS")" = 'setsid uwsm-app -- xdg-terminal-exec --app-id=org.nova.htop -e /usr/bin/htop -d 5
setsid uwsm-app -- xdg-terminal-exec --app-id=x.y -e nvim -- a\ b' ]
}

@test "tui: no command is the usage" {
  run nova-launch-tui --app-id=x.y
  [ "$status" -eq 1 ]
  [ "$output" = "Usage: nova-launch-tui [--app-id=<app-id>] <command> [args...]" ]
  [ ! -s "$CALLS" ]
}

@test "or focus: an open window is focused, and nothing started" {
  nova-launch-or-focus btop "nova-launch-tui btop"
  [ "$(cat "$CALLS")" = "hyprctl clients -j
hyprctl dispatch hl.dsp.focus\\(\\{\\ window\\ =\\ \\\"address:0xa\\\"\\ \\}\\)" ]
}

@test "or focus tui: a command of several words is started whole" {
  nova-launch-or-focus-tui htop -d 5
  nova-launch-or-focus-tui --app-id=org.nova.top htop "a b"
  [ "$(grep '^setsid' "$CALLS")" = 'setsid nova-launch-tui htop -d 5
setsid nova-launch-tui --app-id=org.nova.top htop a\ b' ]
}

@test "or focus tui: the window is found by the app id the launch gives it" {
  nova-launch-or-focus-tui btop
  fails grep -q '^setsid' "$CALLS"
  grep -qF 'address:0xa' "$CALLS"
}

@test "editor: a terminal editor in a new terminal, or this one, and others on their own" {
  write_file "$HOME/.local/state/nova/defaults/editor" $'nvim\n'
  stub nvim
  stub nova-launch-tui
  nova-launch-editor notes.txt
  nova-launch-editor --inline notes.txt
  write_file "$HOME/.local/state/nova/defaults/editor" $'code\n'
  stub code
  nova-launch-editor notes.txt
  [ "$(cat "$CALLS")" = 'nova-launch-tui nvim -- notes.txt
nvim -- notes.txt
setsid uwsm-app -- code -- notes.txt' ]
}

@test "editor: one that is not installed is nano" {
  write_file "$HOME/.local/state/nova/defaults/editor" $'not-an-editor\n'
  stub nano
  nova-launch-editor --inline notes.txt
  [ "$(cat "$CALLS")" = 'nano -- notes.txt' ]
}
