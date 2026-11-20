#!/usr/bin/env bats

# What the shell holds and does while nothing of it is open. A window plugin
# loads when it is summoned and goes when it is hidden (services/Panels.qml);
# one kept loaded from login, a window that a service, the bar or a bar
# widget makes, and a Timer that runs all the time, cost memory and wakeups
# for as long as the session lasts, so each is one of the few listed here
# with the reason it earns its place. A new one fails this test until it is
# added, with its reason.
#
# What the test cannot see, and is for review: a Timer that runs through a
# binding (running: root.monitor), or that something other than its part's
# Component.onCompleted starts (a click, a reply) and nothing stops; a
# window made from a file's address (a Loader's source); and whether a
# window listed is made at login or only once it is wanted (inside a Loader,
# a LazyLoader or a Component). A Settings page's Timers run only while the
# page is shown, as the window makes its page only while it is open.

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

# The windows made by the parts loaded all the time (shell.qml, the
# services, the bar and its widgets), a file each, and why. A window plugin
# kept loaded is in the list above instead.
windows=(
  plugins/airdrop/AirDrop.qml          # the send window, made hidden: a file sent with AirDrop opens it at once
  plugins/background/Background.qml    # the background, on screen all the time
  plugins/bar/ScreenBar.qml            # the bar, on screen all the time
  plugins/bar/widgets/Tray.qml         # a bar panel (the tray's menus)
  plugins/batterylife/BarWidget.qml    # a bar panel: made with the bar, hidden, so that a click opens it at once
  plugins/lock/Service.qml             # the lock, whose surfaces come only when locked, and its preview, whose picture loads only while shown
  plugins/mobile-data/BarWidget.qml    # a bar panel
  plugins/notifications/Service.qml    # a toast window for each screen, shown only while a toast is
  plugins/panels/audio/Panel.qml       # a bar panel
  plugins/panels/bluetooth/Panel.qml   # a bar panel
  plugins/panels/clock/BarWidget.qml   # a bar panel
  plugins/panels/monitor/Panel.qml     # a bar panel
  plugins/panels/network/Panel.qml     # a bar panel
  plugins/panels/power/Panel.qml       # a bar panel
  plugins/panels/weather/BarWidget.qml # a bar panel
  plugins/polkit/PolkitAgent.qml       # the password card, made hidden: an app asking for rights opens it at once
  plugins/services/media/BarWidget.qml # a bar panel
)

# The Timers that start with their part and go on by themselves, a file
# each time one is in it, and why.
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

@test "only the windows listed are made by the parts loaded all the time" {
  local roots=shell.qml manifest entry
  while IFS= read -r -d '' manifest; do
    while IFS= read -r entry; do roots="$roots ${manifest%/*}/$entry"; done \
      < <(jq -r '.entryPoints | (.service, .bar, .barWidget) | select(. != null)' "$shell/$manifest")
  done < <(cd "$shell" && find plugins -name '*manifest.json' -print0)
  run bash -c "cd '$shell' && find . -name '*.qml' -print0 |
    xargs -0 awk -v roots='$roots' -f '$BATS_TEST_DIRNAME/windows-reached.awk' | LC_ALL=C sort"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") <(printf '%s\n' "${windows[@]}" | LC_ALL=C sort)
}

