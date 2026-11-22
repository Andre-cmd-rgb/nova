#!/usr/bin/env bats

# nova-notification-send: what reaches the notification daemon, through a
# busctl stub that writes down its arguments one a line. The text can come
# from anywhere, so none of it may become an option, a hint or a command; and
# a command never travels in a hint, which any program may send, but in a
# file of its own in Nova's private runtime folder, which the hint names.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/busctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$CALLS"
[[ ! -e $CALLS.fail ]] || exit 1
echo 'u 42'
STUB
  chmod +x "$SCRATCH/bin/busctl"
  export PATH="$SCRATCH/bin:$PATH"
  FOLDER=$XDG_RUNTIME_DIR/nova/notifications
}

teardown() { teardown_scratch; }

send() { "$REPO_ROOT/src/cli/bin/nova-notification-send" "$@"; }

# The call's values after Notify's signature, one a line: the app's name, the
# id it replaces, the icon, the headline, the description, the actions, the
# hints' count and the hints, and the timeout. The commands file's random
# name is <name> here.
values() { sed '1,/^susssasa{sv}i$/d' "$CALLS" | sed -E 's/^[0-9a-f]{32}$/<name>/'; }

# A hint's value.
hint() { sed '1,/^susssasa{sv}i$/d' "$CALLS" | sed -n "/^$1\$/{n;n;p}"; }

# What the file the nova-command hint names says.
commands() { cat -- "$FOLDER/$(hint nova-command)"; }

@test "a headline alone: low urgency, no timeout, nothing replaced, and a file saying it is Nova's" {
  send 'Wi-Fi restarted'
  [ "$(values | paste -sd '|')" = 'nova-action|0||Wi-Fi restarted||0|2|urgency|y|0|nova-command|s|<name>|-1' ]
  [ "$(head -3 "$CALLS" | paste -sd ' ')" = '--user -- call' ]
  [ "$(commands)" = '{}' ]
}

@test "options go before or after the text, as --name value or --name=value" {
  send -u critical --glyph=󰐥 'Head' 'Body' --app-name nova-update -t 5000 --replace-id=7 --image /tmp/a.png -i dialog-warning --value 40
  [ "$(values | paste -sd '|')" = 'nova-update|7|dialog-warning|Head|Body|0|5|urgency|y|2|nova-glyph|s|󰐥|image-path|s|/tmp/a.png|value|i|40|nova-command|s|<name>|5000' ]
}

@test "text that looks like options stays text" {
  send 'Sale' '-50% off'
  [ "$(values | sed -n 5p)" = '-50% off' ]
  send '--hint=int:x:1' '-rf'
  [ "$(values | sed -n 4,5p | paste -sd '|')" = '--hint=int:x:1|-rf' ]
  send --exec 'Body'
  [ "$(values | sed -n 4,5p | paste -sd '|')" = '--exec|Body' ]
  [ "$(commands)" = '{}' ]
}

@test "after --, the two words that follow are the text, whatever they say" {
  send -u normal -- '--exec' '--app-name=x' --exec nova-x
  [ "$(values | sed -n '1p;4,5p' | paste -sd '|')" = 'nova-action|--exec|--app-name=x' ]
  [ "$(commands)" = '{"argv":["nova-x"]}' ]
  send -- 'Head' ''
  [ "$(values | sed -n 4,5p | paste -sd '|')" = 'Head|' ]
  for args in "-- Head" "-- Head Body extra" "-- Head Body -u low"; do
    # shellcheck disable=SC2086 # the words of each case
    run send $args
    [ "$status" -eq 1 ]
  done
}

@test "an option where the description would be is an option" {
  send 'Head' -u normal
  [ "$(values | sed -n 5p)" = '' ]
  [ "$(values | sed -n 10p)" = 1 ]
}

@test "--exec gives the words a click runs, each kept whole, in the file and in no hint" {
  send 'Head' --exec nova-launch-browser 'a b' $'two\nlines' --
  [ "$(commands)" = '{"argv":["nova-launch-browser","a b","two\nlines","--"]}' ]
  fails grep -qx 'nova-exec-argv\|nova-buttons' "$CALLS"
  fails grep -q 'nova-launch-browser' "$CALLS"
}

