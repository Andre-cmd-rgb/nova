import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Ui
import qs.Commons
import "KeyboardLayoutModel.js" as Keyboards

// The keyboard's layout as a short code (EN, DE), shown only with more than
// one layout to go round; a click goes on to the next. The widget reads
// `hyprctl -j devices` when Hyprland says a layout changed or its config was
// reloaded, and every ten seconds while it is not sure which keyboard to
// speak for.
BarWidget {
  id: widget
  moduleName: "nova.keyboard-layout"

  // The active keymap as Hyprland describes it, "English (US)", and xkb's
  // codes by description.
  property string keymap: ""
  property var briefs: ({})
  readonly property string code: Keyboards.shortLabel(keymap, briefs)
  // Whether the keyboard read has more than one layout to go round.
  property bool severalLayouts: true

  // What the last reading settled on: the keyboard a click switches, and
  // how many there are, buttons and fcitx5's virtual one left out; or that
  // it could not tell. lastTyped is the keyboard the last activelayout
  // event named.
  property string device: ""
  property int devices: 0
  property bool inDoubt: false
  property string lastTyped: ""

  visible: code !== "" && severalLayouts
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A reading, now or, while one runs, after it: that one may have started
  // before a switch.
  function look() {
    reading.again = reading.running
    if (!reading.running) reading.running = true
  }

  // switchxkblayout is a hyprctl command, not a dispatcher. It moves the one
  // keyboard: the whole seat would move the buttons too, and a button left a
  // layout ahead of a keyboard gone round to the first would be read as the
  // one furthest along.
  function nextLayout() {
    if (!device || !bar) return
    bar.run("hyprctl switchxkblayout " + Util.shellQuote(device) + " next")
    settle.restart()
  }

  // Hyprland's "main" keyboard is often not one typed on (fcitx5 takes it,
  // then whatever device it saw last, a power button too), so the widget
  // takes the keyboard the last switch named, or the one furthest along its
  // layouts. Only a list speaks for the seat: a reading cut off when it
  // stalled parses as no keyboards at all.
  function take(text) {
    var listed
    try {
      listed = JSON.parse(text || "{}").keyboards
    } catch (e) {
      return
    }
    if (!Array.isArray(listed)) return

    var typed = listed.filter(function(device) { return Keyboards.isTypedKeyboard(device.name) })
    var chosen = Keyboards.selectKeyboard(typed, lastTyped)
    inDoubt = !chosen || !chosen.active_keymap
    if (inDoubt) {
      // The poll goes on. With no keyboard left, nothing shows or switches.
      if (typed.length > 0) return
      keymap = ""
      device = ""
      return
    }
    devices = typed.length
    device = String(chosen.name || "")
    severalLayouts = String(chosen.layout).indexOf(",") !== -1
    keymap = chosen.active_keymap
  }

  Connections {
    target: Hyprland

    // A reload can add a layout, which decides whether the widget shows, and
    // raises no activelayout.
    function onRawEvent(event) {
      var name = event && event.name ? String(event.name) : ""
      var named = name === "activelayout" ? Keyboards.eventKeyboardName(event) : ""
      if (named) widget.lastTyped = named
      if (name.indexOf("activelayout") !== -1 || name === "configreloaded") widget.look()
    }
  }

  Process {
    id: reading
    // Asked for again while it ran.
    property bool again: false
    command: ["hyprctl", "-j", "devices"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: widget.take(text)
    }
    onRunningChanged: {
      if (running) {
        stall.restart()
        return
      }
      stall.stop()
      if (again) widget.look()
    }
  }

  // A reading that never ends would hold the code where it is, as a running
  // Process does not start again: after 5 s it is stopped, and another
  // follows, as it may have been the only one coming.
  Timer {
    id: stall
    interval: 5000
    onTriggered: {
      reading.running = false
      settle.restart()
    }
  }

  // A reading once Hyprland has switched, after a click.
  Timer {
    id: settle
    interval: 600
    onTriggered: widget.look()
  }

  // A keyboard plugged in or out raises no event, so the widget looks every
  // 10 s until its first reading, while in doubt, and while there are two
  // keyboards or more. One keyboard, read, is left alone.
  Timer {
    interval: 10000
    repeat: true
    running: !widget.device || widget.inDoubt || widget.devices > 1
    onTriggered: widget.look()
  }

  // xkb's layout codes, read once: the table changes only with xkb.
  // --load-exotic for layouts such as trans (IPA), which come in the same
  // package.
  Process {
    id: xkbTable
    command: ["xkbcli", "list", "--load-exotic"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: widget.briefs = Keyboards.layoutBriefs(text)
    }
  }

  Component.onCompleted: {
    xkbTable.running = true
    look()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: widget.bar
    text: widget.code
    tooltipText: widget.keymap
    fontSize: Style.font.caption
    horizontalMargin: 6
    onPressed: widget.nextLayout()
  }
}
