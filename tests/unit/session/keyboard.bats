#!/usr/bin/env bats

# data/hypr/keyboard.lua, which the session's input.lua and the login greeter
# both take the keyboard layout from, against a scratch vconsole.conf.

load ../test_helper

setup() {
  setup_scratch
  sed "s,/etc/vconsole.conf,$SCRATCH/vconsole.conf," "$REPO_ROOT/data/hypr/keyboard.lua" >"$SCRATCH/keyboard.lua"
}

teardown() { teardown_scratch; }

layout() {
  KEYBOARD="$SCRATCH/keyboard.lua" lua -e \
    'local k = dofile(os.getenv("KEYBOARD")).layout(); io.write(k.layout, "|", k.variant, "|", k.options)' </dev/null
}

@test "the installer's layout and variant, as written" {
  printf 'KEYMAP=de-latin1-nodeadkeys\nXKBLAYOUT=de\nXKBVARIANT="nodeadkeys"\n' >"$SCRATCH/vconsole.conf"
  [ "$(layout)" = "de|nodeadkeys|" ]
}

@test "a non-Latin layout comes second, after US, switched with both Alts" {
  printf 'XKBLAYOUT=ru\n' >"$SCRATCH/vconsole.conf"
  [ "$(layout)" = "us,ru|,|grp:alts_toggle" ]
}

@test "no vconsole.conf: US" {
  [ "$(layout)" = "us||" ]
}

@test "the greeter takes its layout from the same file, and starts without it" {
  grep -q 'dofile("/usr/share/nova/default/hypr/keyboard.lua")' "$REPO_ROOT/data/session/greeter/greeter-hyprland.lua"
  grep -q 'pcall' "$REPO_ROOT/data/session/greeter/greeter-hyprland.lua"
}
