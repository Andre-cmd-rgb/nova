#!/usr/bin/env bats

load ../test_helper

# Hyprland, foot and ttfx are stubs that log their calls; so are pgrep and
# pkill, which must never reach a real process here.
setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/home/.config"
  export NOVA_WORDMARK="$SCRATCH/nova.txt" CALLS="$SCRATCH/calls"
  mkdir -p "$HOME" "$SCRATCH/bin"
  echo nova >"$NOVA_WORDMARK"
  stub hyprctl 'case $1 in
    monitors) echo "[{\"name\":\"eDP-1\",\"focused\":true},{\"name\":\"DP-2\",\"focused\":false}]" ;;
    activewindow) echo "{\"class\":\"${ACTIVE:-org.nova.screensaver}\"}" ;;
  esac'
  stub socat 'printf "openwindow>>a1,1,org.nova.screensaver,foot\nopenwindow>>a2,2,org.nova.screensaver,foot\n"'
  stub pgrep 'exit 1'
  stub nova-shell 'echo false'
  for name in pkill ttfx; do stub "$name"; done
  export PATH="$SCRATCH/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/data/screensaver/nova-screensaver"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

@test "a terminal on each display, one at a time, then focus goes back" {
  run main auto
  [ "$status" -eq 0 ]
  [ "$(grep -c 'exec_cmd(\[\[foot --app-id=org.nova.screensaver --config=/usr/share/nova/screensaver/foot.ini nova-screensaver-run\]\])' "$CALLS")" -eq 2 ]
  # Focus eDP-1, open, focus DP-2, open, back to eDP-1.
  [ "$(grep -o 'monitor = "[^"]*"' "$CALLS" | paste -sd' ')" = 'monitor = "eDP-1" monitor = "DP-2" monitor = "eDP-1"' ]
}

@test "auto leaves it be under the lock, and while it already shows" {
  stub nova-shell 'echo true'
  main auto
  fails grep -q exec_cmd "$CALLS"
  stub nova-shell 'echo false'
  stub pgrep 'exit 0'
  main auto
  fails grep -q exec_cmd "$CALLS"
}

@test "shown by hand, it starts over" {
  stub pgrep 'exit 0'
  main
  grep -qx 'pkill -f \[o\]rg.nova.screensaver' "$CALLS"
  grep -q exec_cmd "$CALLS"
}

@test "stop closes every window and brings the cursor back" {
  main stop
  grep -qx 'pkill -f \[o\]rg.nova.screensaver' "$CALLS"
  grep -q 'invisible = false' "$CALLS"
  run main sideways
  [ "$status" -eq 2 ]
}

@test "without ttfx it says what to install" {
  local tool
  mkdir -p "$SCRATCH/sys"
  for tool in bash jq; do ln -s "$(command -v "$tool")" "$SCRATCH/sys/$tool"; done
  rm "$SCRATCH/bin/ttfx"
  PATH="$SCRATCH/bin:$SCRATCH/sys" run show
  [ "$status" -eq 1 ]
  [[ $output == *"sudo pacman -S ttfx"* ]]
}

@test "the terminal: plays the wordmark, and a key ends every screensaver" {
  stub ttfx 'exec sleep 5'
  run "$REPO_ROOT/data/screensaver/nova-screensaver-run" <<<q
  [ "$status" -eq 0 ]
  grep -q "ttfx -i $NOVA_WORDMARK --frame-rate 60 .*--random-effect" "$CALLS"
  grep -q 'invisible = true' "$CALLS"
  grep -q 'invisible = false' "$CALLS"
  grep -qx 'pkill -f \[o\]rg.nova.screensaver' "$CALLS"
}

@test "the terminal: your own text, and losing focus ends it too" {
  stub ttfx 'exec sleep 5'
  mkdir -p "$XDG_CONFIG_HOME/nova"
  echo hello >"$XDG_CONFIG_HOME/nova/screensaver.txt"
  ACTIVE=org.nova.terminal run "$REPO_ROOT/data/screensaver/nova-screensaver-run" </dev/null
  [ "$status" -eq 0 ]
  grep -q "ttfx -i $XDG_CONFIG_HOME/nova/screensaver.txt " "$CALLS"
  grep -qx 'pkill -f \[o\]rg.nova.screensaver' "$CALLS"
}