@test "the window check follows the types a file is made of, as QML finds them" {
  setup_scratch
  mkdir -p "$SCRATCH/shell/parts" "$SCRATCH/shell/Ui"
  cd "$SCRATCH/shell"
  # Svc makes a window by the type of a folder it imports with an alias,
  # and Inner one of its own, through Holder. Lazy is made from its address,
  # which the check cannot see, and Unused by nothing.
  printf 'import "parts" as P\nItem {\n  P.Card {}\n  Holder {}\n  Loader { source: "Lazy.qml" }\n}\n' >Svc.qml
  printf 'PanelWindow {\n}\n' >parts/Card.qml
  printf 'Item {\n  Inner {}\n}\n' >Holder.qml
  printf 'Item {\n  FloatingWindow {}\n}\n' >Inner.qml
  printf 'PanelWindow {}\n' >Lazy.qml
  printf 'Item {\n  PanelWindow {}\n}\n' >Unused.qml
  # Ui's Surface is a window, with one inside that counts where it is used;
  # this folder's is not. A file that imports qs.Ui has Ui's (Shown, and
  # Bare, which is one); one that does not has its folder's (Plain).
  printf 'PanelWindow {\n  PopupWindow {}\n}\n' >Ui/Surface.qml
  printf 'Item {}\n' >Surface.qml
  printf 'import qs.Ui\nItem {\n  Surface {}\n}\n' >Shown.qml
  printf 'import qs.Ui\nSurface {\n}\n' >Bare.qml
  printf 'Item {\n  Surface {}\n  Text { text: "PanelWindow {}" }\n}\n' >Plain.qml
  printf '// PanelWindow {}\nItem {\n}\n' >Commented.qml
  run bash -c "find . -name '*.qml' -print0 |
    xargs -0 awk -v roots='Svc.qml Shown.qml Bare.qml Plain.qml Commented.qml' -f '$BATS_TEST_DIRNAME/windows-reached.awk' | LC_ALL=C sort"
  cd "$BATS_TEST_DIRNAME"
  teardown_scratch
  [ "$output" = "Bare.qml"$'\n'"Inner.qml"$'\n'"Shown.qml"$'\n'"Svc.qml" ]
}

@test "only the Timers listed start with their part and go on by themselves" {
  run bash -c "cd '$shell' && find . -name '*.qml' -print0 | LC_ALL=C sort -z |
    xargs -0 awk -f '$BATS_TEST_DIRNAME/always-running.awk' | sed 's#^\./##; s# [0-9]*\$##'"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") <(printf '%s\n' "${always[@]}" | LC_ALL=C sort)
}

@test "the Timer check sees one that runs all the time, however it is started" {
  setup_scratch
  # Counted: 2 and 10 (repeat and running), 13 and 14 (repeat, started by
  # id or by its property's name as the part is made), 16 (a one-shot that
  # starts itself again), 17 (one started as the part is made that starts
  # itself again by id). Not: 11 (a binding), 12 (one shot), 15 (one shot,
  # started as the part is made), 22 (started by a click; the string does
  # not start it).
  cat >"$SCRATCH/A.qml" <<'EOF'
Item {
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      if (a) { b() }
    }
  }
  Timer { interval: 5; repeat: true; running: true }
  Timer { repeat: true; running: root.shown }
  Timer { running: true }
  Timer { id: poll; interval: 5; repeat: true }
  property Timer every: Timer { interval: 5; repeat: true }
  Timer { id: once; interval: 5 }
  Timer { id: tick; running: true; onTriggered: restart() }
  Timer {
    id: retry
    interval: 5
    onTriggered: if (failed) retry.start()
  }
  Timer { id: later; repeat: true }
  Component.onCompleted: { poll.start(); once.start()
    every.running = true
    retry.restart(); console.log("later.start()") }
  MouseArea { onClicked: later.start() }
}
EOF
  # Each file's ids are its own: poll is started in B, not in C.
  printf 'Item {\n  Timer { id: poll; repeat: true }\n  Component.onCompleted: poll.start()\n}\n' >"$SCRATCH/B.qml"
  printf 'Item {\n  Timer { id: poll; repeat: true }\n}\n' >"$SCRATCH/C.qml"
  run awk -f "$BATS_TEST_DIRNAME/always-running.awk" "$SCRATCH/A.qml" "$SCRATCH/B.qml" "$SCRATCH/C.qml"
  local want
  want=$(for line in 2 10 13 14 16 17; do echo "$SCRATCH/A.qml $line"; done; echo "$SCRATCH/B.qml 2")
  teardown_scratch
  [ "$output" = "$want" ]
}
