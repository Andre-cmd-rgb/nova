#!/usr/bin/env bats

# nova-cmd-browser-handoff: a command line handed to the running browser over
# its profile's singleton socket, as a second browser process would hand it,
# and refused wherever a launch could do otherwise. The socket is one of the
# test's own, and socat a stub that keeps what it is sent and answers ACK. It
# needs Chrome's own binary to be there, as only that is handed to.

load ../test_helper

setup() {
  [[ -x /usr/bin/google-chrome-stable ]] || skip "no /usr/bin/google-chrome-stable here"
  [[ ! -e /etc/chrome-flags.conf ]] || skip "/etc/chrome-flags.conf here has flags of its own"
  setup_scratch
  export XDG_CONFIG_HOME=$SCRATCH/config
  mkdir -p "$SCRATCH/bin" "$XDG_CONFIG_HOME/google-chrome"
  python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$XDG_CONFIG_HOME/google-chrome/SingletonSocket"
  printf '#!/bin/bash\necho "$*" >"%s/socat-args"\ncat >"%s/sent"\necho -n "${REPLY_WITH-ACK}"\n' "$SCRATCH" "$SCRATCH" >"$SCRATCH/bin/socat"
  chmod +x "$SCRATCH/bin/socat"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { [[ -z ${SCRATCH:-} ]] || teardown_scratch; }

handoff() { "$REPO_ROOT/src/cli/bin/nova-cmd-browser-handoff" "$@"; }

@test "the arguments go to the running browser as a second process sends them" {
  cd "$SCRATCH"
  handoff google-chrome-stable https://example.org --incognito
  [ "$(tr '\0' '|' <"$SCRATCH/sent")" = "START|$SCRATCH|browser|https://example.org|--incognito" ]
  [ "$(cat "$SCRATCH/socat-args")" = "-t2 - UNIX-CONNECT:$XDG_CONFIG_HOME/google-chrome/SingletonSocket" ]
}

@test "Nova's own flags in the flags file are no bar; any other is, comments aside" {
  printf -- '--ozone-platform=wayland --password-store=gnome-libsecret # the keyring\n--enable-features=A,B\n# --kiosk\n--no-default-browser-check\n' >"$XDG_CONFIG_HOME/chrome-flags.conf"
  handoff google-chrome-stable https://example.org
  echo '--force-dark-mode' >>"$XDG_CONFIG_HOME/chrome-flags.conf"
  run handoff google-chrome-stable https://example.org
  [ "$status" -eq 1 ]
}

@test "another data directory, a wrapper, no socket or no answer: the caller launches" {
  run handoff google-chrome-stable --user-data-dir=/tmp/other https://example.org
  [ "$status" -eq 1 ]
  CHROME_CONFIG_HOME=/tmp/other run handoff google-chrome-stable https://example.org
  [ "$status" -eq 1 ]
  printf '#!/bin/sh\n' >"$SCRATCH/bin/chromium"
  chmod +x "$SCRATCH/bin/chromium"
  run handoff chromium https://example.org
  [ "$status" -eq 1 ]
  run handoff
  [ "$status" -eq 1 ]
  REPLY_WITH= run handoff google-chrome-stable https://example.org
  [ "$status" -eq 1 ]
  rm "$XDG_CONFIG_HOME/google-chrome/SingletonSocket"
  rm -f "$SCRATCH/sent"
  run handoff google-chrome-stable https://example.org
  [ "$status" -eq 1 ]
  [ ! -e "$SCRATCH/sent" ]
}
