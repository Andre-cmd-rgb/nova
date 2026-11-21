#!/usr/bin/env bats

# tools/lint-patterns: each kind of bug it knows is found in a sample that has
# it, and the right way to write the same thing is not, so that the lint can
# run on the whole tree without exceptions.

load ../test_helper

setup() {
  setup_scratch
  LINT=$REPO_ROOT/tools/lint-patterns
}

teardown() { teardown_scratch; }

sample() { # name, then the file's text on stdin
  cat >"$SCRATCH/$1"
  printf '%s\n' "$SCRATCH/$1"
}

@test "locale: translated output read without LC_ALL=C is found, wherever it is read" {
  file=$(sample bad.sh <<'EOF'
#!/bin/bash
mute=$(pactl get-sink-mute @DEFAULT_SINK@)
pactl list sinks | awk '/^Sink #/'
lpstat -d | sed -n 's/^system default destination: //p'
behind=$(pacman -Qu | grep -v '\[ignored\]$')
info=$(pactl \
  subscribe)
EOF
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': locale: ' <<<"$output")" -eq 5 ]
  [[ $output == *"bad.sh:6: locale"* ]]
}

@test "locale: untranslated forms, output thrown away, and LC_ALL=C pass" {
  file=$(sample good.sh <<'EOF'
#!/bin/bash
# pactl list sinks, in a comment
mute=$(LC_ALL=C.UTF-8 pactl get-sink-mute @DEFAULT_SINK@)
pactl list sinks short | cut -f2
pactl get-default-sink
pacman -Si -- "$target" >/dev/null 2>&1 || exit 1
pacman -Qq | grep -x nova
LC_ALL=C pacman -Qu
pactl set-sink-mute @DEFAULT_SINK@ toggle
EOF
  )
  run "$LINT" "$file"
  [ "$status" -eq 0 ]
}

@test "locale: a QML command array reading pactl is found without env LC_ALL=C" {
  bad=$(sample Bad.qml <<'EOF'
import Quickshell.Io
Process { command: ["pactl", "subscribe"] }
EOF
  )
  good=$(sample Good.qml <<'EOF'
import Quickshell.Io
Process { command: ["env", "LC_ALL=C.UTF-8", "pactl", "subscribe"] }
EOF
  )
  run "$LINT" "$bad"
  [ "$status" -eq 1 ]
  [[ $output == *"Bad.qml:2: locale"* ]]
  run "$LINT" "$good"
  [ "$status" -eq 0 ]
}

@test "exec: a redirection exec would keep for the script is found; braced, or inside <( ), it is not" {
  file=$(sample exec.sh <<'EOF'
#!/bin/bash
exec {lock}>"$dir/.lock" 2>/dev/null || exit 0
exec 3>"$dir/log" 2>/dev/null
{ exec {lock}>"$dir/.lock"; } 2>/dev/null || exit 0
exec {events}< <(exec socat -U - "UNIX-CONNECT:$socket" 2>/dev/null)
exec {fd}>&-
EOF
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': exec: ' <<<"$output")" -eq 2 ]
  [[ $output == *"exec.sh:2: exec"* && $output == *"exec.sh:3: exec"* ]]
}

@test "grep: journalctl -g with nothing to catch its exit 1 is found" {
  file=$(sample grep.sh <<'EOF'
#!/bin/bash
last=$(journalctl -b -u ModemManager.service -o cat \
  -g 'Invalid transition' | tail -n 1)
last=$(journalctl -b -o cat \
  -g 'Invalid transition' | tail -n 1) || true
if journalctl -b --grep='x' -q; then :; fi
nova-notification-send -g glyph "title"
EOF
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$output" = "$file:2: grep: journalctl -g exits 1 when nothing matches: add || true, or test it" ]
}

@test "patsub: a bare & in a replacement is found; an escaped one is not" {
  file=$(sample patsub.sh <<'EOF'
#!/bin/bash
escaped=${font//</&lt;}
escaped=${font//&/\&amp;}
escaped=${escaped//</\&lt;}
flags=${flags//,/ }
EOF
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$output" = "$file:2: patsub: a bare & in a replacement is the text matched (bash 5.2): write \\&" ]
}

@test "shadow: state or data on an Item root is found; on a QtObject root, or deeper in, it is not" {
  bad=$(sample View.qml <<'EOF'
import QtQuick
Column {
  property string state: "idle"
  readonly property var data: []
  Item {
    property string state: "nested"
  }
}
EOF
  )
  good=$(sample Run.qml <<'EOF'
import QtQuick
QtObject {
  readonly property string state: "running"
}
EOF
  )
  run "$LINT" "$bad"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': shadow: ' <<<"$output")" -eq 2 ]
  [[ $output == *"View.qml:3: shadow"* && $output == *"View.qml:4: shadow"* ]]
  run "$LINT" "$good"
  [ "$status" -eq 0 ]
}
