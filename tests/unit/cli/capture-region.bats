#!/usr/bin/env bats

# nova-capture-region: the shell's picker asked first, and its answer, its
# freeze kept or thawed; without it, what a pick gives in each mode, a bare
# click taking what slurp was highlighting under it, the keys that end a pick
# or move its highlight while slurp is up; and a monitor named for a region
# that is one. Hyprland, the shell, slurp, hyprpicker, pgrep and pkill are
# stubs: one 1000x800 monitor with a 200x200 window at 50,50, unless a test
# lays out its own, and no shell, unless a test starts one.

load ../test_helper

setup() {
  setup_scratch
  export XDG_RUNTIME_DIR=$SCRATCH/run CALLS=$SCRATCH/calls
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR"
  echo '[{"x":0,"y":0,"width":1000,"height":800,"scale":1,"transform":0,"focused":true,"activeWorkspace":{"id":1},"name":"eDP-1"}]' >"$SCRATCH/monitors"
  echo '[{"at":[50,50],"size":[200,200],"workspace":{"id":1},"hidden":false}]' >"$SCRATCH/clients"
  echo '100, 100' >"$SCRATCH/pointer"
  stub hyprctl 'case "$1 ${2:-}" in
  "monitors -j") cat "$SCRATCH/monitors" ;;
  "clients -j") cat "$SCRATCH/clients" ;;
  "cursorpos ") cat "$SCRATCH/pointer" ;;
  "layers -j") if [[ -e $SCRATCH/frozen ]]; then echo "{\"namespace\": \"hyprpicker\"}"; else echo "{}"; fi ;;
  *) [[ $* =~ x\ =\ (-?[0-9]+),\ y\ =\ (-?[0-9]+) ]] && echo "move ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" >>"$CALLS" ;;
esac'
  # The still is on screen as hyprpicker starts.
  stub hyprpicker 'touch "$SCRATCH/frozen"; exec sleep 5'
  stub pgrep 'exit 0'
  stub pkill 'echo "pkill $*" >>"$CALLS"'
  stub nova-shell 'exit 1'
  export PATH="$SCRATCH/bin:$PATH"
}

# A shell whose picker answers a pick with what is in $SCRATCH/answer, a
# moment later, and notes what it is asked.
shell_picks() { # answer
  printf '%s\n' "$1" >"$SCRATCH/answer"
  stub nova-shell 'echo "shell $*" >>"$CALLS"
case "$1 $2" in
  "nova.capture pick") (sleep 0.2; cat "$SCRATCH/answer" >"$4") & echo ok ;;
  "nova.capture waiting") echo yes ;;
esac'
  stub hyprpicker 'echo hyprpicker >>"$CALLS"; exec sleep 5'
  stub slurp 'echo slurp >>"$CALLS"; cat >/dev/null'
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

region() { "$REPO_ROOT/src/cli/bin/nova-capture-region" "$@"; }

click() { # x y
  stub slurp "cat >/dev/null; echo '$1,$2 1x1'"
  run region smart
}

@test "the shell's picker picks: its answer, nothing of slurp's, and the still thawed after" {
  shell_picks '10,20 300x200'
  for mode in smart region windows; do
    : >"$CALLS"
    run region "$mode"
    [ "$status" -eq 0 ]
    [ "$output" = '10,20 300x200' ]
    grep -q "^shell nova.capture pick $mode $XDG_RUNTIME_DIR/nova/capture-" "$CALLS"
    grep -q "^shell -q nova.capture thaw $XDG_RUNTIME_DIR/nova/capture-" "$CALLS"
    fails grep -qx -e hyprpicker -e slurp "$CALLS"
  done
  # The FIFO goes with the freeze.
  [ -z "$(ls "$XDG_RUNTIME_DIR/nova" | grep '^capture-')" ]
}

