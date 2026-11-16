// stub: bin/nova-toggle-nightlight record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/services/nightlight" as NightLight

// The night light's schedule in the shell: set hours that hold now turn it
// on, once; a switch by hand stays until the next turn; new hours that do
// not hold now turn it off; and a shell started again in the same session
// makes no turn already made. nova-toggle-nightlight is a stub that notes
// each call.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property int minute: new Date().getHours() * 60 + new Date().getMinutes()

  // From an hour ago to an hour from now; or from one hour on to two.
  function hours(fromNow, toNow) {
    const time = minutes => {
      const at = (test.minute + minutes + 1440) % 1440
      return String(Math.floor(at / 60)).padStart(2, "0") + ":" + String(at % 60).padStart(2, "0")
    }
    return { shellConfig: { nightlight: { schedule: "hours", from: time(fromNow), to: time(toNow) } } }
  }

  property var shellNow: hours(-60, 60)
  property QtObject fakeShell: QtObject {
    property var shellConfig: test.shellNow.shellConfig
    function serviceFor(id) { return null }
  }

  property var first: null
  property var second: null
  property int step: 0
  property Item stage: Item {}

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function made() {
    calls.reload()
    calls.waitForJob()
    return String(calls.text()).trim().split("\n").filter(line => line.startsWith("nova-toggle-nightlight"))
  }

  FileView {
    id: calls
    path: test.home + "/stub-calls"
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: turn
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/nightlight-turn"
    blockLoading: true
    printErrors: false
  }

  Component {
    id: service
    NightLight.Service {}
  }

  // Each step a second after the one before: the switch is a process.
  Timer {
    id: next
    interval: 1200
    onTriggered: test.go()
  }

  function go() {
    step += 1
    if (step === 1) {
      check("hours that hold now: on", made(), ["nova-toggle-nightlight on"])
      turn.reload()
      turn.waitForJob()
      check("the turn made is kept for the session", Number(String(turn.text()).trim()) > 0, true)
      first.follow()
      first.setNightlight(false)
    } else if (step === 2) {
      check("followed again, and switched off by hand: nothing more from the schedule", made(), ["nova-toggle-nightlight on", "nova-toggle-nightlight off"])
      first.follow()
      test.shellNow = hours(60, 120)
    } else if (step === 3) {
      check("hours that no longer hold now: off", made().length, 3)
      first.destroy()
    } else if (step === 4) {
      second = service.createObject(stage, { shell: fakeShell })
    } else {
      check("a shell started again makes no turn made already", made().length, 3)
      console.log("DONE")
      Qt.quit()
      return
    }
    next.restart()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    first = service.createObject(stage, { shell: fakeShell })
    next.start()
  })
}
