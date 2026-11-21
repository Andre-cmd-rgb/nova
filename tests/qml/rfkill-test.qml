// stub: bin/rfkill rfkill
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The shell's one rfkill watch (Rfkill): idle until something holds it,
// the switches as `rfkill event` says them (a stub that prints the lines in
// $HOME/rfkill-event, then waits), each type's blocked switches, a change
// and a switch gone, the lines for one that begins to listen late, and the
// watch stopped once the last hold is let go, not while another holds it.
ShellRoot {
  id: test

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

  property var heard: []
  Connections {
    target: Rfkill
    function onHeard(change) { test.heard = test.heard.concat([change.idx + ":" + change.op]) }
  }

  FileView {
    id: events
    path: Quickshell.env("HOME") + "/rfkill-event"
    printErrors: false
    onSaved: test.held()
  }

  Component.onCompleted: Qt.callLater(begin)

  function begin() {
    check("held by nothing, the watch does not run", [Rfkill.watch.running, Rfkill.switches], [false, {}])
    events.setText("1700000000.1: idx 0 type 2 op 0 soft 1 hard 0\nidx 1 type 5 op 0 soft 0 hard 0\nidx 2 type 1 op 0 soft 0 hard 1\nnonsense\n")
  }

  function held() {
    Rfkill.hold()
    when(() => Object.keys(Rfkill.switches).length === 3, "held, the watch says the switches", () => {
      check("each switch as the watch says it", heard, ["0:0", "1:0", "2:0"])
      check("Bluetooth's switches, blocked or not", Rfkill.blocked(Rfkill.bluetooth), { "0": true })
      check("the modem's", Rfkill.blocked(Rfkill.wwan), { "1": false })
      check("the switches as lines, for one that listens late", Rfkill.lines(),
        ["idx 0 type 2 op 0 soft 1 hard 0", "idx 1 type 5 op 0 soft 0 hard 0", "idx 2 type 1 op 0 soft 0 hard 1"])
      Rfkill.take("idx 0 type 2 op 2 soft 0 hard 0")
      check("a switch unblocked", Rfkill.blocked(Rfkill.bluetooth), { "0": false })
      Rfkill.take("idx 0 type 2 op 1 soft 0 hard 0")
      check("a switch gone", [Rfkill.blocked(Rfkill.bluetooth), heard.slice(-2)], [{}, ["0:2", "0:1"]])
      Rfkill.hold()
      Rfkill.release()
      Qt.callLater(() => Qt.callLater(stillHeld))
    })
  }

  function stillHeld() {
    check("let go by one of two, the watch runs on", Rfkill.watch.running, true)
    Rfkill.release()
    when(() => !Rfkill.watch.running, "let go by the last, the watch stops", () => {
      check("stopped, it knows no switch", Rfkill.switches, {})
      finish()
    })
  }
}
