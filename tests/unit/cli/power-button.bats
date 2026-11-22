#!/usr/bin/env bats

# nova power button: what a press does, as Settings chose it, and that behind
# the lock it opens nothing (the menu, or a shutdown that talks to the user
# and closes windows), while sleep still sleeps. The shell's lock status, the
# menu, the shutdown and systemctl are stubs that note their calls.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home XDG_CONFIG_HOME=$SCRATCH/home/.config CALLS=$SCRATCH/calls LOCK=$SCRATCH/lock
  mkdir -p "$HOME" "$SCRATCH/bin"
  for name in nova-menu nova-system-shutdown systemctl; do
    printf '#!/bin/sh\necho "%s $*" >>"$CALLS"\n' "$name" >"$SCRATCH/bin/$name"
  done
  # The shell's answer, as the lock has it: the file's words, or no answer.
  cat >"$SCRATCH/bin/nova-shell" <<'STUB'
#!/bin/sh
[ "$*" = "lock status" ] && [ -f "$LOCK" ] || exit 1
cat "$LOCK"
STUB
  chmod +x "$SCRATCH"/bin/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

button() { "$REPO_ROOT/src/cli/bin/nova-power-button" "$@"; }

press() { # choice lock-status|none
  : >"$CALLS"
  button "$1"
  if [[ $2 == none ]]; then rm -f "$LOCK"; else printf '%s\n' "$2" >"$LOCK"; fi
  button press
  cat "$CALLS"
}

@test "the choice is kept, the menu by default" {
  [ "$(button)" = menu ]
  button sleep
  [ "$(button)" = sleep ]
  button off
  [ "$(button)" = off ]
  button menu
  [ "$(button)" = menu ]
  run button maybe
  [ "$status" -eq 2 ]
}

@test "unlocked, a press does what was chosen" {
  [ "$(press menu '{"locked":false}')" = 'nova-menu toggle system' ]
  [ "$(press off '{"locked":false}')" = 'nova-system-shutdown ' ]
  [ "$(press sleep '{"locked":false}')" = 'systemctl sleep' ]
}

@test "behind the lock, a press opens nothing, and sleep still sleeps" {
  [ "$(press menu '{"locked":true,"secure":true}')" = '' ]
  [ "$(press off '{"locked":true,"secure":true}')" = '' ]
  [ "$(press sleep '{"locked":true,"secure":true}')" = 'systemctl sleep' ]
}

@test "with the shell not answering, it is taken for locked" {
  [ "$(press menu none)" = '' ]
  [ "$(press off none)" = '' ]
  [ "$(press off 'not json')" = '' ]
  [ "$(press sleep none)" = 'systemctl sleep' ]
}
