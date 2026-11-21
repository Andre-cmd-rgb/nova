// stub: bin/nova-update-check nova-update-check
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/bar/widgets" as Widgets

// The update badge, the real SystemUpdate.qml on a fake bar, and its
// plugin's service, the real SystemUpdateCheck.qml, with nova-update-check a
// stub. The service asks nothing while no copy of the badge holds it; two
// copies, as on two screens, have it ask once and both show its answer; a
// clear or a refresh through either copy is the service's, and so is the
// asking again once an update run says it is done; with the copies gone it
// rests.
ShellRoot {
  id: test

  property Item stage: Item {}
  property Widgets.SystemUpdateCheck service: Widgets.SystemUpdateCheck {}
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
      function serviceFor(id) { return id === "nova.system-update" ? test.service : null }
    }
    function listButton(button, on) {}
    function copiesOf(id) { return test.copies }
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

  // The calls the stub saw, a line each.
  function calls() {
    callsFile.reload()
    return callsFile.text().split("\n").filter(line => line !== "")
  }

  FileView {
    id: callsFile
    path: test.home + "/stub-calls"
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: answer
    path: test.home + "/update-answer"
    printErrors: false
  }

  FileView {
    id: status
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/update/status.json"
    printErrors: false
  }

  Component {
    id: badge
    Widgets.SystemUpdate {}
  }

  Component.onCompleted: {
    answer.setText("available 1.2.3\n")
    rest.start()
  }

  // Given time, an unheld service would have asked by now.
  Timer {
    id: rest
    interval: 500
    onTriggered: {
      test.check("unheld, the service asks nothing", [test.service.wanted, test.calls()], [false, []])
      test.copies = [badge.createObject(test.stage, { bar: test.fakeBar, widgetId: "nova.system-update" }),
        badge.createObject(test.stage, { bar: test.fakeBar, widgetId: "nova.system-update" })]
      test.when(() => test.copies.every(copy => copy.waiting !== ""), "held, the badges show the answer", test.held)
    }
  }

  function held() {
    check("two copies hold the one service", service.holders.length, 2)
    check("which asked once", calls(), ["nova-update-check --notify"])
    check("both copies show what waits", copies.map(copy => [copy.visible, copy.waiting]),
      [[true, "Nova 1.2.3 is available"], [true, "Nova 1.2.3 is available"]])
    copies[1].clear()
    check("cleared through one copy, both are", copies.map(copy => copy.visible), [false, false])
    answer.setText("unfinished 1.2.3\n")
  }

  Connections {
    target: answer
    function onSaved() {
      if (test.calls().length !== 1) return
      test.copies[0].refresh()
      test.when(() => test.copies[1].waiting !== "" && test.calls().length === 2, "refreshed through one copy, the service asks once more", test.refreshed)
    }
  }

  function refreshed() {
    check("the answer, on both", copies.map(copy => copy.waiting),
      ["The update to Nova 1.2.3 did not finish", "The update to Nova 1.2.3 did not finish"])
    answer.setText("current\n")
  }

  Connections {
    target: answer
    function onSaved() {
      if (test.calls().length !== 2) return
      status.setText(JSON.stringify({ state: "done" }))
      test.when(() => test.calls().length === 3 && test.copies[0].waiting === "", "an update run done, the service asks again", test.done)
    }
  }

  function done() {
    check("and the badges go", copies.map(copy => copy.visible), [false, false])
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
