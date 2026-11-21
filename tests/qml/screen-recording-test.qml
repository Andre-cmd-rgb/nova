// stub: bin/nova-session-pgrep nova-session-pgrep
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/bar/widgets" as Widgets

// The screen recording indicator, in two copies of the real Indicators.qml
// on a fake bar, as on two screens, and the indicators' service, the real
// RecorderSearch.qml, with nova-session-pgrep a stub. The service looks for
// the recorder once for all the copies as they come; a refresh through one
// copy looks once more, and a recorder found lights the indicator on both;
// with the copies gone it rests.
ShellRoot {
  id: test

  property Item stage: Item {}
  property Widgets.RecorderSearch service: Widgets.RecorderSearch {}
  property var copies: []

  property QtObject fakeBar: QtObject {
    readonly property int thickness: 30
    readonly property string fontFamily: "monospace"
    readonly property color textColour: "white"
    readonly property color urgent: "red"
    readonly property bool textFades: false
    readonly property bool peek: false
    property QtObject tip: QtObject {
      function ask(button, text) {}
      function withdraw(button) {}
    }
    property QtObject shell: QtObject {
      function serviceFor(id) { return id === "nova.indicators" ? test.service : null }
    }
    function listButton(button, on) {}
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
    id: recording
    path: test.home + "/recording"
    printErrors: false
    onSaved: {
      test.copies[1].refresh()
      test.when(() => test.copies.every(copy => copy.order.length === 1) && test.calls().length === 2,
        "refreshed through one copy, the service looks once more, and the indicator is lit on both", test.lit)
    }
  }

  Component {
    id: indicators
    Widgets.Indicators { settings: ({ items: ["ScreenRecording"] }) }
  }

  Component.onCompleted: Qt.callLater(begin)

  function begin() {
    copies = [indicators.createObject(stage, { bar: fakeBar }), indicators.createObject(stage, { bar: fakeBar })]
    when(() => calls().length > 0 && !test.service.askedAgain, "held, the service looks", held)
  }

  function held() {
    settle.start()
  }

  // Given time, a second look would have come by now.
  Timer {
    id: settle
    interval: 500
    onTriggered: {
      test.check("the copies hold the one service", test.service.holders.length, 2)
      test.check("which looked once for both", test.calls(), ["nova-session-pgrep -f ^gpu-screen-recorder"])
      test.check("nothing lit", test.copies.map(copy => copy.order.length), [0, 0])
      recording.setText("on\n")
    }
  }

  function lit() {
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
