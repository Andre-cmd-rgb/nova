// platform: wayland
// stub: home/battery/bin/batterylife record
// stub: bin/nova-power-profile nova-power-profile
import QtQuick
import Quickshell
import Quickshell.Io

// Battery Life's power profiles: the plugin's service, the real Service.qml,
// reads none while nothing holds it, then once for both copies of the real
// BarWidget.qml, as on two screens, which hold it; a profile chosen on either
// is set once, and read once after.
// The service runs its helper beside its own file, so the test copies both
// files into the scratch home, next to a stub that only notes its calls.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  property Item stage: Item {}
  property var service: null
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
      function serviceFor(id) { return id === "nova.batterylife" ? test.service : null }
    }
    function listButton(button, on) {}
    function claimPopup(key, open) { popup = open ? key : null }
    function inWindow(item, window) { return false }
    function nextPanel(owner, step) { return false }
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

  // The power profile calls, a line each.
  function calls() {
    callsFile.reload()
    return callsFile.text().split("\n").filter(line => line.startsWith("nova-power-profile"))
  }

  FileView {
    id: callsFile
    path: test.home + "/stub-calls"
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: installedService
    path: Quickshell.env("TEST_PLUGINS") + "/batterylife/Service.qml"
    blockLoading: true
  }

  FileView {
    id: installedWidget
    path: Quickshell.env("TEST_PLUGINS") + "/batterylife/BarWidget.qml"
    blockLoading: true
  }

  FileView {
    id: serviceCopy
    path: test.home + "/battery/Service.qml"
    printErrors: false
    onSaved: widgetCopy.setText(installedWidget.text())
  }

  FileView {
    id: widgetCopy
    path: test.home + "/battery/BarWidget.qml"
    printErrors: false
    onSaved: test.begin()
  }

  Component.onCompleted: serviceCopy.setText(installedService.text())

  function begin() {
    const madeService = Qt.createComponent("file://" + home + "/battery/Service.qml")
    if (madeService.status !== Component.Ready) {
      check("the service loads", madeService.errorString(), "")
      return finish()
    }
    service = madeService.createObject(stage)
    alone.start()
  }

  // Given time, a read with nothing holding the service would have come.
  Timer {
    id: alone
    interval: 500
    onTriggered: {
      test.check("held by none, no read", test.calls(), [])
      test.addCopies()
    }
  }

  function addCopies() {
    const made = Qt.createComponent("file://" + home + "/battery/BarWidget.qml")
    if (made.status !== Component.Ready) {
      check("the widget loads", made.errorString(), "")
      return finish()
    }
    copies = [made.createObject(stage, { bar: fakeBar }), made.createObject(stage, { bar: fakeBar })]
    when(() => copies.every(copy => copy.activeProfile === "balanced"), "both copies show the profiles", read)
  }

  function read() {
    settle.start()
  }

  // Given time, a second read would have come by now.
  Timer {
    id: settle
    interval: 500
    // A read of the calls can be a moment behind the file: it is asked
    // until it has the one call.
    onTriggered: test.when(() => test.calls().length > 0, "the read is noted", test.readOnce)
  }

  function readOnce() {
    check("read once for both", calls(), ["nova-power-profile list --active-state"])
    check("the profiles, on both", copies.map(copy => copy.profiles),
      [["power-saver", "balanced", "performance"], ["power-saver", "balanced", "performance"]])
    copies[1].setProfile("performance")
    when(() => calls().length === 3, "a profile chosen is set, and read after", chosen)
  }

  function chosen() {
    check("set once, and read once after", calls().slice(1), ["nova-power-profile set performance", "nova-power-profile list --active-state"])
    finish()
  }
}
