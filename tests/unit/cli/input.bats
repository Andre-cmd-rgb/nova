#!/usr/bin/env bats

# nova input, behind Settings → Keyboard & Mouse: what it reads back from
# Hyprland, what it keeps, the Lua it writes from that, and what it refuses.
# Hyprland is a stub that answers getoption from $LIVE and logs every call;
# xkb's list of layouts is a few lines of the real one.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_STATE_HOME="$SCRATCH/state" CALLS="$SCRATCH/calls" LIVE="$SCRATCH/live"
  export NOVA_XKB_RULES="$SCRATCH/evdev.lst" XDG_RUNTIME_DIR="$SCRATCH/run" NOVA_PATH="$SCRATCH/nova"
  mkdir -p "$HOME" "$SCRATCH/bin" "$XDG_RUNTIME_DIR" "$NOVA_PATH/default/hypr"
  ln -s "$REPO_ROOT/data/hypr/keyboard.lua" "$NOVA_PATH/default/hypr/keyboard.lua"
  printf '%s\n' '! layout' '  us              English (US)' '  de              German' '  fr              French' '  ru              Russian' '' \
    '! variant' '  intl            us: English (US, intl., with dead keys)' '  nodeadkeys      de: German (no dead keys)' '' \
    '! option' '  grp:alts_toggle      Both Alts together' >"$NOVA_XKB_RULES"
  # Each getoption asked for, answered from $LIVE ("option<TAB>json"), in
  # Hyprland's form; nothing when Hyprland is not there ($LIVE missing).
  stub hyprctl '
[[ $1 == -j && $2 == --batch ]] || exit 0
[[ -f $LIVE ]] || exit 1
IFS=";" read -ra asked <<<"$3"
for one in "${asked[@]}"; do
  option=$(sed -E "s/^[[:space:]]*getoption //; s/[[:space:]]*$//" <<<"$one")
  value=$(awk -F "\t" -v o="$option" "\$1 == o { print \$2 }" "$LIVE")
  [[ -n $value ]] && printf "{\"option\": \"%s\", %s, \"set\": true }\n\n" "$option" "$value"
done'
  stub nova-hw-touchpad 'echo elan-touchpad'
  export PATH="$SCRATCH/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/cli/bin/nova-input"
  saved=$XDG_STATE_HOME/nova/input.json
  rules=$XDG_STATE_HOME/nova/toggles/hypr/input-settings.lua
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# Hyprland's settings as a P1 has them with Nova's defaults, one German.
live_p1() {
  printf '%s\t%s\n' \
    input:kb_layout '"str": "us,de"' input:kb_variant '"str": ",nodeadkeys"' \
    input:kb_options '"str": "compose:caps,shift:both_capslock_cancel,grp:alt_shift_toggle"' \
    input:repeat_delay '"int": 250' input:repeat_rate '"int": 40' input:sensitivity '"float": -0.300000' \
    input:natural_scroll '"bool": false' input:touchpad:natural_scroll '"bool": true' input:touchpad:tap_to_click '"bool": true' >"$LIVE"
}

@test "json: what Hyprland has in effect, its layouts with their variants, and the touchpad" {
  live_p1
  run cmd_json
  [ "$status" -eq 0 ]
  [ "$(jq -c "del(.nonLatin)" <<<"$output")" = '{"layouts":["us","de:nodeadkeys"],"switch":"alt-shift","repeat":{"delay":250,"rate":40},"speed":-0.3,"naturalScroll":{"mouse":false,"touchpad":true},"tapToClick":true,"touchpad":true}' ]
}

@test "json: a switch Settings does not offer is another one; none is none" {
  live_p1
  sed -i 's/grp:alt_shift_toggle/grp:win_space_toggle/' "$LIVE"
  [ "$(cmd_json | jq -r .switch)" = other ]
  sed -i 's/,grp:win_space_toggle//' "$LIVE"
  [ "$(cmd_json | jq -r .switch)" = none ]
}

@test "json: with no Hyprland to ask, what is kept, else Nova's, and no touchpad found" {
  stub nova-hw-touchpad 'exit 1'
  [ "$(cmd_json | jq -c "del(.nonLatin)")" = '{"layouts":[],"switch":"none","repeat":{"delay":250,"rate":40},"speed":0,"naturalScroll":{"mouse":false,"touchpad":true},"tapToClick":true,"touchpad":false}' ]
  write_file "$saved" '{"layouts":["de"],"switch":"alts","speed":0.5,"naturalScroll":{"touchpad":false},"tapToClick":false}'
  [ "$(cmd_json | jq -c "del(.nonLatin)")" = '{"layouts":["de"],"switch":"alts","repeat":{"delay":250,"rate":40},"speed":0.5,"naturalScroll":{"mouse":false,"touchpad":false},"tapToClick":false,"touchpad":false}' ]
}

