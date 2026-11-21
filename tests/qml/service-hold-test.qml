import QtQuick
import Quickshell
import "plugins/readouts" as Readouts

// A widget's hold on its service (Ui/ServiceHold.qml), through the CPU
// readout, the real Cpu.qml on a fake bar: nothing held while the shell has
// no service yet, the part held once one comes, moved to a new one when the
// service is made again, and let go with the widget.
ShellRoot {
  id: test

  property Item stage: Item {}
  property var service: null
  property var widget: null

  component FakeService: QtObject {
    property var held: []
    property int cpu: 42
    function hold(part) { held = held.concat([part]) }
    function release(part) {
      const at = held.indexOf(part)
      if (at >= 0) held = held.slice(0, at).concat(held.slice(at + 1))
    }
  }

  property FakeService first: FakeService {}
  property FakeService second: FakeService {}

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
      function serviceFor(id) { return id === "nova.readouts" ? test.service : null }
    }
    function listButton(button, on) {}
    function run(command) {}
  }

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  Component {
    id: cpu
    Readouts.Cpu {}
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    widget = cpu.createObject(stage, { bar: fakeBar })
    check("no service yet: nothing shown", widget.percent, -1)
    service = first
    check("the service come: the part held, and read", [first.held, widget.percent], [["cpu"], 42])
    service = second
    check("the service made again: the hold moved to the new one", [first.held, second.held], [[], ["cpu"]])
    widget.destroy()
    gone.start()
  }

  Timer {
    id: gone
    interval: 200
    onTriggered: {
      test.check("the widget gone: let go", test.second.held, [])
      console.log("DONE")
      Qt.quit()
    }
  }
}
