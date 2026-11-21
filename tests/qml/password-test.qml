// warns: Process failed to start, likely because the binary could not be found. Command: QList("nova-no-such-command")
import QtQuick
import Quickshell
import "plugins/settings" as Settings

ShellRoot {
  Settings.PasswordSheet { id: sheet; width: 700; height: 500 }
  property int changes: 0
  Connections { target: sheet; function onChanged() { changes++ } }

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  Component.onCompleted: Qt.callLater(function () {
    sheet.open()
    check(sheet.opened && !sheet.busy && sheet.error === "", "opens a fresh sheet")
    sheet.currentPassword = "old"
    sheet.newPassword = "new"
    sheet.repeatedPassword = "other"
    sheet.submit()
    check(sheet.error === "The new passwords are not the same." && !sheet.busy, "mismatch never starts a helper")
    check(!sheet.newPassword && !sheet.repeatedPassword, "mismatch clears the new fields")
    sheet.cancel()
    check(!sheet.opened && !sheet.currentPassword, "cancel hides the sheet and clears secrets")

    sheet.open()
    sheet.busy = true
    sheet.cancel()
    check(sheet.opened && sheet.busy, "a change under way is not cancelled halfway")
    sheet.finish(1, '{"ok":false,"error":"The current password is not right."}')
    check(sheet.opened && !sheet.busy && sheet.error === "The current password is not right.", "a failed change stays in the sheet")
    sheet.busy = true
    sheet.finish(0, '{"ok":true}')
    check(!sheet.opened && changes === 1, "success closes the sheet with confirmation")
    sheet.finish(0, '{"ok":true}')
    check(changes === 1, "an old process result cannot confirm twice")
    sheet.open()
    sheet.busy = true
    sheet.finish(0, 'not JSON')
    check(sheet.opened && sheet.error === "Could not change the password.", "missing results fail closed")
    sheet.cancel()

    // A helper that cannot start is never heard to exit: the sheet is let
    // go all the same, saying so, rather than held busy for good.
    sheet.helper = ["nova-no-such-command"]
    sheet.open()
    sheet.currentPassword = "old"
    sheet.newPassword = "new"
    sheet.repeatedPassword = "new"
    sheet.submit()
    waitFor(function () { return !sheet.busy }, function (done) {
      check(done && sheet.opened && sheet.error === "Could not change the password.", "a helper that cannot start lets the sheet go, saying so")
      check(!sheet.currentPassword && !sheet.newPassword && !sheet.repeatedPassword, "and clears the secrets")
      sheet.cancel()
      check(!sheet.opened, "which can then be cancelled")
      console.log("DONE")
      Qt.quit()
    })
  })

  // Calls <then> with true once <done> holds, or with false after 5 s.
  function waitFor(done, then) {
    poll.done = done
    poll.then = then
    poll.left = 100
    poll.start()
  }
  Timer {
    id: poll
    property var done: null
    property var then: null
    property int left: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (done()) { stop(); then(true) }
      else if (--left <= 0) { stop(); then(false) }
    }
  }
}
