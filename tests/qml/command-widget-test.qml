import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/bar" as BarParts

// A user's command widget, the real CommandWidget.qml in two copies on a fake
// bar with the bar's real runs (CommandRuns.qml), as on two screens: the
// command runs once for both, and both show what it printed; an entry with
// another interval is a run of its own; with the copies gone, the runs go.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  property Item stage: Item {}
  property var copies: []

  property Item fakeBar: Item {
    readonly property int thickness: 30
    readonly property string fontFamily: "monospace"
    readonly property color foreground: "white"
    readonly property color textColour: "white"
    readonly property color urgent: "red"
    readonly property bool textFades: false
    readonly property bool peek: false
    readonly property BarParts.CommandRuns commands: BarParts.CommandRuns {}
    property QtObject tip: QtObject {
      function ask(button, text) {}
      function withdraw(button) {}
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

  // The runs of the command, a line each.
  function runs() {
    runsFile.reload()
    return runsFile.text().split("\n").filter(line => line !== "").length
  }

  FileView {
    id: runsFile
    path: test.home + "/runs"
    blockLoading: true
    printErrors: false
  }

  readonly property string exec: "echo ran >>\"$HOME/runs\"; echo '{\"text\":\"91%\",\"class\":\"active\"}'"

  Component {
    id: widget
    BarParts.CommandWidget {}
  }

  Component.onCompleted: Qt.callLater(begin)

  function begin() {
    const entry = { id: "disk", exec: exec, interval: 600 }
    copies = [widget.createObject(stage, { bar: fakeBar, entry: entry }), widget.createObject(stage, { bar: fakeBar, entry: entry })]
    when(() => copies.every(copy => copy.text === "91%"), "both copies show what the command printed", shown)
  }

  function shown() {
    settle.start()
  }

  // Given time, a second run would have come by now.
  Timer {
    id: settle
    interval: 500
    onTriggered: {
      test.check("run once for both", [test.runs(), Object.keys(test.fakeBar.commands.runs).length], [1, 1])
      test.check("both in the urgent colour, as its class says", test.copies.map(copy => copy.urgent), [true, true])
      test.copies.push(widget.createObject(test.stage, { bar: test.fakeBar, entry: { id: "disk2", exec: test.exec, interval: 300 } }))
      test.when(() => test.runs() === 2 && test.copies[2].text === "91%", "another interval is a run of its own", test.other)
    }
  }

  function other() {
    check("two runs", Object.keys(fakeBar.commands.runs).length, 2)
    for (const copy of copies) copy.destroy()
    copies = []
    gone.start()
  }

  Timer {
    id: gone
    interval: 200
    onTriggered: {
      test.check("with the copies gone, the runs go", Object.keys(test.fakeBar.commands.runs).length, 0)
      test.finish()
    }
  }
}
