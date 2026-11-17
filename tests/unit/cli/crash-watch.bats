#!/usr/bin/env bats

# nova-crash-watch, with Hyprland's windows, the processes and the
# notifications stubbed, and the stream of events from a file: which crashes
# it says, in what words, with what Reopen runs, and which it leaves alone.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" HOME="$SCRATCH/home"
  export XDG_DATA_HOME="$SCRATCH/home/.local/share" XDG_DATA_DIRS="$SCRATCH/system"
  export NOVA_CRASH_EVENTS="$SCRATCH/events" NOVA_PROC="$SCRATCH/proc"
  mkdir -p "$SCRATCH/bin" "$XDG_DATA_HOME/applications" "$SCRATCH/system/applications" "$NOVA_PROC"
  : >"$NOVA_CRASH_EVENTS"
  # hyprctl answers from $SCRATCH/clients, or, from its second call on,
  # $SCRATCH/clients-later when there is one (a window opened since).
  stub hyprctl 'n=$(grep -c "^hyprctl" "$CALLS")
    if [[ $n -gt 1 && -f $SCRATCH/clients-later ]]; then cat "$SCRATCH/clients-later"; else cat "$SCRATCH/clients" 2>/dev/null || echo "[]"; fi'
  stub nova-notification-send
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

watch() { "$REPO_ROOT/src/cli/bin/nova-crash-watch"; }

windows() { # "address pid class"...: Hyprland's windows
  local entry address pid class
  local -a list=()
  for entry; do
    read -r address pid class <<<"$entry"
    list+=("$(jq -nc --arg a "0x$address" --argjson p "$pid" --arg c "$class" '{address: $a, pid: $p, class: $c, initialClass: $c}')")
  done
  printf '%s\n' "${list[@]}" | jq -sc . >"$SCRATCH/clients"
}

events() { printf '%s\n' "$@" >>"$NOVA_CRASH_EVENTS"; }

running() { # pid [state]: a process that runs (or is in that state)
  mkdir -p "$NOVA_PROC/$1"
  printf 'Name:\tapp\nUmask:\t0022\nState:\t%s\nTgid:\t%s\n' "${2:-S (sleeping)}" "$1" >"$NOVA_PROC/$1/status"
}

entry() { # id [lines...]: a desktop entry in the system's folder
  local id=$1
  shift
  printf '[Desktop Entry]\nType=Application\n%s\n' "$@" >"$SCRATCH/system/applications/$id.desktop"
}

said() { grep '^nova-notification-send' "$CALLS" 2>/dev/null || true; }

@test "an app whose window a crash took away is said, with Reopen opening it as the menu does" {
  entry org.example.Sketch 'Name=Sketch' 'Icon=org.example.Sketch' 'Name[de]=Skizze'
  windows 'abc 4242 org.example.Sketch'
  events 'hypr closewindow>>abc' 'core 4242'
  watch
  [ "$(said)" = 'nova-notification-send -u normal -g 󰀦 -i org.example.Sketch --button Reopen Sketch quit unexpectedly --exec uwsm-app -- org.example.Sketch.desktop' ]
}

@test "the crash may come before the window closes, and a window may close dumping its core or a zombie" {
  entry sketch 'Name=Sketch'
  windows 'abc 4242 sketch' 'def 5151 sketch'
  running 5151 'Z (zombie)'
  events 'core 4242' 'hypr closewindow>>abc'
  watch
  [ "$(said | wc -l)" -eq 1 ]
  : >"$CALLS"
  : >"$NOVA_CRASH_EVENTS"
  windows 'def 5151 other'
  entry other 'Name=Other'
  events 'hypr closewindow>>def' 'core 5151'
  watch
  [[ $(said) == *'Other quit unexpectedly'* ]]
  : >"$CALLS"
  : >"$NOVA_CRASH_EVENTS"
  printf 'Name:\tapp\nState:\tD (disk sleep)\nCoreDumping:\t1\n' >"$NOVA_PROC/5151/status"
  events 'hypr closewindow>>def' 'core 5151'
  watch
  [[ $(said) == *'Other quit unexpectedly'* ]]
}

