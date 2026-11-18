#!/usr/bin/env bats

# nova-capture-screenshot: where a screenshot goes for each action, the
# notification that opens it to edit, hardware cursors while it is taken, and
# the freeze ended after. nova-capture-region, grim, wl-copy, hyprctl, pidof,
# pkill and the notification are stubs that log; the picker's freeze is a sleep.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home CALLS=$SCRATCH/calls
  mkdir -p "$SCRATCH/bin" "$HOME/.config"
  echo 'XDG_PICTURES_DIR="$HOME/Shots"' >"$HOME/.config/user-dirs.dirs"
  echo '10,10 300x200' >"$SCRATCH/region"
  # The freeze writes nowhere, as the picker's does: holding the picker's
  # output open, it would keep the command reading for a region until it ended.
  stub nova-capture-region 'if [[ $1 == --thaw ]]; then echo "thaw" >>"$CALLS"; kill "$2"; exit; fi
sleep 30 >/dev/null 2>&1 & echo $! >"$SCRATCH/freezer"; echo $!; cat "$SCRATCH/region"; echo "region $*" >>"$CALLS"'
  stub grim 'echo "grim $*" >>"$CALLS"; if [[ $3 == - ]]; then echo PNG; else echo PNG >"$3"; fi'
  stub wl-copy 'echo "wl-copy $* $(cat)" >>"$CALLS"'
  stub hyprctl 'case $1 in getoption) echo "{\"int\": 1}" ;; *) echo "hyprctl $*" >>"$CALLS" ;; esac'
  stub pidof '[[ $* == "-q slurp" && -e $SCRATCH/slurp-up ]]'
  stub pkill '[[ -e $SCRATCH/slurp-up ]] && echo "pkill $*" >>"$CALLS"'
  stub nova-notification-send 'echo "notify $*" >>"$CALLS"'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() {
  if [[ -s $SCRATCH/freezer ]]; then kill "$(cat "$SCRATCH/freezer")" 2>/dev/null || true; fi
  teardown_scratch
}

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

shot() { "$REPO_ROOT/src/cli/bin/nova-capture-screenshot" "$@"; }

@test "a screenshot is saved to Pictures, put on the clipboard, and said, to edit" {
  run shot
  [ "$status" -eq 0 ]
  [[ $output =~ ^$HOME/Shots/screenshot-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.png$ ]]
  file=$output
  [ "$(cat "$file")" = PNG ]
  grep -qx 'region smart --keep-freeze' "$CALLS"
  grep -qx "grim -g 10,10 300x200 $file" "$CALLS"
  grep -qx 'wl-copy --type image/png PNG' "$CALLS"
  grep -qx "notify Screenshot saved to clipboard and file Edit with Super + Alt + , (or click this) --image $file --exec nova-image-edit $file satty" "$CALLS"
  grep -qx "notify Created screenshot directory: $HOME/Shots -t 2000" "$CALLS"
  # The still goes as soon as grim has it, and once.
  [ "$(grep -A1 '^grim' "$CALLS" | tail -1)" = thaw ]
  [ "$(grep -c '^thaw' "$CALLS")" -eq 1 ]
}

@test "hardware cursors while it is taken, the setting put back after, and the freeze ended" {
  shot region save
  [ "$(grep '^hyprctl' "$CALLS")" = 'hyprctl eval hl.config({ cursor = { no_hardware_cursors = 0 } })
hyprctl eval hl.config({ cursor = { no_hardware_cursors = 1 } })' ]
  # Ended: gone, or dead and not collected yet. The freeze is no child of the
  # command's, so it cannot wait for it, and in a container nothing may ever
  # collect it: a process that is dead still answers kill -0.
  local pid state=running
  pid=$(cat "$SCRATCH/freezer")
  for _ in {1..50}; do
    state=$(awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)
    [[ -n $state && $state != Z ]] || break
    sleep 0.1
  done
  [[ -z $state || $state == Z ]]
}

@test "copy puts it on the clipboard only; save saves it only" {
  run shot windows copy
  [ -z "$output" ]
  grep -qx 'region windows --keep-freeze' "$CALLS"
  grep -qx 'wl-copy --type image/png PNG' "$CALLS"
  fails grep -q '^notify Screenshot' "$CALLS"
  [ -z "$(ls -A "$HOME/Shots" 2>/dev/null)" ]
  : >"$CALLS"
  run shot fullscreen save
  [ -f "$output" ]
  fails grep -q -e '^wl-copy' -e '^notify Screenshot' "$CALLS"
}

@test "--editor names the editor the notification opens, wherever it is" {
  shot --editor=pinta region
  grep -q -- '--exec nova-image-edit .* pinta$' "$CALLS"
  grep -qx 'region region --keep-freeze' "$CALLS"
}

@test "a pick given up takes nothing" {
  : >"$SCRATCH/region"
  run shot
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  fails grep -q -e '^grim' -e '^notify Screenshot' "$CALLS"
}

@test "PRINT again while the picker is up puts it away" {
  touch "$SCRATCH/slurp-up"
  run shot
  [ "$status" -eq 0 ]
  grep -q '^pkill .*slurp' "$CALLS"
  fails grep -q '^region' "$CALLS"
}
