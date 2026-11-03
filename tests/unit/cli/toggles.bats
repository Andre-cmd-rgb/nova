#!/usr/bin/env bats

# The toggles behind the menu and the keys: the night light, a touchpad
# turned off and kept off, and the bar. Hyprland, hyprsunset and the shell are
# stubs that log every call to $CALLS.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" CALLS="$SCRATCH/calls" HYPR="$SCRATCH/hypr"
  unset HYPRLAND_INSTANCE_SIGNATURE
  mkdir -p "$HOME" "$SCRATCH/bin" "$HYPR"
  # hyprsunset's temperature is $HYPR/temperature; one just started sets its
  # own back $HYPR/resets times.
  stub hyprctl '
case $1 in
  devices) cat "$HYPR/devices.json" ;;
  hyprsunset)
    if (($# == 3)); then
      resets=$(cat "$HYPR/resets" 2>/dev/null || echo 0)
      if ((resets > 0)); then echo $((resets - 1)) >"$HYPR/resets"; echo 6500 >"$HYPR/temperature"; else echo "$3" >"$HYPR/temperature"; fi
    else
      cat "$HYPR/temperature"
    fi ;;
esac'
  for name in nova-osd nova-shell nova-toggle setsid sleep; do stub "$name"; done
  stub pgrep 'echo 4242'
  : >"$CALLS"
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:/usr/bin"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

@test "night light status: tinted below 6000 K, and no temperature when hyprsunset cannot say" {
  echo 4000 >"$HYPR/temperature"
  [ "$(nova-toggle-nightlight --status)" = '{"enabled":true,"temperature":4000}' ]
  echo 6500 >"$HYPR/temperature"
  [ "$(nova-toggle-nightlight --status)" = '{"enabled":false,"temperature":6500}' ]
  rm "$HYPR/temperature"
  [ "$(nova-toggle-nightlight --status)" = '{"enabled":false,"temperature":null}' ]
  run nova-toggle-nightlight --nope
  [ "$status" -eq 2 ]
}

@test "night light: on from day, off from any tint, set again until a fresh hyprsunset keeps it" {
  echo 6500 >"$HYPR/temperature"
  echo 2 >"$HYPR/resets"
  nova-toggle-nightlight
  [ "$(cat "$HYPR/temperature")" = 4000 ]
  [ "$(grep -c '^hyprctl hyprsunset temperature 4000' "$CALLS")" -eq 3 ]
  grep -qx "nova-shell -q nightlight refresh" "$CALLS"
  echo 5000 >"$HYPR/temperature"
  nova-toggle-nightlight
  [ "$(cat "$HYPR/temperature")" = 6500 ]
}

@test "night light: on and off set night and day whatever the tint, and hold through a fresh hyprsunset" {
  echo 5000 >"$HYPR/temperature"
  nova-toggle-nightlight on
  [ "$(cat "$HYPR/temperature")" = 4000 ]
  nova-toggle-nightlight on
  [ "$(cat "$HYPR/temperature")" = 4000 ]
  nova-toggle-nightlight off
  [ "$(cat "$HYPR/temperature")" = 6500 ]
  nova-toggle-nightlight off
  [ "$(cat "$HYPR/temperature")" = 6500 ]
  echo 2 >"$HYPR/resets"
  nova-toggle-nightlight on
  [ "$(cat "$HYPR/temperature")" = 4000 ]
  [ "$(grep -c '^nova-shell -q nightlight refresh' "$CALLS")" -eq 5 ]
  run nova-toggle-nightlight sideways
  [ "$status" -eq 2 ]
  [ "$output" = "Usage: nova-toggle-nightlight [on|off|--status]" ]
}

@test "touchpad: off keeps its name for the config, on forgets it" {
  echo '{"mice": [{"name": "logitech-usb-receiver"}, {"name": "elan067a:00-04f3:3197-touchpad"}]}' >"$HYPR/devices.json"
  nova-toggle-touchpad
  [ "$(cat "$HOME/.local/state/nova/toggles/hypr/touchpad-disabled-name")" = "elan067a:00-04f3:3197-touchpad" ]
  grep -qxF 'hyprctl eval hl.device({ name = "elan067a:00-04f3:3197-touchpad", enabled = false })' "$CALLS"
  grep -qx "nova-osd -i touchpad -m Touchpad disabled" "$CALLS"
  nova-toggle-touchpad
  [ ! -e "$HOME/.local/state/nova/toggles/hypr/touchpad-disabled-name" ]
  grep -qxF 'hyprctl eval hl.device({ name = "elan067a:00-04f3:3197-touchpad", enabled = true })' "$CALLS"
}

@test "touchpad: a name with quotes stays a Lua string, and one with a control character is refused" {
  echo '{"mice": [{"name": "odd \"touchpad\" \\\\"}]}' >"$HYPR/devices.json"
  nova-toggle-touchpad off
  grep -qxF 'hyprctl eval hl.device({ name = "odd \"touchpad\" \\\\", enabled = false })' "$CALLS"
  echo '{"mice": [{"name": "bad\ttouchpad"}]}' >"$HYPR/devices.json"
  run nova-toggle-touchpad off
  [ "$status" -eq 1 ]
  [ "$output" = "Invalid touchpad device name" ]
}

@test "touchpad: none found is said, and what was kept is forgotten all the same" {
  echo '{"mice": []}' >"$HYPR/devices.json"
  write_file "$HOME/.local/state/nova/toggles/hypr/touchpad-disabled-name" $'gone\n'
  run nova-toggle-touchpad on
  [ "$status" -eq 1 ]
  [ "$output" = "No touchpad device found" ]
  [ ! -e "$HOME/.local/state/nova/toggles/hypr/touchpad-disabled-name" ]
}

@test "touchscreen: found among the touch devices, off and on by its name" {
  echo '{"mice": [{"name": "elan067a:00-04f3:3197-touchpad"}], "touch": [{"name": "wacom-hid-52eb-finger"}]}' >"$HYPR/devices.json"
  nova-toggle-input-device touchscreen off
  [ "$(cat "$HOME/.local/state/nova/toggles/hypr/touchscreen-disabled-name")" = "wacom-hid-52eb-finger" ]
  grep -qxF 'hyprctl eval hl.device({ name = "wacom-hid-52eb-finger", enabled = false })' "$CALLS"
  nova-toggle-input-device touchscreen on
  [ ! -e "$HOME/.local/state/nova/toggles/hypr/touchscreen-disabled-name" ]
  echo '{"mice": [], "touch": []}' >"$HYPR/devices.json"
  run nova-toggle-input-device touchscreen off
  [ "$output" = "No touchscreen device found" ]
}

@test "bar: on is its flag off, and the shell is told to look again" {
  nova-toggle-bar on
  nova-toggle-bar
  [ "$(cat "$CALLS")" = "nova-toggle bar-off off
nova-shell -q nova.bar syncHidden
nova-toggle bar-off toggle
nova-shell -q nova.bar syncHidden" ]
  run nova-toggle-bar sideways
  [ "$status" -eq 2 ]
}