@test "the shell's freeze kept for the caller, before the region, until --thaw" {
  shell_picks '10,20 300x200'
  run region region --keep-freeze
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "shell:$XDG_RUNTIME_DIR/nova/capture-"* ]]
  [ "${lines[1]}" = '10,20 300x200' ]
  fails grep -q thaw "$CALLS"
  [ -p "${lines[0]#shell:}" ]
  region --thaw "${lines[0]}"
  grep -qx "shell -q nova.capture thaw ${lines[0]#shell:}" "$CALLS"
  [ ! -e "${lines[0]#shell:}" ]
}

@test "a pick given up in the shell gives nothing and fails, and so does a shell that let it go" {
  shell_picks ''
  run region smart
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # Asked whether it still has the request, the shell says no: given up.
  stub nova-shell 'echo "shell $*" >>"$CALLS"
case "$1 $2" in
  "nova.capture pick") echo ok ;;
  "nova.capture waiting") echo no ;;
esac'
  : >"$CALLS"
  NOVA_CAPTURE_PATIENCE=0.2 run region smart
  [ "$status" -eq 1 ]
  [ "$(grep -c "^shell nova.capture waiting $XDG_RUNTIME_DIR/nova/capture-" "$CALLS")" -eq 1 ]
  # A shell that does not answer is asked three times, then given up on.
  stub nova-shell 'echo "shell $*" >>"$CALLS"
case "$1 $2" in
  "nova.capture pick") echo ok ;;
  *) exit 1 ;;
esac'
  : >"$CALLS"
  NOVA_CAPTURE_PATIENCE=0.2 run region smart
  [ "$status" -eq 1 ]
  [ "$(grep -c "^shell nova.capture waiting " "$CALLS")" -eq 3 ]
}

@test "PRINT's screenshot asks with the token the shell gave it, any other with none" {
  shell_picks '10,20 300x200'
  NOVA_CAPTURE_PICK=print-1 run region smart
  grep -q "^shell nova.capture pick smart $XDG_RUNTIME_DIR/nova/capture-[^ ]* print-1$" "$CALLS"
  : >"$CALLS"
  run region smart
  grep -q "^shell nova.capture pick smart $XDG_RUNTIME_DIR/nova/capture-[^ ]* -$" "$CALLS"
}

@test "--layout is what is offered: the focused monitor, the monitors, the windows" {
  run region --layout
  [ "$status" -eq 0 ]
  [ "$output" = $'focused 0,0 1000x800\nmonitor 0,0 1000x800\nwindow 50,50 200x200' ]
}

@test "a click inside a window takes the window, not its monitor" {
  click 100 100
  [ "$status" -eq 0 ]
  [ "$output" = '50,50 200x200' ]
}

@test "a click beside every window takes the monitor" {
  click 600 600
  [ "$status" -eq 0 ]
  [ "$output" = '0,0 1000x800' ]
}

@test "a dragged region stays as it was drawn" {
  stub slurp "cat >/dev/null; echo '10,10 300x300'"
  run region smart
  [ "$output" = '10,10 300x300' ]
}

@test "slurp comes up once the still of the screen is on it, and not before" {
  stub hyprpicker 'sleep 0.3; touch "$SCRATCH/frozen"; exec sleep 5'
  stub slurp 'if [[ -e $SCRATCH/frozen ]]; then echo after >"$SCRATCH/slurp-when"; else echo before >"$SCRATCH/slurp-when"; fi; cat >/dev/null; echo "10,10 300x300"'
  for mode in smart region windows; do
    rm -f "$SCRATCH/frozen" "$SCRATCH/slurp-when"
    run region "$mode"
    [ "$output" = '10,10 300x300' ]
    [ "$(cat "$SCRATCH/slurp-when")" = after ]
  done
}

@test "a hyprpicker that cannot start holds nothing up" {
  stub hyprpicker 'exit 1'
  stub slurp 'cat >/dev/null; echo "10,10 300x300"'
  run region smart
  [ "$status" -eq 0 ]
  [ "$output" = '10,10 300x300' ]
}

