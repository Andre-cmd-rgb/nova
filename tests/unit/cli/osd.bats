#!/usr/bin/env bats

# nova-osd and nova-brightness-keyboard against stubs of the shell, nova and
# brightnessctl, and a keyboard light of the test's own (NOVA_LEDS_PATH).

load ../test_helper

setup() {
  setup_scratch
  export CALLS=$SCRATCH/calls NOVA_LEDS_PATH=$SCRATCH/leds
  mkdir -p "$SCRATCH/bin" "$NOVA_LEDS_PATH/input3::capslock" "$NOVA_LEDS_PATH/tpacpi::kbd_backlight"
  : >"$CALLS"
  stub nova-shell
  stub nova
  # A light of 3 levels, at 1.
  stub brightnessctl 'case "$*" in *" max") echo 3 ;; *" get") echo 1 ;; esac'
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

@test "osd: --help prints how to call it, and shows nothing" {
  run "$REPO_ROOT/src/cli/bin/nova-osd" --help
  [ "$status" -eq 0 ]
  [ "$output" = "Usage: nova-osd [-i|--icon <icon>] [-m|--message <text>] [-p|--progress <0-100>] [-d|--duration <ms>]" ]
  [ ! -s "$CALLS" ]
}

@test "osd: a level goes to the shell as text, with its percentage" {
  run "$REPO_ROOT/src/cli/bin/nova-osd" -i keyboard -p 40 -d 900
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = 'nova-shell -q osd show {"icon":"keyboard","message":"","value":"40","progressText":"40%","max":"100","duration":"900"}' ]
}

@test "osd: an option it does not know is refused" {
  run "$REPO_ROOT/src/cli/bin/nova-osd" --bogus
  [ "$status" -eq 1 ]
  [ "$output" = "Unknown OSD option: --bogus" ]
  [ ! -s "$CALLS" ]
}

@test "keyboard light: the device is the LED named kbd_backlight" {
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" device
  [ "$status" -eq 0 ]
  [ "$output" = "tpacpi::kbd_backlight" ]
}

@test "keyboard light: a step up, and round from the top to off" {
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" up
  [ "$status" -eq 0 ]
  grep -qx 'brightnessctl -d tpacpi::kbd_backlight set 2' "$CALLS"
  grep -qx 'nova-shell -q osd show {"icon":"keyboard","message":"","value":"66","progressText":"66%","max":"100","duration":""}' "$CALLS"
  stub brightnessctl 'case "$*" in *" max") echo 3 ;; *" get") echo 3 ;; esac'
  : >"$CALLS"
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" --no-osd cycle
  grep -qx 'brightnessctl -d tpacpi::kbd_backlight set 0' "$CALLS"
  fails grep -q '^nova-shell' "$CALLS"
}

@test "keyboard light: none there is an error" {
  rm -r "$NOVA_LEDS_PATH/tpacpi::kbd_backlight"
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" up
  [ "$status" -eq 1 ]
  [ "$output" = "No keyboard backlight device found" ]
}

@test "keyboard light: down stops at off, up at the top, and a wide range steps by a tenth" {
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" --no-osd down
  grep -qx 'brightnessctl -d tpacpi::kbd_backlight set 0' "$CALLS"
  stub brightnessctl 'case "$*" in *" max") echo 3 ;; *" get") echo 0 ;; esac'
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" --no-osd down
  grep -qx 'brightnessctl -d tpacpi::kbd_backlight set 0' "$CALLS"
  stub brightnessctl 'case "$*" in *" max") echo 3 ;; *" get") echo 3 ;; esac'
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" --no-osd up
  grep -qx 'brightnessctl -d tpacpi::kbd_backlight set 3' "$CALLS"
  stub brightnessctl 'case "$*" in *" max") echo 512 ;; *" get") echo 100 ;; esac'
  : >"$CALLS"
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" down
  grep -qx 'brightnessctl -d tpacpi::kbd_backlight set 49' "$CALLS"
  grep -q '"value":"9"' "$CALLS"
}

@test "keyboard light: off keeps the level for restore to put back" {
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" off
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" restore
  [ "$(cat "$CALLS")" = $'brightnessctl -sd tpacpi::kbd_backlight set 0\nbrightnessctl -rd tpacpi::kbd_backlight' ]
}

@test "keyboard light: anything else is refused" {
  run "$REPO_ROOT/src/cli/bin/nova-brightness-keyboard" brighter
  [ "$status" -eq 1 ]
  [[ $output == Usage:* ]]
  [ ! -s "$CALLS" ]
}
