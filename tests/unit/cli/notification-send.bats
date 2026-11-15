#!/usr/bin/env bats

# nova-notification-send: what reaches the notification daemon, through a
# busctl stub that writes down its arguments one a line. The text can come
# from anywhere, so none of it may become an option, a hint or a command.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/busctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$CALLS"
echo 'u 42'
STUB
  chmod +x "$SCRATCH/bin/busctl"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

send() { "$REPO_ROOT/src/cli/bin/nova-notification-send" "$@"; }

# The call's values after Notify's signature, one a line: the app's name, the
# id it replaces, the icon, the headline, the description, the actions, the
# hints' count and the hints, and the timeout.
values() { sed '1,/^susssasa{sv}i$/d' "$CALLS"; }

@test "a headline alone: low urgency, no timeout, nothing replaced" {
  send 'Wi-Fi restarted'
  [ "$(values | paste -sd '|')" = 'nova-action|0||Wi-Fi restarted||0|1|urgency|y|0|-1' ]
  [ "$(head -3 "$CALLS" | paste -sd ' ')" = '--user -- call' ]
}

@test "options go before or after the text, as --name value or --name=value" {
  send -u critical --glyph=󰐥 'Head' 'Body' --app-name nova-update -t 5000 --replace-id=7 --image /tmp/a.png -i dialog-warning
  [ "$(values | paste -sd '|')" = 'nova-update|7|dialog-warning|Head|Body|0|3|urgency|y|2|nova-glyph|s|󰐥|image-path|s|/tmp/a.png|5000' ]
}

@test "text that looks like options stays text" {
  send 'Sale' '-50% off'
  [ "$(values | sed -n 5p)" = '-50% off' ]
  send '--hint=int:x:1' '-rf'
  [ "$(values | sed -n 4,5p | paste -sd '|')" = '--hint=int:x:1|-rf' ]
  send --exec 'Body'
  [ "$(values | sed -n 4,5p | paste -sd '|')" = '--exec|Body' ]
  [ "$(values | sed -n 7p)" = 1 ]
}

@test "an option where the description would be is an option" {
  send 'Head' -u normal
  [ "$(values | sed -n 5p)" = '' ]
  [ "$(values | sed -n 10p)" = 1 ]
}

@test "--exec gives the words a click runs, each kept whole" {
  send 'Head' --exec nova-launch-browser 'a b' $'two\nlines' --
  hint=$(values | sed -n '/^nova-exec-argv$/{n;n;p}')
  [ "$hint" = '["nova-launch-browser","a b","two\nlines","--"]' ]
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

@test "wrong options are refused before anything is sent" {
  for args in "-u urgent Head" "-r x1 Head" "-t 1.5 Head" "Head -g" "Head Body extra" ""; do
    # shellcheck disable=SC2086 # the words of each case
    run send $args
    [ "$status" -eq 1 ]
    [ -n "$output" ]
  done
  [ ! -s "$CALLS" ]
}
