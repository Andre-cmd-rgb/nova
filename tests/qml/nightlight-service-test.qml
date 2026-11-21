// stub: bin/nova-toggle-nightlight record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/services/nightlight" as NightLight

// The night light's schedule in the shell: set hours that hold now turn it
// on, once; a switch by hand stays until the next turn, also when the turn
// moves a few minutes, as a sunset does when its place is looked up again;
// new hours that do not hold now turn it off; the schedule switched off ends
// a night it turned on, leaves one turned on by hand, and forgets its last
// turn, so that switched on again it makes it again; and a shell started
// again in the same session makes no turn already made.
// nova-toggle-nightlight is a stub that notes each call.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property int minute: new Date().getHours() * 60 + new Date().getMinutes()

  // From <fromNow> minutes from now to <toNow>, as shell.json has them.
  function hours(fromNow, toNow) {
    const time = minutes => {
      const at = (test.minute + minutes + 1440) % 1440
      return String(Math.floor(at / 60)).padStart(2, "0") + ":" + String(at % 60).padStart(2, "0")
    }
    return { nightlight: { schedule: "hours", from: time(fromNow), to: time(toNow) } }
  }

  // An hour ago, moved five minutes the way that keeps it on the same day.
  readonly property int moved: new Date(Date.now() - 55 * 60000).getDate() === new Date(Date.now() - 60 * 60000).getDate() ? -55 : -65

  property QtObject fakeShell: QtObject {
    property var shellConfig: test.hours(-60, 60)
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

  // The calls to the switch so far, "on" and "off".
  function made() {
    calls.reload()
    calls.waitForJob()
    return String(calls.text()).trim().split("\n").filter(line => line.startsWith("nova-toggle-nightlight")).map(line => line.split(" ")[1])
  }

  function kept() {
    turn.reload()
    turn.waitForJob()
    return String(turn.text()).trim()
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
      check("hours that hold now: on", made(), ["on"])
      check("the turn made is kept for the session, by its day", /^on \d{4}-\d\d-\d\d$/.test(kept()), true)
      const ahead = (first.nextTurn - Date.now()) / 60000
      check("a timer waits for the next turn, the end of the hours in an hour", ahead > 58 && ahead <= 60, true)
      first.setNightlight(false)
      fakeShell.shellConfig = hours(moved, 60)
    } else if (step === 2) {
      check("off by hand, and the turn five minutes earlier: still off", made(), ["on", "off"])
      fakeShell.shellConfig = hours(60, 120)
    } else if (step === 3) {
      check("hours that no longer hold now: off", made(), ["on", "off", "off"])
      fakeShell.shellConfig = hours(-60, 60)
    } else if (step === 4) {
      check("and that hold again: on", made().slice(3), ["on"])
      fakeShell.shellConfig = { nightlight: { schedule: "off" } }
    } else if (step === 5) {
      check("the schedule off ends the night it turned on, and forgets the turn", [made().slice(4), kept()], [["off"], ""])
      check("and waits for no turn", first.nextTurn, 0)
      fakeShell.shellConfig = hours(-60, 60)
    } else if (step === 6) {
      check("on again, the same hours turn it on again", made().slice(5), ["on"])
      first.setNightlight(false)
      first.setNightlight(true)
    } else if (step === 7) {
      check("off and on by hand", made().slice(6), ["off", "on"])
      fakeShell.shellConfig = { nightlight: { schedule: "off" } }
    } else if (step === 8) {
      check("the schedule off leaves a night turned on by hand", made().length, 8)
      fakeShell.shellConfig = hours(-60, 60)
    } else if (step === 9) {
      check("on again: its turn, though the night is on already", made().slice(8), ["on"])
      first.destroy()
    } else if (step === 10) {
      second = service.createObject(stage, { shell: fakeShell })
    } else {
      check("a shell started again makes no turn made already", made().length, 9)
      // Tromsø at midwinter: no sunrise in the days ahead.
      second.place = { latitude: 69.65, longitude: 18.96 }
      fakeShell.shellConfig = { nightlight: { schedule: "sunset" } }
      const polarNoon = new Date(2026, 11, 21, 12).getTime()
      check("by the sun with no turn in the days ahead (a polar night), it looks again a day on", second.lookAgainAfter(polarNoon), polarNoon + 86400000)
      fakeShell.shellConfig = { nightlight: { schedule: "off" } }
      check("and with no schedule, never", second.lookAgainAfter(polarNoon), null)
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
