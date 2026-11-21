// stub: bin/nova-notification-send record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/calendar" as Calendar

// The calendar's reminders, with no clock but the one aimed at the next:
// how far it has looked is kept as it starts, with no file yet; a reminder
// added is waited for, said on time (nova-notification-send is a stub that
// notes it), and kept as said; then, with nothing due, the timer waits a
// day, and a look at the clock writes nothing. An event that comes in with
// its reminder already past is not said when the next one is, and is kept as
// looked over, so that a restart does not say it either; a change that comes
// as a reminder falls due does not skip it.
ShellRoot {
  id: test

  property var service: null
  property Item stage: Item {}
  property real alarm: 0
  property string keptBefore: ""

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  FileView { id: callsFile; path: Quickshell.env("HOME") + "/stub-calls"; blockLoading: true; printErrors: false }
  FileView { id: stateFile; path: test.service ? test.service.statePath : ""; blockLoading: true; printErrors: false }

  function said() {
    callsFile.reload()
    callsFile.waitForJob()
    return String(callsFile.text()).trim().split("\n").filter(line => line.startsWith("nova-notification-send"))
  }

  function kept() {
    stateFile.reload()
    stateFile.waitForJob()
    try {
      return Number(JSON.parse(String(stateFile.text())).said) || 0
    } catch (e) {
      return 0
    }
  }

  // Waits for <done> to hold, then calls <next>; fails <what> after 8 s.
  function when(done, next, what) {
    waiter.done = done
    waiter.next = next
    waiter.what = what
    waiter.left = 160
    waiter.start()
  }
  Timer {
    id: waiter
    property var done: null
    property var next: null
    property string what: ""
    property int left: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (done()) {
        stop()
        next()
      } else if (--left <= 0) {
        stop()
        test.check(what, false, true)
        test.finish()
      }
    }
  }

  Component {
    id: made
    Calendar.Service {}
  }

  Component.onCompleted: Qt.callLater(() => {
    service = made.createObject(stage, {})
    when(() => service.store.loaded && service.stateRead && kept() > 0, started, "the calendar loads, and how far it looked is kept")
  })

  function started() {
    const now = Date.now()
    check("with no file yet, how far it looked is kept as it starts", Math.abs(kept() - now) < 5000, true)
    check("nothing due: no reminder waited for", service.nextAlarm, 0)
    // On a whole second, as the calendar's file keeps times.
    alarm = Math.ceil((now + 3000) / 1000) * 1000
    service.store.addEvent({ title: "Stand-up", start: alarm + 60000, end: alarm + 3600000, allDay: false, reminder: -60000, repeat: "none" })
    when(() => service.nextAlarm !== 0, () => {
      check("a reminder added is waited for, at its time", service.nextAlarm, alarm)
      when(() => said().length > 0, reminded, "the reminder is said")
    }, "the reminder added is waited for")
  }

  function reminded() {
    const now = Date.now()
    check("said on time: not before its time, and within two seconds of it", now >= alarm && now - alarm < 2500, true)
    check("said once, as itself", said().length === 1 && said()[0].indexOf("Stand-up") >= 0, true)
    check("and kept as said", kept() >= alarm, true)
    check("nothing more due in two days: no reminder waited for", service.nextAlarm, 0)
    keptBefore = String(stateFile.text())
    service.remind()
    pause.start()
  }

  // A moment for a write that should not come.
  Timer {
    id: pause
    interval: 700
    onTriggered: {
      test.kept()
      test.check("a look at the clock with no reminder come since writes nothing", String(stateFile.text()), test.keptBefore)
      test.addPast()
    }
  }

  // A meeting made on a phone, synced after its reminder went (since the
  // file was last written: a whole second, as the calendar keeps times), and
  // one to come a moment later.
  property real past: 0
  function addPast() {
    when(() => Math.floor(Date.now() / 1000) * 1000 > service.saidKept, () => {
      const now = Date.now()
      past = Math.floor(now / 1000) * 1000
      alarm = Math.ceil((now + 3000) / 1000) * 1000
      service.store.addEvent({ title: "Synced", start: past + 600000, end: past + 3600000, allDay: false, reminder: -600000, repeat: "none" })
      service.store.addEvent({ title: "Review", start: alarm + 60000, end: alarm + 3600000, allDay: false, reminder: -60000, repeat: "none" })
      // The file is written as the change comes, a moment after it.
      when(() => service.nextAlarm === alarm && kept() >= past, () => {
        check("a reminder already past when it comes in is kept as looked over", true, true)
        when(() => said().length > 1, () => {
          const lines = said()
          check("the next reminder is said, and the one already past is not",
            lines.length === 2 && lines[1].indexOf("Review") >= 0 && !lines.some(line => line.indexOf("Synced") >= 0), true)
          changeAsDue()
        }, "the next reminder is said")
      }, "the next reminder is waited for, and the one already past kept as looked over")
    }, "a second goes by")
  }

  // A change that comes as a reminder falls due, before the timer (a second
  // late, on purpose) has come to it: the reminder is said, once, and not
  // skipped as one the change brought.
  function changeAsDue() {
    const now = Date.now()
    alarm = Math.ceil((now + 3000) / 1000) * 1000
    service.store.addEvent({ title: "Retro", start: alarm + 60000, end: alarm + 3600000, allDay: false, reminder: -60000, repeat: "none" })
    when(() => Date.now() >= alarm + 150, () => {
      service.store.addEvent({ title: "Later", start: alarm + 86400000, end: alarm + 90000000, allDay: false, reminder: -60000, repeat: "none" })
      afterDue.start()
    }, "the reminder falls due")
  }

  Timer {
    id: afterDue
    interval: 1800
    onTriggered: {
      const lines = test.said().filter(line => line.indexOf("Retro") >= 0)
      test.check("a change as a reminder falls due: the reminder is said, once", lines.length, 1)
      test.finish()
    }
  }
}
