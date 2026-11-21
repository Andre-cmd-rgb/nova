#!/usr/bin/env bats

# A file the shell follows as it changes is a WatchedFile (Commons), not a
# FileView that reads again at each change (onFileChanged: reload()): with
# Quickshell 0.3.2 that reload does nothing while a read is under way, and a
# change that lands then is not read until the next one, which left the
# screen on a stale state (an app's inhibitor gone, a job done) until the
# next change, or a clock (the idle service's minute) put it right. A
# WatchedFile reads once more after a load that followed a change
# (tests/qml/watched-file-test.qml).
#
# The FileViews listed here are the shell's own writers: each change of
# theirs is one the shell made, and read twice it would cost a second parse
# of the whole file at each write. Another one fails this test until it is
# a WatchedFile, or listed here with its reason.

load ../test_helper

shell=$REPO_ROOT/src/shell

writers=(
  plugins/calendar/Store.qml     # the calendar's own file, written as events are made and moved
  plugins/clipboard/History.qml  # the clipboard's history, written at each copy
  services/ShellJson.qml         # ~/.config/nova/shell.json, written by the shell's verbs
)

@test "a file followed as it changes is a WatchedFile, but for the shell's own writers listed" {
  run bash -c "cd '$shell' && grep -rlE 'onFileChanged:[[:space:]]*(\{[[:space:]]*)?reload\(\)' --include='*.qml' . |
    grep -vx './Commons/WatchedFile.qml' | sed 's#^\./##' | LC_ALL=C sort"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") <(printf '%s\n' "${writers[@]}" | LC_ALL=C sort)
}

@test "the check sees a reload at a change, however it is written" {
  setup_scratch
  mkdir -p "$SCRATCH/shell/Commons"
  printf 'FileView {\n  onFileChanged: reload()\n}\n' >"$SCRATCH/shell/A.qml"
  printf 'FileView {\n  onFileChanged: { reload() }\n}\n' >"$SCRATCH/shell/B.qml"
  printf 'WatchedFile {\n  onLoaded: read(text())\n}\n' >"$SCRATCH/shell/C.qml"
  printf 'FileView {\n  onFileChanged: plugged.restart()\n}\n' >"$SCRATCH/shell/D.qml"
  printf 'FileView {\n  onFileChanged: reload()\n}\n' >"$SCRATCH/shell/Commons/WatchedFile.qml"
  run bash -c "cd '$SCRATCH/shell' && grep -rlE 'onFileChanged:[[:space:]]*(\{[[:space:]]*)?reload\(\)' --include='*.qml' . |
    grep -vx './Commons/WatchedFile.qml' | sed 's#^\./##' | LC_ALL=C sort"
  teardown_scratch
  [ "$output" = "A.qml"$'\n'"B.qml" ]
}