@test "the file is in a folder of the user's alone, under a name no one can guess, a new one each time" {
  send 'Head' --exec nova-x
  first=$(hint nova-command)
  [[ $first =~ ^[0-9a-f]{32}$ ]]
  [ "$(stat -c %a "$XDG_RUNTIME_DIR/nova")" = 700 ]
  [ "$(stat -c %a "$FOLDER")" = 700 ]
  [ "$(stat -c %a "$FOLDER/$first")" = 600 ]
  send 'Head' --exec nova-x
  [ "$(hint nova-command)" != "$first" ]
  [ "$(find "$FOLDER" -type f | wc -l)" -eq 2 ]
}

@test "--button puts the click's command on a button of its own, its words as given" {
  send --button 'Reopen "now"' 'Head' --exec nova-launch -- org.gnome.Nautilus.desktop
  [ "$(commands)" = '{"argv":["nova-launch","--","org.gnome.Nautilus.desktop"],"buttons":[{"says":"Reopen \"now\"","argv":["nova-launch","--","org.gnome.Nautilus.desktop"],"main":true}]}' ]
}

@test "--buttons gives each button a command of its own" {
  send -u critical --buttons '[{"says":"Decline","argv":["nova-airdrop","decline","7-1"]},{"says":"Accept","argv":["nova-airdrop","accept","7-1"],"main":true}]' -- 'Offer' 'a.jpg'
  [ "$(commands)" = '{"buttons":[{"says":"Decline","argv":["nova-airdrop","decline","7-1"],"main":false},{"says":"Accept","argv":["nova-airdrop","accept","7-1"],"main":true}]}' ]
}

@test "buttons that are not a list of up to three, each with words and a sound command, are refused" {
  for bad in '{}' '[]' '[{"says":"A","argv":["a"]},{"says":"B","argv":["b"]},{"says":"C","argv":["c"]},{"says":"D","argv":["d"]}]' \
    '[{"says":" ","argv":["a"]}]' '[{"says":"A","argv":["-rf"]}]' '[{"says":"A","argv":[]}]' '[{"says":"A","argv":["a",2]}]' \
    '[{"says":"A","argv":["a"],"main":"yes"}]' 'not json'; do
    run send --buttons "$bad" 'Head'
    [ "$status" -eq 1 ]
    [[ $output == *'--buttons takes'* ]]
  done
  run send --button A --buttons '[{"says":"A","argv":["a"]}]' 'Head' --exec a
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS" ]
  [ -z "$(ls -A "$FOLDER" 2>/dev/null)" ]
}

@test "a button with no command to run is refused" {
  run send --button Reopen 'Head'
  [ "$status" -eq 1 ]
  [[ $output == *'--button needs --exec'* ]]
  [ ! -s "$CALLS" ]
}

@test "a whole command line in one word, or none at all, is refused" {
  run send 'Head' --exec 'nova-menu toggle'
  [ "$status" -eq 1 ]
  [[ $output == *'--exec nova-menu toggle'* ]]
  run send 'Head' --exec
  [ "$status" -eq 1 ]
  run send 'Head' --exec ''
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS" ]
}

@test "-p prints the new notification's id" {
  run send -p 'Head'
  [ "$status" -eq 0 ]
  [ "$output" = 42 ]
}

@test "a call that fails leaves no file behind" {
  touch "$CALLS.fail"
  run send 'Head' --exec nova-x
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$FOLDER")" ]
}

@test "without a runtime folder: a notification goes as anyone's, and one with a command not at all" {
  unset XDG_RUNTIME_DIR
  send 'Head'
  [ "$(values | paste -sd '|')" = 'nova-action|0||Head||0|1|urgency|y|0|-1' ]
  rm -f "$CALLS"
  run send 'Head' --exec nova-x
  [ "$status" -eq 1 ]
  [ ! -e "$CALLS" ]
}

@test "wrong options are refused before anything is sent" {
  for args in "-u urgent Head" "-r x1 Head" "-t 1.5 Head" "--value 101 Head" "--value -1 Head" "Head -g" "Head Body extra" ""; do
    # shellcheck disable=SC2086 # the words of each case
    run send $args
    [ "$status" -eq 1 ]
    [ -n "$output" ]
  done
  [ ! -s "$CALLS" ]
}