@test "a pick given up gives nothing and fails" {
  stub slurp 'cat >/dev/null; exit 1'
  run region smart
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "windows offers slurp the monitors and the windows to choose from" {
  stub slurp 'echo "$*" >"$SCRATCH/slurp-args"; cat >"$SCRATCH/slurp-in"; echo "50,50 200x200"'
  run region windows
  [ "$output" = '50,50 200x200' ]
  [ "$(cat "$SCRATCH/slurp-args")" = '-r' ]
  [ "$(cat "$SCRATCH/slurp-in")" = $'0,0 1000x800\n50,50 200x200' ]
}

@test "fullscreen is the focused monitor, in logical pixels, turned" {
  echo '[{"x":0,"y":0,"width":2000,"height":1000,"scale":2,"transform":1,"focused":true,"activeWorkspace":{"id":1},"name":"eDP-1"}]' >"$SCRATCH/monitors"
  run region fullscreen
  [ "$output" = '0,0 500x1000' ]
}

@test "a region that is a monitor is named for it" {
  click 600 600
  run region smart --match-monitor
  [ "$output" = 'monitor:eDP-1' ]
  click 100 100
  run region smart --match-monitor
  [ "$output" = '50,50 200x200' ]
}

@test "the screen is kept frozen for the caller, its PID before the region" {
  stub slurp "cat >/dev/null; echo '10,10 300x300'"
  run region region --keep-freeze
  kill "${lines[0]}"
  [[ ${lines[0]} =~ ^[0-9]+$ ]]
  [ "${lines[1]}" = '10,10 300x300' ]
}

@test "RETURN ends the pick with the window under the pointer, CTRL + RETURN with the screen" {
  stub slurp 'cat >/dev/null; "$REPO_ROOT/src/cli/bin/nova-capture-region" "$TAKE"; exit 1'
  TAKE=--take-window run region smart
  [ "$output" = '50,50 200x200' ]
  [ "$(cat "$CALLS")" = 'pkill -x slurp' ]
  TAKE=--take-fullscreen run region smart
  [ "$output" = '0,0 1000x800' ]
  # Given up after either, the next pick takes nothing from it.
  stub slurp 'cat >/dev/null; exit 1'
  run region smart
  [ "$status" -eq 1 ]
}

@test "the keys do nothing while no pick is up" {
  stub pgrep 'exit 1'
  run region --take-window
  [ "$status" -eq 0 ]
  run region --select-window next
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS" ]
}

# Four windows: A and B side by side at the top, C across the bottom, and a
# small floating D over A's middle, so that the pointer goes to a point of
# A's own (187,200) to highlight it. Reading order is A, B, D, C.
four_windows() {
  printf '[%s,%s,%s,%s]\n' \
    '{"at":[0,0],"size":[500,400],"workspace":{"id":1},"hidden":false}' \
    '{"at":[500,0],"size":[500,400],"workspace":{"id":1},"hidden":false}' \
    '{"at":[0,400],"size":[1000,400],"workspace":{"id":1},"hidden":false}' \
    '{"at":[200,150],"size":[100,100],"workspace":{"id":1},"hidden":false}' >"$SCRATCH/clients"
}

moves() { # pointer direction...: where each direction moves the pointer from there
  local direction
  for direction in "${@:2}"; do
    echo "$1" >"$SCRATCH/pointer"
    : >"$CALLS"
    region --select-window "$direction"
    printf '%s=%s\n' "$direction" "$(cat "$CALLS")"
  done
}

@test "TAB and CTRL + TAB go round the windows in reading order" {
  four_windows
  [ "$(moves '250, 200' next prev)" = $'next=move 500 600\nprev=move 750 200' ]
  [ "$(moves '900, 700' next prev)" = $'next=move 187 200\nprev=move 250 200' ]
}

@test "the arrows go to the nearest window that way, a step aside counting double" {
  four_windows
  [ "$(moves '250, 200' left right up down)" = $'left=\nright=move 750 200\nup=\ndown=move 500 600' ]
  # Three at the same score: the first in reading order.
  [ "$(moves '900, 700' up)" = 'up=move 187 200' ]
}

@test "with no windows there is nowhere to go" {
  echo '[]' >"$SCRATCH/clients"
  run region --select-window next
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}
