// platform: wayland
import QtQuick
import Quickshell
import "plugins/screentime" as ScreenTime

// Screen Time's bar widget, in two copies of the real BarWidget.qml on a fake
// bar, as on two screens, and the plugin's service, the real Service.qml,
// with its real helper in the scratch home: the service asks today's total
// for both copies, which show the same, and rests from it with the copies
// gone. Without the service (Screen Time off) a copy shows nothing.
ShellRoot {
  id: test

  property Item stage: Item {}
  property ScreenTime.Service service: ScreenTime.Service {}
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
      property bool recording: true
      function serviceFor(id) { return id === "nova.screentime" && recording ? test.service : null }
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

  Component {
    id: widget
    ScreenTime.BarWidget {}
  }

  Component.onCompleted: Qt.callLater(begin)

  function begin() {
    check("unheld, no total asked", [service.wanted, service.total], [false, ""])
    fakeBar.shell.recording = false
    const alone = widget.createObject(stage, { bar: fakeBar })
    check("with Screen Time off, the widget shows nothing and holds nothing", [alone.visible, alone.implicitWidth, service.holders.length], [false, 0, 0])
    alone.destroy()
    fakeBar.shell.recording = true
    copies = [widget.createObject(stage, { bar: fakeBar }), widget.createObject(stage, { bar: fakeBar })]
    waiter.start()
  }

  Timer {
    id: waiter
    property int left: 100
    interval: 50
    repeat: true
    onTriggered: {
      if (test.service.total === "" && --left > 0) return
      stop()
      test.check("held by both copies", test.service.holders.length, 2)
      test.check("today's total, the same on both", test.copies.map(copy => [copy.total !== "", copy.total === test.service.total]),
        [[true, true], [true, true]])
      for (const copy of test.copies) copy.destroy()
      test.copies = []
      gone.start()
    }
  }

  Timer {
    id: gone
    interval: 200
    onTriggered: {
      test.check("with the copies gone, the service rests from it", [test.service.holders.length, test.service.wanted], [0, false])
      test.finish()
    }
  }
}
