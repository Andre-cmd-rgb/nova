#!/usr/bin/env bats

# Do Not Disturb's hours, written to shell.json and said back. The shell is a
# stub that writes down each call.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" NOVA_PATH="$SCRATCH/nova" CALLS="$SCRATCH/calls"
  mkdir -p "$HOME/.config/nova" "$NOVA_PATH/default" "$SCRATCH/bin"
  cp "$REPO_ROOT/data/defaults/shell.json" "$NOVA_PATH/default/shell.json"
  printf '#!/bin/bash\necho "nova-shell $*" >>"$CALLS"\n' >"$SCRATCH/bin/nova-shell"
  chmod +x "$SCRATCH/bin/nova-shell"
  : >"$CALLS"
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:$PATH"
}

teardown() { teardown_scratch; }

settings() { jq -c "$1" "$HOME/.config/nova/shell.json"; }

@test "off at first, then set hours, each said back, and the rest of the settings kept" {
  [ "$(nova-notification-schedule)" = "Off: Do Not Disturb comes on only by hand." ]
  [ "$(nova-notification-schedule hours)" = "From 22:00 to 07:00, every day." ]
  [ "$(settings .doNotDisturb)" = '{"schedule":"hours"}' ]
  grep -qx 'nova-shell -q shell reloadConfig' "$CALLS"
  [ "$(nova-notification-schedule 23:30 6:45)" = "From 23:30 to 06:45, every day." ]
  [ "$(settings .doNotDisturb)" = '{"from":"23:30","schedule":"hours","to":"06:45"}' ]
  [ "$(nova-notification-schedule off)" = "Off: Do Not Disturb comes on only by hand." ]
  [ "$(nova-notification-schedule hours)" = "From 23:30 to 06:45, every day." ]
  [ "$(settings .bar.position)" = '"top"' ]
}

@test "one end at a time, the other as kept, as Settings sends two picks in a row" {
  nova-notification-schedule from 21:00
  nova-notification-schedule to 06:00
  [ "$(settings .doNotDisturb)" = '{"from":"21:00","schedule":"hours","to":"06:00"}' ]
  [ "$(nova-notification-schedule)" = "From 21:00 to 06:00, every day." ]
}

@test "hours that are no times, or the same time twice, are refused and nothing is written" {
  nova-notification-schedule 22:00 07:00
  for wrong in "22:00 24:00" "22:00" "10pm 7am" "sunset" "off now" "22:00 07:00 08:00"; do
    # shellcheck disable=SC2086 # the words are the arguments
    run nova-notification-schedule $wrong
    [ "$status" -eq 1 ]
    [[ $output == *"usage: nova notification schedule"* ]]
  done
  run nova-notification-schedule 07:00 7:00
  [ "$status" -eq 1 ]
  [[ $output == *"start and end at different times"* ]]
  run nova-notification-schedule to 22:00
  [[ $output == *"start and end at different times"* ]]
  run nova-notification-schedule from
  [ "$status" -eq 1 ]
  [ "$(settings .doNotDisturb)" = '{"from":"22:00","schedule":"hours","to":"07:00"}' ]
}
