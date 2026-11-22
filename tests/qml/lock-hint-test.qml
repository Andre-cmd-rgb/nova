// stub: bin/busctl record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/lock" as Lock

// logind's LockedHint follows the lock: true once it is secure, false when
// it ends, nothing at the start; a change while a call runs is made after it,
// so the last call says what the lock is. busctl is a stub that notes its
// calls; no bus.
ShellRoot {
  id: test

  property bool secure: false
  property Item stage: Item {}

  Component {
    id: maker
    Lock.LockedHint { secure: test.secure }
  }

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  FileView { id: calls; path: Quickshell.env("HOME") + "/stub-calls"; blockAllReads: true; printErrors: false }
  function said() {
    calls.reload()
    return String(calls.text() || "").split("\n").filter(line => line !== "")
      .map(line => line.replace("busctl --system -- call org.freedesktop.login1 /org/freedesktop/login1/session/auto org.freedesktop.login1.Session SetLockedHint b ", ""))
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

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    maker.createObject(stage)
    later(300, () => {
      check(said().length === 0, "nothing is said as the shell starts")
      secure = true
      later(400, () => {
        check(JSON.stringify(said()) === JSON.stringify(["true"]), "the lock secure: the hint is true, on the user's display session")
        secure = false
        secure = true
        secure = false
        later(600, () => {
          const all = said()
          check(all.length >= 2 && all[all.length - 1] === "false", "changes while a call runs end with the lock as it is: unlocked, false")
          console.log("DONE")
          Qt.quit()
        })
      })
    })
  })
}
