// stub: bin/nova-calendar-sync nova-calendar-sync
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "plugins/calendar" as Calendar

// An autologin boot, the lock up: the calendar of an account does not sync
// before the boot's first unlock, neither at login nor when a sync is asked
// for, since a sync reads the account's password from the login keyring,
// still locked then, and the keyring would ask for its password behind the
// lock. Once the first unlock is done, the sync asked for runs at once.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  property var calendars: null
  property Item stage: Item {}

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  FileView { id: callsFile; path: test.home + "/stub-calls"; blockAllReads: true; printErrors: false }
  function syncs() {
    callsFile.reload()
    return String(callsFile.text() || "").split("\n").filter(line => line === "nova-calendar-sync sync").length
  }

  Process {
    id: seed
    command: ["sh", "-c", 'mkdir -p "$1/.config/nova" && printf "%s" "$2" >"$1/.config/nova/calendars.json"', "sh", test.home,
      JSON.stringify({ accounts: [{ id: "acc1", type: "icloud", name: "iCloud", user: "alice" }],
        calendars: [{ id: "home", account: "acc1", kind: "caldav", name: "Home", color: "green", shown: true, readOnly: false, events: true, tasks: false, file: "home.ics" }] })]
    onExited: {
      test.check(!Commons.BootLock.unlocked, "an autologin session starts before the boot's first unlock")
      test.calendars = made.createObject(test.stage, {})
      test.later(3600, test.atLogin)
    }
  }

  Component {
    id: made
    Calendar.Calendars {}
  }

  Timer {
    id: wait
    property var next: null
    onTriggered: next()
  }
  function later(ms, next) {
    wait.interval = ms
    wait.next = next
    wait.restart()
  }

  // Past the login's sync, 3 s after the start.
  function atLogin() {
    check(calendars.synced, "the account's calendar is read from the list")
    check(syncs() === 0, "no sync at login while the lock is up")
    calendars.sync()
    later(300, asked)
  }

  function asked() {
    check(syncs() === 0 && !calendars.syncing, "nor when one is asked for")
    Commons.BootLock.unlocked = true
    later(500, unlocked)
  }

  function unlocked() {
    check(syncs() === 1, "the first unlock done, the sync asked for runs, once")
    calendars.sync()
    later(500, after)
  }

  function after() {
    check(syncs() === 2, "and from then on a sync runs when asked for")
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => { seed.running = true })
}
