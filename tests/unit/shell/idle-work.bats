#!/usr/bin/env bats

# What the shell holds and does while nothing of it is open. A window plugin
# loads when it is summoned and goes when it is hidden (services/Panels.qml);
# one kept loaded from login, and a Timer that runs all the time, cost memory
# and wakeups for as long as the session lasts, so each is one of the few
# listed here with the reason it earns its place. A new one fails this test
# until it is added, with its reason.
#
# What the test cannot see: a Timer that runs through a binding (running:
# root.monitor) in a part that is always loaded; those are for review. A
# Settings page's Timers run only while the page is shown, as the window
# makes its page only while it is open.

load ../test_helper

shell=$REPO_ROOT/src/shell

# The window plugins loaded at login and never unloaded, and why: each opens
# at a key or a click with nothing to build, and holds little while shut
# (a few MB each, measured on the P1).
kept=(
  nova.airdrop     # the menu's AirDrop row reads whether it is on from the first
  nova.capture     # PRINT freezes the screens the moment it is pressed
  nova.clipboard   # SUPER + CTRL + V, at once
  nova.dictation   # SUPER + D starts listening as it is pressed
  nova.emojis      # SUPER + CTRL + E, at once
  nova.image-picker # lets its slices go after two minutes shut
  nova.menu        # SUPER + SPACE and the bar's menu, at once
  nova.osd         # the volume and brightness keys, at each press
  nova.preview     # Space in Files; lets the file go after two minutes shut
)

# The Timers that repeat and run all the time, a file each time one is in it,
# and why.
always=(
  Commons/Wake.qml                       # the wall clock every ten seconds, the one look for a sleep
  plugins/bar/widgets/SystemUpdate.qml   # asks for updates every six hours
  plugins/batterylife/Service.qml        # the battery's history: a sample a few minutes
  plugins/batterylife/Service.qml        # and its settings, read every ten minutes
  plugins/panels/weather/Forecast.qml    # the forecast on the bar, every quarter of an hour
  plugins/screentime/BarWidget.qml       # today's screen time on the bar, a minute
  plugins/screentime/Service.qml         # the day's record, written every minute
  plugins/screentime/Service.qml         # and its settings, read every ten minutes
  plugins/settings/BluetoothView.qml     # a Settings page, made only while it is shown
  plugins/settings/PowerReadout.qml      # a Settings page's
  plugins/settings/WifiLinkView.qml      # a Settings page's
  plugins/settings/WifiView.qml          # a Settings page's
)

@test "only the window plugins listed are kept loaded from login" {
  run bash -c "find '$shell/plugins' -name '*manifest.json' -print0 | xargs -0 jq -r \
    'select(.keepLoaded == true and (.kinds | any(. == \"panel\" or . == \"overlay\" or . == \"menu\"))) | .id' | LC_ALL=C sort"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") <(printf '%s\n' "${kept[@]}" | LC_ALL=C sort)
}

@test "only the Timers listed repeat and run all the time" {
  run bash -c "cd '$shell' && find . -name '*.qml' -print0 | LC_ALL=C sort -z |
    xargs -0 awk -f '$BATS_TEST_DIRNAME/always-running.awk' | sed 's#^\./##; s# [0-9]*\$##'"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") <(printf '%s\n' "${always[@]}" | LC_ALL=C sort)
}

@test "the check sees a Timer that runs all the time, on one line or many" {
  setup_scratch
  printf 'Item {\n  Timer {\n    interval: 1000\n    running: true\n    repeat: true\n    onTriggered: {\n      if (a) { b() }\n    }\n  }\n  Timer { interval: 5; repeat: true; running: true }\n  Timer { repeat: true; running: root.shown }\n  Timer { running: true }\n}\n' >"$SCRATCH/A.qml"
  run awk -f "$BATS_TEST_DIRNAME/always-running.awk" "$SCRATCH/A.qml"
  teardown_scratch
  [ "$output" = "$SCRATCH/A.qml 2"$'\n'"$SCRATCH/A.qml 10" ]
}