@test "each change is kept, written out as Lua after the user's input.lua, and applied with a reload" {
  cmd_layouts us de:nodeadkeys
  cmd_switch ctrl-shift
  cmd_repeat 300 30
  cmd_speed -0.3
  cmd_natural_scroll mouse on
  cmd_natural_scroll touchpad off
  cmd_tap_to_click off
  [ "$(cat "$saved")" = '{"layouts":["us","de:nodeadkeys"],"switch":"ctrl-shift","repeat":{"delay":300,"rate":30},"speed":-0.3,"naturalScroll":{"mouse":true,"touchpad":false},"tapToClick":false}' ]
  [ "$(sed 1d "$rules")" = 'hl.config({ input = { repeat_delay = 300, repeat_rate = 30 } })
hl.config({ input = { sensitivity = -0.3 } })
hl.config({ input = { natural_scroll = true } })
hl.config({ input = { touchpad = { natural_scroll = false } } })
hl.config({ input = { touchpad = { tap_to_click = false } } })
hl.config({ input = require("default.hypr.keyboard").chosen({ "us", "de" }, { "", "nodeadkeys" }, "grp:ctrl_shift_toggle") })' ]
  [ "$(grep -c '^hyprctl reload$' "$CALLS")" -eq 7 ]
  cmd_switch none
  grep -qF '{ "", "nodeadkeys" }, "")' "$rules"
}

@test "layouts with no switch chosen leave the switch to the config: nil" {
  cmd_layouts ru
  [ "$(sed 1d "$rules")" = 'hl.config({ input = require("default.hypr.keyboard").chosen({ "ru" }, { "" }, nil) })' ]
}

@test "layouts: only xkb's, with their own variants, one to four, none twice; nothing kept on a refusal" {
  run cmd_layouts xx
  [ "$status" -eq 1 ]
  [[ $output == *"xkb has no layout 'xx'"* ]]
  run cmd_layouts de:intl
  [[ $output == *"xkb has no variant 'intl' of 'de'"* ]]
  run cmd_layouts 'us;os.execute("x")'
  [[ $output == *"no layout 'us;os.execute(\"x\")'"* ]]
  run cmd_layouts us de ru us:intl de:nodeadkeys
  [[ $output == *"one layout to four"* ]]
  run cmd_layouts
  [[ $output == *"one layout to four"* ]]
  run cmd_layouts de us de
  [[ $output == *"named twice"* ]]
  [ ! -e "$saved" ]
  [ ! -e "$rules" ]
  [ ! -e "$CALLS" ]
}

@test "layouts: four at most with the US a non-Latin first one gets, which keyboard.lua names" {
  run cmd_layouts ru de fr de:nodeadkeys
  [ "$status" -eq 1 ]
  [[ $output == *"ru first gets US ahead of it, and xkb takes four layouts at most"* ]]
  [ ! -e "$saved" ]
  cmd_layouts ru de fr us:intl
  cmd_layouts ru de fr
  cmd_layouts de fr ru us
  [ "$(jq -c .layouts "$saved")" = '["de","fr","ru","us"]' ]
  [ "$(cmd_json | jq -c '[(.nonLatin | index("ru") != null), (.nonLatin | index("de") != null)]')" = '[true,false]' ]
}

@test "with no Hyprland to tell, a change is kept all the same, and said to wait for it" {
  stub hyprctl 'exit 1'
  run cmd_speed 0.5
  [ "$status" -eq 0 ]
  [[ $output == *"kept; Hyprland takes it as it starts"* ]]
  [ "$(jq -c .speed "$saved")" = 0.5 ]
  grep -qF 'sensitivity = 0.5' "$rules"
}

@test "one change at a time: each waits for another under way, and none is lost" {
  local held
  exec {held}>>"$XDG_RUNTIME_DIR/nova-input.lock"
  flock "$held"
  "$REPO_ROOT/src/cli/bin/nova-input" speed 0.5 {held}>&- &
  sleep 0.5
  [ ! -e "$saved" ]
  exec {held}>&-
  wait
  [ "$(jq -c .speed "$saved")" = 0.5 ]
  for change in "switch none" "repeat 300 30" "speed -0.2" "natural-scroll mouse on" "natural-scroll touchpad off" "tap-to-click off"; do
    # shellcheck disable=SC2086 # the words are the arguments
    "$REPO_ROOT/src/cli/bin/nova-input" $change &
  done
  wait
  [ "$(jq -c '[.switch, .repeat.delay, .speed, .naturalScroll.mouse, .naturalScroll.touchpad, .tapToClick]' "$saved")" = '["none",300,-0.2,true,false,false]' ]
}

@test "the rest refuse what is not theirs" {
  run cmd_switch shift
  [[ $output == *"alts, alt-shift, ctrl-shift or none"* ]]
  run cmd_repeat 50 30
  [ "$status" -eq 1 ]
  run cmd_repeat 300 0
  [ "$status" -eq 1 ]
  run cmd_repeat 300
  [ "$status" -eq 1 ]
  run cmd_speed 1.5
  [ "$status" -eq 1 ]
  run cmd_speed fast
  [ "$status" -eq 1 ]
  run cmd_natural_scroll trackball on
  [ "$status" -eq 1 ]
  run cmd_tap_to_click yes
  [ "$status" -eq 1 ]
  [ ! -e "$saved" ]
}

@test "a kept file edited into other shapes writes only what is safe to run" {
  write_file "$saved" '{"layouts":["us\") os.execute(\"x"],"repeat":{"delay":"300","rate":30},"speed":9,"naturalScroll":{"mouse":"yes"},"tapToClick":true,"switch":"grp:x\")"}'
  write_rules
  [ "$(sed 1d "$rules")" = 'hl.config({ input = { touchpad = { tap_to_click = true } } })' ]
  write_file "$saved" '{"layouts":["us"],"switch":"x\") os.execute(\"y"}'
  write_rules
  [ "$(sed 1d "$rules")" = 'hl.config({ input = require("default.hypr.keyboard").chosen({ "us" }, { "" }, nil) })' ]
}

@test "with no arguments, what is in effect, in words" {
  live_p1
  run main
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Layouts: us, de:nodeadkeys, switched with alt-shift" ]
  [ "${lines[1]}" = "Key repeat: after 250 ms, 40 a second" ]
  [ "${lines[4]}" = "Tap to click: on" ]
  run main sideways
  [ "$status" -eq 1 ]
}
