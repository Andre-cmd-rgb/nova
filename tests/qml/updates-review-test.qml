// stub: bin/nova-apps-install nova-apps-install
// warns: nova-update-check
import QtQuick
import Quickshell
import "plugins/settings" as Settings

// Reading a held app's recipe in Updates: the commit shown, and so the one
// Build approves, is the one read for the app that is open, also when
// another was asked for while the first was still being read.
ShellRoot {
  id: test

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  // What the stub makes of a name: its first four bytes in hexadecimal, 32
  // zeros after.
  function commitOf(pkg) {
    let hex = ""
    for (let i = 0; i < 4; i++) hex += pkg.charCodeAt(i).toString(16)
    return hex + "0".repeat(32)
  }

  Settings.UpdatesView { id: page; width: 600 }

  property int step: 0

  Timer {
    id: next
    interval: 1500
    onTriggered: {
      test.step++
      if (test.step === 1) {
        test.check("another app asked for while one is being read: its recipe is shown, not the first's",
          [page.reviewing, page.reviewText.indexOf("commit " + test.commitOf("beta")) === 0], ["beta", true])
        page.review("alpha")
        page.review("")
        page.review("alpha")
      } else if (test.step === 2) {
        test.check("closed and asked for again while it was being read, the read stands",
          [page.reviewing, page.reviewText.indexOf("commit " + test.commitOf("alpha")) === 0], ["alpha", true])
        console.log("DONE")
        Qt.quit()
        return
      }
      next.restart()
    }
  }

  Component.onCompleted: Qt.callLater(() => {
    page.review("alpha")
    page.review("beta")
    next.start()
  })
}
