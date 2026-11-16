#!/usr/bin/env bats

# data/hypr/keyboard.lua, which the session's input.lua and the login greeter
# both take the keyboard layout from, against a scratch vconsole.conf; and
# the layouts Settings keeps, against a stand-in for Hyprland's options.

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

@test "vconsole.conf as a person writes it: spaces, quotes, comments, and the last line of a name" {
  printf '%s\n' '# XKBLAYOUT=fr' '  XKBLAYOUT = "gb"   # the office' "XKBVARIANT='extd'" \
    'XKBLAYOUTS=xx' 'XKBLAYOUT=de' 'XKBVARIANTX=no' >"$SCRATCH/vconsole.conf"
  [ "$(layout)" = "de|extd|" ]
  printf '%s\n' 'XKBLAYOUT="ru,us"' 'XKBVARIANT=' >"$SCRATCH/vconsole.conf"
  [ "$(layout)" = "us,ru,us|,|grp:alts_toggle" ]
}

@test "no vconsole.conf: US" {
  [ "$(layout)" = "us||" ]
}

# M.chosen, for the layouts Settings keeps (nova input): <lua lists and
# switch>, with the options Hyprland has so far as <options>.
chosen() { # options args
  KEYBOARD="$SCRATCH/keyboard.lua" OPTIONS="$1" lua -e '
    hl = { get_config = function(key) if key == "input.kb_options" then return os.getenv("OPTIONS") end end }
    local k = dofile(os.getenv("KEYBOARD")).chosen('"$2"')
    io.write(k.kb_layout, "|", k.kb_variant, "|", k.kb_options)' </dev/null
}

@test "Settings' layouts: the options set so far kept, their switch replaced by the one chosen" {
  [ "$(chosen 'compose:caps,grp:alts_toggle,shift:both_capslock_cancel' '{ "us", "de" }, { "", "nodeadkeys" }, "grp:alt_shift_toggle"')" = \
    "us,de|,nodeadkeys|compose:caps,shift:both_capslock_cancel,grp:alt_shift_toggle" ]
  [ "$(chosen 'compose:caps,grp:alts_toggle' '{ "us", "de" }, { "", "" }, ""')" = "us,de|,|compose:caps" ]
  [ "$(chosen 'compose:caps' '{ "de" }, { "" }, "grp:alts_toggle"')" = "de||compose:caps" ]
}

@test "Settings' layouts with no switch chosen: the one set so far, else both Alts" {
  [ "$(chosen 'compose:caps,grp:ctrl_shift_toggle' '{ "us", "de" }, { "", "" }, nil')" = "us,de|,|compose:caps,grp:ctrl_shift_toggle" ]
  [ "$(chosen 'compose:caps' '{ "us", "de" }, { "", "" }, nil')" = "us,de|,|compose:caps,grp:alts_toggle" ]
  [ "$(chosen '' '{ "fr" }, { "" }, nil')" = "fr||" ]
}

@test "Settings' layouts: a non-Latin one first gets US ahead of it" {
  [ "$(chosen 'compose:caps' '{ "ru", "de" }, { "phonetic", "" }, ""')" = "us,ru,de|,phonetic,|compose:caps" ]
}

@test "the greeter takes its layout from the same file, and starts without it" {
  grep -q 'dofile("/usr/share/nova/default/hypr/keyboard.lua")' "$REPO_ROOT/data/session/greeter/greeter-hyprland.lua"
  grep -q 'pcall' "$REPO_ROOT/data/session/greeter/greeter-hyprland.lua"
}
