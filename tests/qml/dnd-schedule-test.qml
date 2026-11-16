// platform: wayland
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/notifications" as Notifications

// Do Not Disturb at set hours, in the notifications' service: hours that
// hold now turn it on, once; a switch by hand stays until the next turn;
// new hours that do not hold now turn it off; and the turn made is kept in
// notifications.json with Do Not Disturb, so that a shell started again,
// as after a reboot, keeps a switch by hand. No bus: the service's server
// has no one to serve.
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
      const saved = kept()
      check("kept with the turn made", [saved.dnd, saved.turn > 0], [true, true])
      first.setDoNotDisturb(false)
      first.followSchedule()
    } else if (step === 2) {
      check("switched off by hand, and followed again: still off", [first.doNotDisturb, kept().dnd], [false, false])
      first.setDoNotDisturb(true)
      fakeShell.shellConfig = hours(60, 120)
    } else if (step === 3) {
      check("hours that no longer hold now: off", first.doNotDisturb, false)
      first.setDoNotDisturb(true)
    } else if (step === 4) {
      check("on by hand again, and kept", kept().dnd, true)
      first.destroy()
    } else if (step === 5) {
      second = service.createObject(stage, { shell: fakeShell })
    } else {
      check("a shell started again keeps the switch by hand", second.doNotDisturb, true)
      fakeShell.shellConfig = {}
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
