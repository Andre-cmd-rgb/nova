#!/usr/bin/env bats

# nova-restart-shell against stubbed quickshell, hyprctl and nova-shell.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_PATH="$SCRATCH/share" HYPRLAND_INSTANCE_SIGNATURE=test CALLS="$SCRATCH/calls"
  write_file "$NOVA_PATH/shell/shell.qml"
  mkdir -p "$SCRATCH/bin"
  : >"$CALLS"
  # One instance to kill, then none.
  stub quickshell 'case $1 in
    kill) [[ ! -e $SCRATCH/killed ]] || exit 1; : >"$SCRATCH/killed" ;;
    list) echo "[]" ;;
  esac'
  stub hyprctl
  stub nova-shell
  stub nova-hyprland-session-locked 'exit 1'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

restart() { "$REPO_ROOT/src/cli/bin/nova-restart-shell"; }

@test "the old shell is stopped and a new one launched from Hyprland" {
  run restart
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^(quickshell kill|hyprctl dispatch)' "$CALLS" | paste -sd,)" = "quickshell kill,quickshell kill,hyprctl dispatch" ]
  grep -qF 'hyprctl dispatch hl.dsp.exec_cmd("nova-launch-shell")' "$CALLS"
}

@test "the terminal hanging up as the shell dies does not stop the restart" {
  # The kill takes a terminal the shell owned with it: the hangup reaches this
  # script, quickshell's grandparent past timeout.
  stub quickshell 'case $1 in
    kill) [[ ! -e $SCRATCH/killed ]] || exit 1; : >"$SCRATCH/killed"
          kill -HUP "$(ps -o ppid= -p "$PPID")" ;;
    list) echo "[]" ;;
  esac'
  run restart
  [ "$status" -eq 0 ]
  grep -qF 'hyprctl dispatch hl.dsp.exec_cmd("nova-launch-shell")' "$CALLS"
}
