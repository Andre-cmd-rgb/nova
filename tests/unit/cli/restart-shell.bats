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

@test "a lock screen up is never restarted, and the refusal says to try later" {
  stub nova-hyprland-session-locked
  stub nova-shell 'case $* in "lock status") echo "{\"secure\": true}" ;; esac'
  run restart
  [ "$status" -eq 75 ]
  [[ $output == *"Refusing to restart"* ]]
  fails grep -q "^quickshell kill" "$CALLS"
}

@test "a lock asked for and not yet up is waited out too" {
  stub nova-hyprland-session-locked
  stub nova-shell 'case $* in "lock status") echo "{\"secure\": false, \"requested\": true}" ;; esac'
  run restart
  [ "$status" -eq 75 ]
  fails grep -q "^quickshell kill" "$CALLS"
}

# A shell whose lock says it is secure once it was asked to lock, and how it
# stood before in $SCRATCH/lock-before (nothing printed when absent).
lock_answers() {
  stub nova-shell 'case $* in
    "lock status")
      if [[ -e $SCRATCH/asked ]]; then echo "{\"secure\": true}"
      elif [[ -e $SCRATCH/lock-before ]]; then cat "$SCRATCH/lock-before"
      else exit 1; fi ;;
    "lock lock") : >"$SCRATCH/asked" ;;
  esac'
}

@test "a session locked with no lock screen is restarted, and locked again" {
  stub nova-hyprland-session-locked
  lock_answers
  echo '{"secure": false, "requested": false}' >"$SCRATCH/lock-before"
  run restart
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^(hyprctl dispatch|nova-shell shell ping|nova-shell lock lock)' "$CALLS" | paste -sd,)" = \
    "hyprctl dispatch,nova-shell shell ping,nova-shell lock lock" ]
}

@test "a shell that does not answer for its lock is taken as one with none up" {
  stub nova-hyprland-session-locked
  lock_answers
  run restart
  [ "$status" -eq 0 ]
  grep -q "^nova-shell lock lock" "$CALLS"
  # Nor does a garbled answer stand for a lock screen.
  rm "$SCRATCH/asked" "$SCRATCH/killed"
  echo 'not json' >"$SCRATCH/lock-before"
  run restart
  [ "$status" -eq 0 ]
  grep -q "^nova-shell lock lock" "$CALLS"
}

@test "an unlocked session is not locked after the restart" {
  run restart
  [ "$status" -eq 0 ]
  fails grep -q "^nova-shell lock" "$CALLS"
}

@test "the new shell waits until the old one of this config is gone, not another's" {
  stub quickshell 'case $1 in
    kill) [[ ! -e $SCRATCH/killed ]] || exit 1; : >"$SCRATCH/killed" ;;
    list)
      echo x >>"$SCRATCH/listed"
      if (($(wc -l <"$SCRATCH/listed") < 3)); then
        printf "[{\"config_path\": \"%s\"}, {\"config_path\": \"/other/shell.qml\"}]\n" "$NOVA_PATH/shell/shell.qml"
      else
        echo "[{\"config_path\": \"/other/shell.qml\"}]"
      fi ;;
  esac'
  run restart
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^(quickshell list|hyprctl dispatch)' "$CALLS" | paste -sd,)" = \
    "quickshell list,quickshell list,quickshell list,hyprctl dispatch" ]
}

@test "from outside the session, the Hyprland instance whose directory is newest" {
  unset HYPRLAND_INSTANCE_SIGNATURE
  export XDG_RUNTIME_DIR=$SCRATCH/run
  mkdir -p "$XDG_RUNTIME_DIR/hypr/old" "$XDG_RUNTIME_DIR/hypr/new" "$SCRATCH/elsewhere"
  touch -d '2024-01-01' "$XDG_RUNTIME_DIR/hypr/old"
  touch -d '2024-01-02' "$XDG_RUNTIME_DIR/hypr/new"
  # A link is no instance of its own, however new.
  ln -s "$SCRATCH/elsewhere" "$XDG_RUNTIME_DIR/hypr/link"
  : >"$XDG_RUNTIME_DIR/hypr/file"
  stub hyprctl 'echo "instance $HYPRLAND_INSTANCE_SIGNATURE" >>"$CALLS"'
  run restart
  [ "$status" -eq 0 ]
  grep -qx "instance new" "$CALLS"
}
