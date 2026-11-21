// platform: wayland
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/notifications" as Notifications

// Do Not Disturb at set hours, in the notifications' service: hours that
// hold now turn it on, once; a switch by hand stays until the next turn,
// also when the hours move a few minutes; new hours that do not hold now
// turn it off; the schedule switched off ends a Do Not Disturb it turned
// on, leaves one turned on by hand, and forgets its last turn; and the turn
// made is kept in notifications.json with Do Not Disturb, so that a shell
// started again, as after a reboot, keeps a switch by hand. No bus: the
// service's server has no one to serve.
ShellRoot {
  id: test

  readonly property string state: Quickshell.env("HOME") + "/.local/state/nova/notifications.json"
  readonly property int minute: new Date().getHours() * 60 + new Date().getMinutes()

  // From <fromNow> minutes from now to <toNow>, as shell.json has them.
  function hours(fromNow, toNow) {
    const time = minutes => {
      const at = (test.minute + minutes + 1440) % 1440
      return String(Math.floor(at / 60)).padStart(2, "0") + ":" + String(at % 60).padStart(2, "0")
    }
    return { doNotDisturb: { schedule: "hours", from: time(fromNow), to: time(toNow) } }
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

  // notifications.json as the service last wrote it.
  function kept() {
    file.reload()
    file.waitForJob()
    try {
      return JSON.parse(String(file.text()))
    } catch (e) {
      return {}
    }
  }

  FileView {
    id: file
    path: test.state
    blockLoading: true
    printErrors: false
  }

  Component {
    id: service
    Notifications.Service {}
  }

  // Each step a moment after the one before: the file is written 200 ms
  // after a change.
  Timer {
    id: next
    interval: 700
    onTriggered: test.go()
  }

  function go() {
    step += 1
    if (step === 1) {
      check("hours that hold now: on", first.doNotDisturb, true)
      const ahead = (first.dndNext - Date.now()) / 60000
      check("a timer waits for the next turn, the end of the hours in an hour", ahead > 58 && ahead <= 60, true)
      const saved = kept()
      check("kept with the turn made, by its day", [saved.dnd, /^on \d{4}-\d\d-\d\d$/.test(saved.turn), saved.bySchedule], [true, true, true])
      first.setDoNotDisturb(false)
      fakeShell.shellConfig = hours(moved, 60)
    } else if (step === 2) {
      check("off by hand, and the hours five minutes earlier: still off", [first.doNotDisturb, kept().dnd], [false, false])
      first.setDoNotDisturb(true)
      fakeShell.shellConfig = hours(60, 120)
    } else if (step === 3) {
      check("on by hand, then hours that do not hold now: off", first.doNotDisturb, false)
      fakeShell.shellConfig = hours(-60, 60)
    } else if (step === 4) {
      check("and that hold again: on", first.doNotDisturb, true)
      fakeShell.shellConfig = { doNotDisturb: { schedule: "off" } }
    } else if (step === 5) {
      const saved = kept()
      check("the schedule off ends the Do Not Disturb it turned on, and forgets the turn", [first.doNotDisturb, saved.dnd, saved.turn], [false, false, ""])
      check("and waits for no turn", first.dndNext, 0)
      fakeShell.shellConfig = hours(-60, 60)
    } else if (step === 6) {
      check("on again, the same hours turn it on again", first.doNotDisturb, true)
      first.setDoNotDisturb(false)
      first.setDoNotDisturb(true)
      fakeShell.shellConfig = { doNotDisturb: { schedule: "off" } }
    } else if (step === 7) {
      check("the schedule off leaves one turned on by hand", [first.doNotDisturb, kept().dnd], [true, true])
      fakeShell.shellConfig = hours(-60, 60)
    } else if (step === 8) {
      check("on again: its turn made, though Do Not Disturb is on already", kept().turn !== "", true)
      first.setDoNotDisturb(false)
    } else if (step === 9) {
      check("then off by hand, and kept", [first.doNotDisturb, kept().dnd], [false, false])
      first.destroy()
    } else if (step === 10) {
      second = service.createObject(stage, { shell: fakeShell })
    } else {
      check("a shell started again keeps the switch by hand", second.doNotDisturb, false)
      console.log("DONE")
      Qt.quit()
      return
    }
    next.restart()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    file.setText(JSON.stringify({ version: 3, dnd: false }) + "\n")
    first = service.createObject(stage, { shell: fakeShell })
    next.start()
  })
}
