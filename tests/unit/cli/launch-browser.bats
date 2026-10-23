#!/usr/bin/env bats

# nova-launch-browser: the default browser opened, a private window with the
# flag that browser takes, and the browser itself never run just to ask.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home CALLS=$SCRATCH/calls
  mkdir -p "$SCRATCH/bin" "$HOME/.local/share/applications"
  export PATH="$SCRATCH/bin:$PATH"
  unset HYPRLAND_INSTANCE_SIGNATURE
  stub nova-cmd-browser-handoff 'echo "handoff $*" >>"$CALLS"'
  stub systemd-run 'echo "systemd-run $*" >>"$CALLS"'
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# The default browser: its desktop entry, and a command of that name that
# records being run.
browser() { # desktop-entry command
  stub nova-cmd-default-browser "echo $1"
  printf '[Desktop Entry]\nExec=%s %%U\n' "$SCRATCH/bin/$2" >"$HOME/.local/share/applications/$1"
  stub "$2" 'echo "browser $*" >>"$CALLS"'
}

@test "a private window: the flag of the browser's own family" {
  browser google-chrome.desktop google-chrome-stable
  "$REPO_ROOT/src/cli/bin/nova-launch-browser" --private https://example.org
  browser firefox.desktop firefox
  "$REPO_ROOT/src/cli/bin/nova-launch-browser" --private
  browser microsoft-edge.desktop microsoft-edge-stable
  "$REPO_ROOT/src/cli/bin/nova-launch-browser" --private
  [ "$(cut -d' ' -f3- "$CALLS")" = "$(printf '%s\n' '--incognito https://example.org' --private-window --inprivate)" ]
}

@test "the browser is handed the page, and never run to read its --help" {
  browser google-chrome.desktop google-chrome-stable
  "$REPO_ROOT/src/cli/bin/nova-launch-browser" https://example.org
  [ "$(cat "$CALLS")" = "handoff $SCRATCH/bin/google-chrome-stable https://example.org" ]
}

@test "a browser no window takes the page from is started" {
  browser google-chrome.desktop google-chrome-stable
  stub nova-cmd-browser-handoff 'exit 1'
  "$REPO_ROOT/src/cli/bin/nova-launch-browser" https://example.org
  [[ $(cat "$CALLS") == "systemd-run --user "*"uwsm-app -- $SCRATCH/bin/google-chrome-stable https://example.org" ]]
}
