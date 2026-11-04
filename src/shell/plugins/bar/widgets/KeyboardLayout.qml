import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Ui
import qs.Commons
import "KeyboardLayoutModel.js" as Keyboards

// The keyboard's layout as a short code (EN, DE), shown while it has more
// than one layout to go round; a click moves it on to the next. The widget
// reads the seat, `hyprctl -j devices`, when Hyprland says a layout changed
// or its config was reloaded, after its own click, and every ten seconds
// while it cannot be sure which keyboard to speak for.
BarWidget {
  id: widget
  moduleName: "nova.keyboard-layout"

  // xkb's codes by layout description, read once: they change only with
  // xkb.
  property var codes: ({})
  // The keyboard spoken for: its name, its keymap as Hyprland describes it
  // ("English (US)"), and whether it has another layout to go to.
  property string device: ""
  property string keymap: ""
  property bool several: true
  // How many keyboards are typed on; whether the last reading left the
  // widget unsure which to speak for; the keyboard the last switch named.
  property int keyboards: 0
  property bool unsure: false
  property string lastNamed: ""

  readonly property string code: Keyboards.label(keymap, codes)

  visible: code !== "" && several
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A reading of the seat. With no keyboard typed on left, nothing shows
  // or switches; one with no keymap yet leaves the widget as it was, and
  // the readings go on.
  function take(answer) {
    const found = Keyboards.seat(answer, lastNamed)
    if (!found) return
    unsure = found.keyboard === null
    if (found.keyboard) {
      keyboards = found.count
      device = String(found.keyboard.name || "")
      several = String(found.keyboard.layout).indexOf(",") !== -1
      keymap = found.keyboard.active_keymap
    } else if (found.count === 0) {
      keymap = ""
      device = ""
    }
  }

  // switchxkblayout is a hyprctl command, not a dispatcher. It moves the
  // one keyboard: the whole seat would move the buttons too, and a button
  // left a layout ahead of a keyboard gone round to the first would read
  // as the one furthest along.
  function next() {
    if (!device || !bar) return
    bar.run("hyprctl switchxkblayout " + Util.shellQuote(device) + " next")
    switched.restart()
  }

  Connections {
    target: Hyprland

    // A reload can add a layout, which decides whether the widget shows,
    // and raises no activelayout.
    function onRawEvent(event) {
      const name = String(event.name)
      if (name === "activelayout") widget.lastNamed = Keyboards.named(event) || widget.lastNamed
      if (name.indexOf("activelayout") !== -1 || name === "configreloaded") seat.ask()
    }
  }

  // The seat, read now, or while a reading runs, once more after it: that
  // one may have started before the change asked about.
  Process {
    id: seat

    property bool owed: false

    function ask() {
      owed = running
      running = true
    }

    command: ["hyprctl", "-j", "devices"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: widget.take(text)
    }
    onRunningChanged: {
      if (running) {
        hung.restart()
      } else {
        hung.stop()
        if (owed) ask()
      }
    }
  }

  // A reading that never ends would hold the code where it is, as a
  // running Process does not start again: after 5 s it is stopped, and
  // another follows, as it may have been the only one coming.
  Timer {
    id: hung
    interval: 5000
    onTriggered: {
      seat.running = false
      switched.restart()
    }
  }

  // Hyprland has switched by 600 ms after a click.
  Timer {
    id: switched
    interval: 600
    onTriggered: seat.ask()
  }

  // A keyboard plugged in or out raises no event, so the widget looks every
  // 10 s until its first reading, while unsure, and while two keyboards or
  // more are typed on. One keyboard, read, is left alone.
  Timer {
    interval: 10000
    repeat: true
    running: !widget.device || widget.unsure || widget.keyboards > 1
    onTriggered: seat.ask()
  }

  // --load-exotic for layouts such as trans (IPA), which come in the same
  // package.
  Process {
    id: xkb
    command: ["xkbcli", "list", "--load-exotic"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: widget.codes = Keyboards.codes(text)
    }
  }

  Component.onCompleted: {
    xkb.running = true
    seat.ask()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: widget.bar
    text: widget.code
    tooltipText: widget.keymap
    fontSize: Style.font.caption
    horizontalMargin: 6
    onPressed: widget.next()
  }
}
