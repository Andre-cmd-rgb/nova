#!/usr/bin/env bats

# nova power button: what a press does, as Settings chose it, and that behind
# the lock it opens nothing (the menu, or a shutdown that talks to the user
# and closes windows), while sleep still sleeps; with the shell silent, a
# shutdown goes by the compositor's word. The shell's lock status, the
# compositor's, the menu, the shutdown and systemctl are stubs that note their
# calls.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home XDG_CONFIG_HOME=$SCRATCH/home/.config CALLS=$SCRATCH/calls LOCK=$SCRATCH/lock HYPR_LOCK=$SCRATCH/hypr-lock
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
  # Hyprland's: the file's exit status (0 locked, 1 unlocked), or 2, cannot tell.
  cat >"$SCRATCH/bin/nova-hyprland-session-locked" <<'STUB'
#!/bin/sh
exit "$(cat "$HYPR_LOCK" 2>/dev/null || echo 2)"
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

@test "a shell that is not locked but cannot say yet that the session is open counts as not answering" {
  # A shell started again under a lock a crashed one left holds no lock of its
  # own, and says so before it has asked the compositor about the other.
  echo 0 >"$HYPR_LOCK"
  [ "$(press menu '{"locked":false,"open":false}')" = '' ]
  [ "$(press off '{"locked":false,"open":false}')" = '' ]
  [ "$(press sleep '{"locked":false,"open":false}')" = 'systemctl sleep' ]
  # With no lock in the compositor a shutdown needs no shell; the menu waits.
  echo 1 >"$HYPR_LOCK"
  [ "$(press off '{"locked":false,"open":false}')" = 'nova-system-shutdown ' ]
  [ "$(press menu '{"locked":false,"open":false}')" = '' ]
  # Open, it does what was chosen.
  [ "$(press menu '{"locked":false,"open":true}')" = 'nova-menu toggle system' ]
}

@test "with the shell not answering, the menu opens nothing, and a shutdown asks the compositor" {
  # Hyprland holds a lock (one a crashed shell left), or cannot tell.
  echo 0 >"$HYPR_LOCK"
  [ "$(press menu none)" = '' ]
  [ "$(press off none)" = '' ]
  [ "$(press off 'not json')" = '' ]
  [ "$(press sleep none)" = 'systemctl sleep' ]
  rm -f "$HYPR_LOCK"
  [ "$(press off none)" = '' ]
  # Hyprland holds none: the screen is open, and a shutdown needs no shell.
  echo 1 >"$HYPR_LOCK"
  [ "$(press off none)" = 'nova-system-shutdown ' ]
  [ "$(press off 'not json')" = 'nova-system-shutdown ' ]
  [ "$(press menu none)" = '' ]
  # The shell's own word wins.
  [ "$(press off '{"locked":true,"secure":true}')" = '' ]
}
