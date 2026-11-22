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

@test "fullscreen: a window over the whole screen in a theme's colour, or in none, is found" {
  file=$(sample Lock.qml <<'EOF'
import QtQuick
import Quickshell
import Quickshell.Wayland

Item {
  WlSessionLock {
    WlSessionLockSurface {
      color: Commons.Color.background
      Item {
        Rectangle { color: "red" }
      }
    }
  }

  PanelWindow {
    anchors { top: true; bottom: true; left: true; right: true }
    color: Commons.Color.background
  }

  component Cover: PanelWindow {
    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
  }

  PanelWindow {
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    color: "white"
  }
}
EOF
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': fullscreen: ' <<<"$output")" -eq 4 ]
  [[ $output == *"Lock.qml:7: fullscreen"* && $output == *"Lock.qml:15: fullscreen"* ]]
  [[ $output == *"Lock.qml:20: fullscreen: a window over the whole screen with no color"* && $output == *"Lock.qml:29: fullscreen"* ]]
}

@test "fullscreen: black or transparent passes, and a window along one edge may take the theme's colour" {
  file=$(sample Fine.qml <<'EOF'
import QtQuick
import Quickshell
import Quickshell.Wayland

Scope {
  WlSessionLock {
    WlSessionLockSurface {
      color: "black"
    }
  }

  PanelWindow {
    anchors { top: true; right: true; bottom: true; left: true }
    color: "transparent"
    Rectangle {
      anchors.fill: parent
      color: Commons.Color.background
    }
  }

  PanelWindow {
    anchors { top: true; left: true; right: true }
    color: Commons.Color.bar.background
  }
}
EOF
  )
  run "$LINT" "$file"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fullscreen: a window keeps its edges across one nested in it, and a comment hides nothing" {
  file=$(sample Nested.qml <<'EOF2'
import QtQuick
import Quickshell

Scope {
  PanelWindow {
    anchors.top: true
    anchors.bottom: true
    PanelWindow {
      anchors.top: true
      color: Commons.Color.bar.background
    }
    anchors.left: true
    anchors.right: true
    color: Commons.Color.background
  }

  PanelWindow { // the cover
    anchors { top: true; bottom: true; left: true; right: true }
    color: Commons.Color.background
  }

  PanelWindow {
    anchors { top: true; bottom: true; left: true; right: true } // all four
    color: "black" // drawn over at once
  }
}
EOF2
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': fullscreen: ' <<<"$output")" -eq 2 ]
  [[ $output == *"Nested.qml:5: fullscreen"* && $output == *"Nested.qml:17: fullscreen"* ]]
}

@test "fullscreen: a window sized to the screen, one by another name, and one indented its own way are found" {
  sized=$(sample Sized.qml <<'EOF2'
import QtQuick
import Quickshell

FloatingWindow {
    implicitWidth: screen.width
    implicitHeight: screen.height
}
EOF2
  )
  cover=$(sample Cover.qml <<'EOF2'
import Quickshell

PanelWindow {
  color: Commons.Color.background
}
EOF2
  )
  shade=$(sample Shade.qml <<'EOF2'
import Quickshell

PanelWindow {
  color: "transparent"
}
EOF2
  )
  uses=$(sample Uses.qml <<'EOF2'
import QtQuick

Item {
  Cover {
    anchors { top: true; bottom: true; left: true; right: true }
  }
  Shade {
    anchors { top: true; bottom: true; left: true; right: true }
  }
  Shade {
    anchors { top: true; bottom: true; left: true; right: true }
    color: Commons.Color.background
  }
  Cover {
    anchors.top: true
  }
}
EOF2
  )
  run "$LINT" "$sized" "$cover" "$shade" "$uses"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': fullscreen: ' <<<"$output")" -eq 3 ]
  [[ $output == *"Sized.qml:4: fullscreen: a window over the whole screen with no color"* ]]
  [[ $output == *"Uses.qml:4: fullscreen"* && $output == *"Uses.qml:10: fullscreen"* ]]
}

@test "pipefail: a reader that stops early under pipefail is found, wherever its status is looked at" {
  file=$(sample early.sh <<'EOF2'
#!/bin/bash
set -euo pipefail
ps -e | sort | head -n 25
if pacman -Qq | grep -q '^lib32-'; then lib32=1; fi
name=$(iw dev | awk '$1 == "Interface" { print $2; exit }')
first=$(find . -name '*.conf' |
  sed q)
! lsblk -nro TYPE | grep -Eqx 'crypt' || exit 1
found=$(journalctl -b | grep -m1 'oops')
printf '%s\n' "${list[@]}" | grep -qxF -- "$name" && echo there
echo "$(ps -e | head -n 1)"
EOF2
  )
  run "$LINT" "$file"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': pipefail: ' <<<"$output")" -eq 7 ]
  for line in 3 4 5 6 8 9 10; do [[ $output == *"early.sh:$line: pipefail"* ]]; done
}

@test "pipefail: readers that read to the end, a status nobody looks at, a reason, and no pipefail pass" {
  file=$(sample fine.sh <<'EOF2'
#!/bin/bash
set -euo pipefail
ps -e | sort | awk 'NR <= 25'
if pacman -Qq | grep '^lib32-' >/dev/null; then lib32=1; fi
name=$(iw dev | awk '$1 == "Interface" && !found++ { print $2 }')
battery=$(upower -e | grep -m1 BAT || true)
while read -r line; do echo "$line"; done < <(ps -e | head -n 10)
echo "$(ps -e | head -n 1)"
brightnessctl -m | awk -F, '{ print $4; read = 1 } END { exit !read }'
last=$(ps -e | head -n -1 | tail -n 1)
case $1 in
  show | read) echo read ;;
esac
# lint-patterns: pipefail one line of 64 bytes, written in one go
line=$(head -c 64 -- "$file" | head -n 1)
grep -q x <<<"$text"
EOF2
  )
  plain=$(sample plain.sh <<'EOF2'
#!/bin/bash
set -eu
ps -e | head -n 1
EOF2
  )
  run "$LINT" "$file" "$plain"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pipefail: a sourced file runs under the pipefail of what sources it; a reason needs words" {
  lib=$(sample lib.bash <<'EOF2'
# shellcheck shell=bash
keymap() { localectl list-keymaps | grep -qx -- "$1"; }
# lint-patterns: pipefail
first() { sed -n 's/^a=//p' "$1" | head -n 1; }
EOF2
  )
  run "$LINT" "$lib"
  [ "$status" -eq 1 ]
  [ "$(grep -c ': pipefail: ' <<<"$output")" -eq 2 ]
  [[ $output == *"lib.bash:2: pipefail"* && $output == *"lib.bash:4: pipefail"* ]]
}