@test "a crash that leaves the windows open, as a browser's tab does, is not said" {
  entry sketch 'Name=Sketch'
  windows 'abc 4242 sketch'
  running 4242
  events 'core 7777' 'core 4242'
  watch
  [ -z "$(said)" ]
}

@test "a crash after the window was closed, an app crashing on its way out, is not said" {
  entry sketch 'Name=Sketch'
  windows 'abc 4242 sketch'
  running 4242
  events 'hypr closewindow>>abc' 'core 4242'
  watch
  [ -z "$(said)" ]
}

@test "a window that closed with its process and no crash is a quit, and not said" {
  windows 'abc 4242 sketch'
  events 'hypr closewindow>>abc' 'core x' 'core '
  watch
  [ -z "$(said)" ]
}

@test "a process with several windows is said once, and an app crashing at each start once a minute" {
  entry sketch 'Name=Sketch'
  windows 'abc 4242 sketch' 'abd 4242 sketch' 'abe 4343 sketch'
  events 'hypr closewindow>>abc' 'hypr closewindow>>abd' 'core 4242' 'core 4242' 'hypr closewindow>>abe' 'core 4343'
  watch
  [ "$(said | wc -l)" -eq 1 ]
}

@test "a window opened after the start is known by its process" {
  entry sketch 'Name=Sketch'
  echo '[]' >"$SCRATCH/clients"
  windows 'abc 4242 sketch'
  mv "$SCRATCH/clients" "$SCRATCH/clients-later"
  echo '[]' >"$SCRATCH/clients"
  events 'hypr openwindow>>abc,1,sketch,A sketch' 'hypr closewindow>>abc' 'core 4242'
  watch
  [[ $(said) == *'Sketch quit unexpectedly'* ]]
}

@test "the entry is found by its name in any case, its StartupWMClass or the last part of its ID; the user's first" {
  entry com.bambulab.BambuStudio 'Name=Bambu Studio'
  entry google-chrome 'Name=Google Chrome' 'StartupWMClass=chrome-browser'
  entry kitty 'Name=kitty'
  entry hidden 'Name=Hidden' 'Hidden=true'
  printf '[Desktop Entry]\nName=My Kitty\n' >"$XDG_DATA_HOME/applications/Kitty.desktop"
  windows 'a1 11 BambuStudio' 'a2 12 chrome-browser' 'a3 13 KITTY' 'a4 14 hidden'
  events 'hypr closewindow>>a1' 'core 11' 'hypr closewindow>>a2' 'core 12' 'hypr closewindow>>a3' 'core 13' 'hypr closewindow>>a4' 'core 14'
  watch
  said | grep -q -- '-g 󰀦 --button Reopen Bambu Studio quit unexpectedly --exec uwsm-app -- com.bambulab.BambuStudio.desktop$'
  said | grep -q -- 'Google Chrome quit unexpectedly --exec uwsm-app -- google-chrome.desktop$'
  said | grep -q -- 'My Kitty quit unexpectedly --exec uwsm-app -- Kitty.desktop$'
  said | grep -qx -- 'nova-notification-send -u normal -g 󰀦 hidden quit unexpectedly'
}

@test "an ID uwsm will not take is opened through gtk-launch" {
  printf '[Desktop Entry]\nName=Odd\nStartupWMClass=odd\n' >"$SCRATCH/system/applications/Odd App.desktop"
  windows 'abc 4242 odd'
  events 'hypr closewindow>>abc' 'core 4242'
  watch
  [[ $(said) == *'Odd quit unexpectedly --exec uwsm-app -- gtk-launch Odd App.desktop' ]]
}

@test "with no shell to show it, the watcher goes on" {
  stub nova-notification-send 'exit 1'
  entry sketch 'Name=Sketch'
  windows 'abc 4242 sketch' 'abd 4343 other'
  entry other 'Name=Other'
  events 'hypr closewindow>>abc' 'core 4242' 'hypr closewindow>>abd' 'core 4343'
  run watch
  [ "$status" -eq 0 ]
  [ "$(said | wc -l)" -eq 2 ]
}

@test "outside a Hyprland session it says so and ends" {
  unset NOVA_CRASH_EVENTS
  run watch
  [ "$status" -eq 1 ]
  [[ $output == *'not running inside a Hyprland session'* ]]
}
