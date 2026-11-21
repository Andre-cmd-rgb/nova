// stub: bin/hyprctl hyprctl
// stub: bin/xkbcli xkbcli
// warns: HYPRLAND_INSTANCE_SIGNATURE
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/bar/widgets" as Widgets

// The keyboard layout widget, the real KeyboardLayout.qml on a fake bar, and
// its plugin's service, the real KeyboardLayoutSeat.qml, with hyprctl and
// xkbcli stubs. The service reads nothing while no copy holds it; two copies,
// as on two screens, have it read the seat and xkb's codes once, and both
// show the code; a click on either switches the one keyboard once; with the
// copies gone it rests.
ShellRoot {
  id: test

  property Item stage: Item {}
  property Widgets.KeyboardLayoutSeat service: Widgets.KeyboardLayoutSeat {}
  property var copies: []

  property QtObject fakeBar: QtObject {
    readonly property int thickness: 30
    readonly property string fontFamily: "monospace"
    readonly property color foreground: "white"
    readonly property color background: "black"
    readonly property color textColour: "white"
    readonly property color urgent: "red"
    readonly property bool textFades: false
    readonly property bool peek: false
    property var popup: null
    property QtObject tip: QtObject {
      function ask(button, text) {}
      function withdraw(button) {}
    }
    property QtObject shell: QtObject {
      function serviceFor(id) { return id === "nova.keyboard-layout" ? test.service : null }
    }
    function listButton(button, on) {}
    function claimPopup(key, open) { popup = open ? key : null }
    function run(command) {}
  }

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // <then> once <ready> holds, looked at every 50 ms; <what> fails after 5 s.
  function when(ready, what, then) {
    waiter.ready = ready
    waiter.what = what
    waiter.then = then
    waiter.left = 100
    waiter.restart()
  }

  Timer {
    id: waiter
    property var ready: null
    property var then: null
    property string what: ""
    property int left: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (ready()) {
        stop()
        then()
      } else if (--left <= 0) {
        stop()
        test.check(what, false, true)
        test.finish()
      }
    }
  }

  readonly property string home: Quickshell.env("HOME")

  // The calls the stubs saw, a line each, but Style's reads of Hyprland's
  // look (getoption), which are the shell's, not the widget's.
  function calls() {
    callsFile.reload()
    return callsFile.text().split("\n").filter(line => line !== "" && line.indexOf(" getoption ") < 0)
  }

  FileView {
    id: callsFile
    path: test.home + "/stub-calls"
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: devices
    path: test.home + "/devices.json"
    printErrors: false
    onSaved: rest.start()
  }

  Component {
    id: layout
    Widgets.KeyboardLayout {}
  }

  Component.onCompleted: devices.setText(JSON.stringify({ keyboards: [
    { name: "at-translated-set-2-keyboard", layout: "us,de", active_layout_index: 1, active_keymap: "German" }
  ] }))

  // Given time, an unheld service would have read the seat by now.
  Timer {
    id: rest
    interval: 500
    onTriggered: {
      test.check("unheld, the service reads nothing", [test.service.wanted, test.calls()], [false, []])
      test.copies = [layout.createObject(test.stage, { bar: test.fakeBar }), layout.createObject(test.stage, { bar: test.fakeBar })]
      test.when(() => test.copies.every(copy => copy.code === "DE") && test.calls().length === 2,
        "held, both copies show the code", test.held)
    }
  }

  function held() {
    check("two copies hold the one service", service.holders.length, 2)
    check("which read the seat and xkb once", calls().slice().sort(), ["hyprctl -j devices", "xkbcli list --load-exotic"])
    check("both copies show, with the keymap as their tip", copies.map(copy => [copy.visible, copy.keymap]),
      [[true, "German"], [true, "German"]])
    copies[1].next()
    when(() => calls().length === 4, "a click switches the keyboard, and the seat is read again", clicked)
  }

  function clicked() {
    check("the one keyboard moved on, once", calls().slice(2).sort(),
      ["hyprctl -j devices", "hyprctl switchxkblayout at-translated-set-2-keyboard next"])
    for (const copy of copies) copy.destroy()
    copies = []
    gone.start()
  }

  Timer {
    id: gone
    interval: 200
    onTriggered: {
      test.check("with the copies gone, the service rests", [test.service.holders.length, test.service.wanted], [0, false])
      test.finish()
    }
  }
}
