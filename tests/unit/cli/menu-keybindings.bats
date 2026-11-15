#!/usr/bin/env bats

# nova-menu-keybindings (SUPER + K) reads the keys from the Hyprland config,
# run again by Lua: Nova's data/hypr behind the skel's hyprland.lua, in a
# scratch HOME. hyprctl and the menu are stubs: the menu picks the line in
# $SCRATCH/pick, and hyprctl only records what it is asked.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home XDG_STATE_HOME=$SCRATCH/home/.local/state NOVA_PATH=$SCRATCH/nova CALLS=$SCRATCH/calls
  mkdir -p "$NOVA_PATH/default" "$HOME/.config/hypr" "$SCRATCH/bin"
  ln -s "$REPO_ROOT/data/hypr" "$NOVA_PATH/default/hypr"
  cp "$REPO_ROOT/data/skel/.config/hypr/hyprland.lua" "$HOME/.config/hypr/"
  : >"$HOME/.config/hypr/bindings.lua"
  for module in monitors input looknfeel autostart; do : >"$HOME/.config/hypr/$module.lua"; done
  : >"$CALLS"
  stub hyprctl 'echo ok'
  stub nova-menu-select 'cat >"$SCRATCH/options"; [[ -e $SCRATCH/pick ]] || exit 1; cat "$SCRATCH/pick"'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name body: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

keybindings() { "$REPO_ROOT/src/cli/bin/nova-menu-keybindings" "$@"; }

# The line --print shows for a description.
line_of() { keybindings --print | grep -F -- "→ $1" | head -n 1; }

pick() { # description
  line_of "$1" >"$SCRATCH/pick"
  [ -s "$SCRATCH/pick" ]
  : >"$CALLS"
  run keybindings
}

@test "--print lists the keys, most used first, and asks Hyprland nothing" {
  run keybindings --print
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<<"$output")" = "SUPER + K                           → Keybindings" ]
  [ "$(sed -n 2p <<<"$output")" = "SUPER + SPACE                       → Nova menu" ]
  [ "$(sed -n 3p <<<"$output")" = "SUPER + RETURN                      → Terminal" ]
  grep -qx 'SUPER SHIFT CTRL + EQUAL            → Expand window down a lot' <<<"$output"
  grep -qx 'SUPER + LEFT MOUSE BUTTON           → Move window' <<<"$output"
  [ ! -s "$CALLS" ]
}

@test "a description with a comma is shown whole" {
  run keybindings --print
  grep -qx 'SUPER + D                           → Dictation (hold to speak, tap for hands-free)' <<<"$output"
}

@test "keys bound without a description, and the Copilot key, are not listed" {
  run keybindings --print
  [ "$status" -eq 0 ]
  fails grep -E 'Lid Switch|F24|HL\.Dispatcher|function: ' <<<"$output"
  [ "$(grep -c '^SUPER + D ' <<<"$output")" -eq 1 ]
  [ "$(grep -c '→ Nova menu$' <<<"$output")" -eq 1 ]
}

@test "a pick runs its key's dispatcher in Hyprland" {
  pick "Keybindings"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(cat "$CALLS")" = 'nova-menu-select Keybindings -- --width 800 --height 500
hyprctl dispatch hl.dsp.exec_cmd("nova-menu-keybindings")' ]
  cmp "$SCRATCH/options" <(keybindings --print)

  pick "Shrink window up a lot"
  [ "$(tail -n 1 "$CALLS")" = 'hyprctl dispatch hl.dsp.window.resize({ relative = true, x = 0, y = -300 })' ]
  pick "Dictation (hold to speak, tap for hands-free)"
  [ "$(tail -n 1 "$CALLS")" = 'hyprctl dispatch hl.dsp.exec_cmd("nova-shell -q dictation press")' ]
}

@test "a key that runs a Lua function is listed, and its pick sends nothing" {
  pick "Universal copy"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^hyprctl' "$CALLS")" -eq 0 ]
}

@test "the menu put away, or nothing picked, runs nothing" {
  run keybindings
  [ "$status" -eq 0 ]
  : >"$SCRATCH/pick"
  run keybindings
  [ "$status" -eq 0 ]
  fails grep -q '^hyprctl' "$CALLS"
}

@test "your config's own keys, and Nova's you unbind, are as you left them" {
  cat >"$HOME/.config/hypr/bindings.lua" <<'EOF'
hl.unbind("SUPER + space")
nova.bind("SUPER + SPACE", "Launcher of my own", 'fuzzel --prompt "> "')
nova.bind("SUPER + SHIFT + R", [[SSH, to "home"]], "foot -e ssh home")
EOF
  run keybindings --print
  [ "$status" -eq 0 ]
  fails grep -q '^SUPER + SPACE .*→ Nova menu$' <<<"$output"
  grep -qx 'SUPER SHIFT + R                     → SSH, to "home"' <<<"$output"
  pick "Launcher of my own"
  [ "$(tail -n 1 "$CALLS")" = 'hyprctl dispatch hl.dsp.exec_cmd("fuzzel --prompt \"> \"")' ]
}

@test "with no config there is no list" {
  rm "$HOME/.config/hypr/hyprland.lua"
  run keybindings --print
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo x >"$SCRATCH/pick"
  run keybindings
  [ "$status" -eq 1 ]
  fails grep -q '^nova-menu-select\|^hyprctl' "$CALLS"
}
