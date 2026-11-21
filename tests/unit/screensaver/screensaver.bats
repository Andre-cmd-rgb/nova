#!/usr/bin/env bats

load ../test_helper

# Hyprland, foot, the theme and the effect are stubs that log their calls; so
# is nova-session-pgrep, which must never reach a real process here.
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
  # Nothing of the screensaver's running, and a signal for it sent.
  stub nova-session-pgrep '[[ $1 == --signal ]]'
  stub nova-shell 'echo false'
  stub nova-theme 'case $2 in
    accent) echo "#cba6ff" ;;
    hyprland_active_border) echo "#cba6ff #12bff4 45deg" ;;
  esac'
  stub nova-screensaver-effect
  export PATH="$SCRATCH/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/data/screensaver/nova-screensaver"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# What the terminal reads: nothing until the effect has started, then the key
# given, or the end of its input. A key that comes sooner ends the screensaver
# before the effect's call is logged.
input() { # [key]
  local _
  for _ in {1..100}; do
    if grep -q '^nova-screensaver-effect' "$CALLS" 2>/dev/null; then break; fi
    sleep 0.05
  done
  printf '%s' "${1:-}"
}

@test "a terminal on each display, one at a time, then focus goes back" {
  run main auto
  [ "$status" -eq 0 ]
  [ "$(grep -c 'exec_cmd(\[\[foot --app-id=org.nova.screensaver --config=/usr/share/nova/screensaver/foot.ini nova-screensaver-run\]\])' "$CALLS")" -eq 2 ]
  # Focus eDP-1, open, focus DP-2, open, back to eDP-1.
  [ "$(grep -o 'monitor = "[^"]*"' "$CALLS" | paste -sd' ')" = 'monitor = "eDP-1" monitor = "DP-2" monitor = "eDP-1"' ]
}

@test "the event listener stops once the windows are open, not at Hyprland's next event" {
  local state
  # A real listener stays connected after the events it was waiting for.
  stub socat 'echo $$ >"$SCRATCH/listener"
printf "openwindow>>a1,1,org.nova.screensaver,foot\nopenwindow>>a2,2,org.nova.screensaver,foot\n"
exec sleep 5'
  main auto
  for _ in {1..20}; do
    state=$(cut -d' ' -f3 "/proc/$(<"$SCRATCH/listener")/stat" 2>/dev/null) || break
    [[ $state != Z ]] || break
    sleep 0.1
  done
  [[ -z $state || $state == Z ]]
}

@test "auto leaves it be under the lock, and while it already shows" {
  stub nova-shell 'echo true'
  main auto
  fails grep -q exec_cmd "$CALLS"
  stub nova-shell 'echo false'
  stub nova-session-pgrep 'exit 0'
  main auto
  fails grep -q exec_cmd "$CALLS"
}

@test "shown by hand, it starts over" {
  stub nova-session-pgrep 'exit 0'
  main
  grep -qx 'nova-session-pgrep --signal TERM -f \[o\]rg.nova.screensaver' "$CALLS"
  grep -q exec_cmd "$CALLS"
}

@test "stop closes every window and brings the cursor back" {
  main stop
  grep -qx 'nova-session-pgrep --signal TERM -f \[o\]rg.nova.screensaver' "$CALLS"
  grep -q 'invisible = false' "$CALLS"
  run main sideways
  [ "$status" -eq 2 ]
}

@test "the terminal: plays the wordmark in the theme's colors, and a key ends every screensaver" {
  stub nova-screensaver-effect 'exec sleep 5'
  run "$REPO_ROOT/data/screensaver/nova-screensaver-run" < <(input q)
  [ "$status" -eq 0 ]
  grep -qx "nova-screensaver-effect --colors #cba6ff,#12bff4 $NOVA_WORDMARK" "$CALLS"
  grep -q 'invisible = true' "$CALLS"
  grep -q 'invisible = false' "$CALLS"
  grep -qx 'nova-session-pgrep --signal TERM -f \[o\]rg.nova.screensaver' "$CALLS"
}

@test "the terminal: your own text, and losing focus ends it too" {
  stub nova-screensaver-effect 'exec sleep 5'
  mkdir -p "$XDG_CONFIG_HOME/nova"
  echo hello >"$XDG_CONFIG_HOME/nova/screensaver.txt"
  ACTIVE=org.nova.terminal run "$REPO_ROOT/data/screensaver/nova-screensaver-run" < <(input)
  [ "$status" -eq 0 ]
  grep -qx "nova-screensaver-effect --colors #cba6ff,#12bff4 $XDG_CONFIG_HOME/nova/screensaver.txt" "$CALLS"
  grep -qx 'nova-session-pgrep --signal TERM -f \[o\]rg.nova.screensaver' "$CALLS"
}

@test "the terminal: focus leaving is heard from Hyprland's events, which it asks once" {
  stub nova-screensaver-effect 'exec sleep 10'
  stub socat 'printf "activewindow>>org.nova.terminal,before\n"; sleep 1.5
    printf "activewindow>>org.nova.screensaver,nova\n"; sleep 1
    printf "activewindow>>org.nova.terminal,shell\n"; exec sleep 10'
  local start=$SECONDS
  run timeout 8 "$REPO_ROOT/data/screensaver/nova-screensaver-run" < <(sleep 7)
  [ "$status" -eq 0 ]
  ((SECONDS - start < 6))
  grep -q '^socat -U - UNIX-CONNECT:.*/\.socket2\.sock$' "$CALLS"
  [ "$(grep -c '^hyprctl activewindow' "$CALLS")" -eq 1 ]
  grep -qx 'nova-session-pgrep --signal TERM -f \[o\]rg.nova.screensaver' "$CALLS"
}

@test "the terminal: another screensaver taking focus does not end it" {
  stub nova-screensaver-effect 'exec sleep 10'
  stub socat 'for _ in 1 2 3 4 5 6; do printf "activewindow>>org.nova.screensaver,nova\n"; sleep 0.5; done; exec sleep 10'
  local start=$SECONDS
  run timeout 8 "$REPO_ROOT/data/screensaver/nova-screensaver-run" < <(sleep 3.5; printf q)
  [ "$status" -eq 0 ]
  ((SECONDS - start >= 3))
  [ "$(grep -c '^hyprctl activewindow' "$CALLS")" -eq 1 ]
}

@test "the terminal: a theme with one color, or none to ask, leaves the rest to the effect" {
  stub nova-screensaver-effect 'exec sleep 5'
  stub nova-theme '[[ $2 == accent ]] && echo "#7aa2f7"'
  run "$REPO_ROOT/data/screensaver/nova-screensaver-run" < <(input q)
  grep -qx "nova-screensaver-effect --colors #7aa2f7 $NOVA_WORDMARK" "$CALLS"
  : >"$CALLS"
  stub nova-theme 'exit 1'
  run "$REPO_ROOT/data/screensaver/nova-screensaver-run" < <(input q)
  grep -qx "nova-screensaver-effect $NOVA_WORDMARK" "$CALLS"
  : >"$CALLS"
  stub nova-theme 'echo "rgb(1,2,3)"'
  run "$REPO_ROOT/data/screensaver/nova-screensaver-run" < <(input q)
  grep -qx "nova-screensaver-effect $NOVA_WORDMARK" "$CALLS"
}

@test "the terminal: an effect that cannot play ends the screensaver, not leaves a black window" {
  stub nova-screensaver-effect 'exit 1'
  run timeout 5 "$REPO_ROOT/data/screensaver/nova-screensaver-run" < <(sleep 4)
  [ "$status" -eq 0 ]
  grep -qx 'nova-session-pgrep --signal TERM -f \[o\]rg.nova.screensaver' "$CALLS"
  grep -q 'invisible = false' "$CALLS"
}
