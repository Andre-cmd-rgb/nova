import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Ui
import qs.Commons
import "KeyboardLayoutModel.js" as Keyboards

// The keyboard's layout as a short code (EN, DE), shown only where there is
// more than one to switch between; a click moves to the next. It reads
// `hyprctl -j devices` when Hyprland says a layout changed or its config was
// reloaded, and every ten seconds while which keyboard it speaks for is in
// doubt.
BarWidget {
  id: root
  moduleName: "nova.keyboard-layout"

  // The active keymap's description, "English (US)", and its code.
  property string keymap: ""
  property var briefs: ({})
  readonly property string code: Keyboards.shortLabel(keymap, briefs)
  // An older Hyprland that lists no layouts gets the code shown.
  property bool severalLayouts: true

  // The keyboard the last reading spoke for, which a click switches; the one
  // the last activelayout event named as typed on; how many keyboards there
  // are, buttons and fcitx5's virtual one left out; and whether the last
  // reading left in doubt which one to read.
  property string keyboard: ""
  property string typedOn: ""
  property int keyboardCount: 0
  property bool unsure: false

  // A reading asked for while one runs: that one may have begun before the
  // switch, so another follows it.
  property bool askAgain: false

  function refresh() {
    if (reading.running) {
      askAgain = true
      return
    }
    askAgain = false
    reading.running = true
  }

  // switchxkblayout is a hyprctl command, not a dispatcher. It moves the
  // keyboard the code describes, and only it: the whole seat would move the
  // buttons as well, and a button left ahead of a keyboard that went round to
  // the first layout would be read as the one furthest along.
  function nextLayout() {
    if (!keyboard || !bar) return
    bar.run("hyprctl switchxkblayout " + Util.shellQuote(keyboard) + " next")
    settle.restart()
  }

  // What `hyprctl -j devices` says. Hyprland's "main" keyboard is often not
  // one typed on (fcitx5 takes it, then whichever device Hyprland saw last,
  // a power button too), so the keyboard is the one the last switch named,
  // or the one furthest along its layouts.
  function read(text) {
    var listed
    try {
      listed = JSON.parse(text || "{}").keyboards
    } catch (e) {
      return
    }
    // Only a list speaks for the seat: a reading cut off when it stalled
    // parses as no keyboards at all.
    if (!Array.isArray(listed)) return

    var typed = listed.filter(function(device) { return Keyboards.isTypedKeyboard(device.name) })
    var chosen = Keyboards.selectKeyboard(typed, typedOn)
    if (!chosen || !chosen.active_keymap) {
      // No keyboard left, or none with a keymap: in doubt either way, so the
      // poll goes on. With none left, nothing is shown or switched.
      unsure = true
      if (typed.length === 0) {
        keymap = ""
        keyboard = ""
      }
      return
    }
    unsure = false
    keyboardCount = typed.length
    keyboard = String(chosen.name || "")
    severalLayouts = chosen.layout === undefined || String(chosen.layout).indexOf(",") !== -1
    keymap = chosen.active_keymap
  }

  Component.onCompleted: {
    xkbTable.running = true
    refresh()
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "activelayout") {
        var named = Keyboards.eventKeyboardName(event)
        if (named) root.typedOn = named
      }
      // A reload can add a layout, which decides whether the widget shows,
      // and it raises no activelayout.
      if (name.indexOf("activelayout") !== -1 || name === "configreloaded") root.refresh()
    }
  }

  Process {
    id: reading
    command: ["hyprctl", "-j", "devices"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.read(text)
    }
    onRunningChanged: {
      if (running) {
        stall.restart()
      } else {
        stall.stop()
        if (root.askAgain) root.refresh()
      }
    }
  }

  // A reading that never ends would hold the code as it is, since a running
  // Process does not start again. After five seconds it is stopped, and
  // another follows: it may have been the only one coming.
  Timer {
    id: stall
    interval: 5000
    onTriggered: {
      reading.running = false
      settle.restart()
    }
  }

  // After a click, a reading once Hyprland has switched.
  Timer {
    id: settle
    interval: 600
    onTriggered: root.refresh()
  }

  // A keyboard plugged in or out raises no event, so the poll: until the
  // first reading, while one is in doubt, and while there are two keyboards.
  // One keyboard, read, is left alone.
  Timer {
    interval: 10000
    running: !root.keyboard || root.unsure || root.keyboardCount > 1
    repeat: true
    onTriggered: root.refresh()
  }

  // Layout codes from xkb's own table, by description. The table changes only
  // with an xkb upgrade, so once. --load-exotic for layouts like trans (IPA),
  // which ship in the same package.
  Process {
    id: xkbTable
    command: ["xkbcli", "list", "--load-exotic"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.briefs = Keyboards.layoutBriefs(text)
    }
  }

  visible: code !== "" && severalLayouts
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.code
    fontSize: Style.font.caption
    horizontalMargin: 6
    tooltipText: root.keymap
    onPressed: root.nextLayout()
  }
}
