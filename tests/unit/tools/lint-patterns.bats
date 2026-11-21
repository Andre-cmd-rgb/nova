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

@test "locale: pacman run for the user to watch, and -Qqu's names, pass" {
  file=$(sample pacman.sh <<'EOF2'
#!/bin/bash
pacman -Syu
sudo pacman -Su --noconfirm
names=$(pacman -Qqu)
info=$(pacman -Si linux)
EOF2
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$output" = "$file:5: locale: pacman read in the user's language: run it with LC_ALL=C" ]
}

@test "exec: a bare exec 2>/dev/null says what it does, and passes" {
  file=$(sample quiet.sh <<'EOF2'
#!/bin/bash
exec 2>/dev/null
EOF2
  )
  run "$LINT" "$file"
  [ "$status" -eq 0 ]
}

@test "patsub: a quoted & is the character" {
  file=$(sample quoted.sh <<'EOF2'
#!/bin/bash
escaped=${font//&/"&amp;"}
escaped=${font//</'&lt;'}
EOF2
  )
  run "$LINT" "$file"
  [ "$status" -eq 0 ]
}

@test "grep: a statement ended by a pipe is read on to its end, || and all" {
  file=$(sample piped.sh <<'EOF2'
#!/bin/bash
last=$(journalctl -b -o cat -g 'Invalid transition' |
  tail -n 1) || true
last=$(journalctl -b -o cat -g 'Invalid transition' |
  tail -n 1)
EOF2
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [[ $output == "$file:4: grep"* ]]
  [ "$(wc -l <<<"$output")" -eq 1 ]
}

@test "shadow: a window root hides data, not state; required and default count" {
  window=$(sample Window.qml <<'EOF2'
import Quickshell
PanelWindow {
  property string state: "shown"
  required property var data
}
EOF2
  )
  run "$LINT" "$window"
  [ "$status" -eq 1 ]
  [ "$output" = "$window:4: shadow: a property named data on the root hides the root's own: name it for what it holds" ]
}

@test "locale: a QML command array over several lines is read whole" {
  file=$(sample Lines.qml <<'EOF2'
import Quickshell.Io
Process {
  command: [
    "pactl",
    "subscribe"
  ]
}
EOF2
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [[ $output == *"Lines.qml:3: locale"* ]]
}

@test "no files to check is an error, not a pass" {
  run env GIT_DIR=/nonexistent "$LINT"
  [ "$status" -eq 2 ]
  [[ $output == *"found no files to check"* ]]
}

@test "locale: pactl with its options first, pacman -Qk, and CUPS in a QML array are found" {
  file=$(sample options.sh <<'EOF2'
#!/bin/bash
sinks=$(timeout 2 pactl -f json list sinks | jq '.[]')
checked=$(pacman -Qk nova 2>&1 || true)
EOF2
  )
  qml=$(sample Cups.qml <<'EOF2'
import Quickshell.Io
Process { command: ["lpstat", "-v"] }
EOF2
  )
  run "$LINT" "$file" "$qml"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': locale: ' <<<"$output")" -eq 3 ]
}

@test "grep: a || before journalctl does not count for it" {
  file=$(sample before.sh <<'EOF2'
#!/bin/bash
[[ -n $x ]] || last=$(journalctl -b -o cat -g 'Invalid transition' | tail -n 1)
EOF2
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [[ $output == "$file:2: grep"* ]]
}

@test "locale: each command of a joined statement is checked on its own" {
  file=$(sample commands.sh <<'EOF2'
#!/bin/bash
command -v pacman >/dev/null &&
  info=$(pacman -Qi foo)
pacman -Syu && pacman -Qi foo | grep -q x
LC_ALL=C pacman -Qu >"$t" ||
  pactl list sinks | grep -c Sink
EOF2
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': locale: ' <<<"$output")" -eq 3 ]
  [[ $output == *"commands.sh:2: locale"* && $output == *"commands.sh:4: locale"* && $output == *"commands.sh:5: locale"* ]]
}

@test "a heredoc is text, and a statement still open at the end of a file is checked" {
  file=$(sample text.sh <<'SAMPLE'
#!/bin/bash
cat <<EOF
pactl list sinks
EOF
cat <<-'END' |
	lpstat -d
	END
  wc -l
pactl list sinks |
SAMPLE
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$output" = "$file:9: locale: pactl read in the user's language: run it with LC_ALL=C.UTF-8" ]
}

@test "QML: a bracket in a string opens no array, and pactl's options before its command count" {
  file=$(sample Strings.qml <<'SAMPLE'
import Quickshell.Io
Item {
  Process { command: ["sh", "-c", "tr -d ["] }
  Process { command: ["lpstat", "-v"] }
  Process { command: ["pactl", "-f", "json", "list", "sinks"] }
}
SAMPLE
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': locale: ' <<<"$output")" -eq 2 ]
  [[ $output == *"Strings.qml:4: locale"* && $output == *"Strings.qml:5: locale"* ]]
}
