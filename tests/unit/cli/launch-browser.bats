#!/usr/bin/env bats

# nova-launch-browser: the default browser opened as its desktop entry says,
# a private window with the flag that browser takes, and the browser itself
# never run just to ask. The default comes from the real
# nova-cmd-default-browser, reading scratch XDG directories.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home CALLS=$SCRATCH/calls
  export XDG_DATA_HOME=$SCRATCH/data XDG_DATA_DIRS=$SCRATCH/none
  export XDG_CONFIG_HOME=$SCRATCH/config XDG_CONFIG_DIRS=$SCRATCH/none
  mkdir -p "$SCRATCH/bin" "$XDG_DATA_HOME/applications" "$XDG_CONFIG_HOME"
  ln -s "$REPO_ROOT/src/cli/bin/nova-cmd-default-browser" "$SCRATCH/bin/"
  export PATH="$SCRATCH/bin:$PATH"
  unset HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP
  stub nova-cmd-browser-handoff 'echo "handoff $*" >>"$CALLS"'
  stub systemd-run 'echo "systemd-run $*" >>"$CALLS"'
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# The default browser: chosen in mimeapps.list, its desktop entry in
# $XDG_DATA_HOME, and a command of that name that records being run. The rest
# of the Exec line is %U unless given.
browser() { # desktop-entry command [rest of the Exec line]
  printf '[Default Applications]\nx-scheme-handler/http=%s\n' "$1" >"$XDG_CONFIG_HOME/mimeapps.list"
  printf '[Desktop Entry]\nExec=%s %s\n' "$SCRATCH/bin/$2" "${3:-%U}" >"$XDG_DATA_HOME/applications/$1"
  stub "$2" 'echo "browser $*" >>"$CALLS"'
}

launch() { "$REPO_ROOT/src/cli/bin/nova-launch-browser" "$@"; }

@test "a private window: the flag of the browser's own family" {
  browser google-chrome.desktop google-chrome-stable
  launch --private https://example.org
  browser firefox.desktop firefox
  launch --private
  browser microsoft-edge.desktop microsoft-edge-stable
  launch --private
  [ "$(cut -d' ' -f3- "$CALLS")" = "$(printf '%s\n' '--incognito https://example.org' --private-window --inprivate)" ]
}

@test "the browser is handed the page, and never run to read its --help" {
  browser google-chrome.desktop google-chrome-stable
  launch https://example.org
  [ "$(cat "$CALLS")" = "handoff $SCRATCH/bin/google-chrome-stable https://example.org" ]
}

@test "a browser no window takes the page from is started" {
  browser google-chrome.desktop google-chrome-stable
  stub nova-cmd-browser-handoff 'exit 1'
  launch https://example.org
  [[ $(cat "$CALLS") == "systemd-run --user "*"uwsm-app -- $SCRATCH/bin/google-chrome-stable https://example.org" ]]
}

@test "the entry's own arguments stay, its field codes go, and the page comes last" {
  browser firefox.desktop firefox '-P Work --new-window %u'
  stub nova-cmd-browser-handoff 'exit 1'
  launch https://example.org
  [[ $(cat "$CALLS") == *"uwsm-app -- $SCRATCH/bin/firefox -P Work --new-window https://example.org" ]]
}

@test "a Flatpak browser: the whole command, and the private flag of what it runs" {
  browser org.mozilla.firefox.desktop flatpak 'run --branch=stable --command=firefox org.mozilla.firefox @@u %u @@'
  stub nova-cmd-browser-handoff 'exit 1'
  launch --private https://example.org
  [[ $(cat "$CALLS") == *"uwsm-app -- $SCRATCH/bin/flatpak run --branch=stable --command=firefox org.mozilla.firefox @@u @@ --private-window https://example.org" ]]
}

@test "quoted and escaped words in the Exec line are read as the specification says" {
  stub 'my browser' 'printf "browser %s|" "$@" >>"$CALLS"'
  printf '[Default Applications]\nx-scheme-handler/http=mine.desktop\n' >"$XDG_CONFIG_HOME/mimeapps.list"
  printf '[Desktop Entry]\nExec="%s" --title "a \\"b\\" c" 100%%%% %%U\n[Desktop Action new]\nExec=other\n' \
    "$SCRATCH/bin/my browser" >"$XDG_DATA_HOME/applications/mine.desktop"
  stub nova-cmd-browser-handoff 'shift; printf "handoff %s|" "$@" >>"$CALLS"'
  launch https://example.org
  [ "$(cat "$CALLS")" = 'handoff --title|handoff a "b" c|handoff 100%|handoff https://example.org|' ]
}

@test "--private is changed only where it is a whole argument" {
  browser google-chrome.desktop google-chrome-stable
  launch --private https://example.org/--private/report
  [ "$(cat "$CALLS")" = "handoff $SCRATCH/bin/google-chrome-stable --incognito https://example.org/--private/report" ]
}
