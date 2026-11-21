// stub: bin/nova-notification-send record
// stub: bin/nova-calendar-sync nova-calendar-sync
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/calendar" as Calendar

// The calendar started again after the computer was off: a reminder that
// fell meanwhile is said, the synced calendar's as the computer's own, though
// the synced calendar's file is read after the computer's (it is made once
// the list of calendars is read). The state file says the calendar last
// looked half an hour ago; each event has a reminder a quarter of an hour
// ago and is still on.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property string folder: home + "/.local/share/nova/calendar"
  property var service: null
  property Item stage: Item {}

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  function ics(body) {
    return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\n" + body.join("\r\n") + "\r\nEND:VCALENDAR\r\n"
  }

  // A time as the file keeps it, in local time.
  function stamp(ms) {
    return Qt.formatDateTime(new Date(ms), "yyyyMMdd'T'HHmmss")
  }

  // An event starting five minutes from now, for an hour, with a reminder
  // twenty minutes before it: a quarter of an hour ago.
  function event(uid, title) {
    const start = Math.floor((Date.now() + 5 * 60000) / 1000) * 1000
    return ics(["BEGIN:VEVENT", "UID:" + uid, "DTSTAMP:20261001T000000Z", "DTSTART:" + stamp(start), "DTEND:" + stamp(start + 3600000),
      "SUMMARY:" + title, "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT20M", "END:VALARM", "END:VEVENT"])
  }

  FileView { id: callsFile; path: test.home + "/stub-calls"; blockLoading: true; printErrors: false }

  function said() {
    callsFile.reload()
    return String(callsFile.text()).trim().split("\n").filter(line => line.startsWith("nova-notification-send"))
  }

  Process {
    id: seed
    command: ["sh", "-c", 'mkdir -p "$1/.config/nova" "$1/.local/state/nova" "$2" && printf "%s" "$3" >"$1/.config/nova/calendars.json" && printf "%s" "$4" >"$1/.local/state/nova/calendar.json" && printf "%s" "$5" >"$2/calendar.ics" && printf "%s" "$6" >"$2/work.ics"',
      "sh", test.home, test.folder,
      JSON.stringify({ accounts: [{ id: "acc1", type: "caldav", name: "Work Server", user: "alice", url: "http://127.0.0.1:5232/" }],
        calendars: [{ id: "work", account: "acc1", kind: "caldav", name: "Work", color: "green", shown: true, readOnly: false, events: true, tasks: false, file: "work.ics" }] }),
      JSON.stringify({ said: Date.now() - 30 * 60000 }) + "\n",
      test.event("own@test", "Dentist"), test.event("synced@test", "Planning")]
    onExited: test.service = made.createObject(test.stage, {})
  }

  Component {
    id: made
    Calendar.Service {}
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => { seed.running = true })

  Timer {
    interval: 100
    repeat: true
    running: test.service !== null
    property int left: 80
    onTriggered: {
      const lines = test.said()
      if (lines.length >= 2 || --left <= 0) {
        stop()
        test.check(lines.some(line => line.indexOf("Dentist") >= 0), "the computer's own calendar's reminder, due while it was off, is said")
        test.check(lines.some(line => line.indexOf("Planning") >= 0), "and the synced calendar's, though its file is read later")
        test.check(lines.length === 2, "each once (" + lines.length + ")")
        test.finish()
      }
    }
  }
}
