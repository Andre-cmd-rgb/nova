// stub: bin/nova-power-profile record
// stub: bin/nova-battery-low record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/services/battery" as Battery

// The battery service with no UPower on the bus, as on a desktop: it puts
// the power mode back once as it starts, warns of nothing, and keeps no clock
// of its own; UPower's own changes are what it looks at.
ShellRoot {
  id: test

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  Battery.Service { id: battery }

  FileView { id: callsFile; path: Quickshell.env("HOME") + "/stub-calls"; blockLoading: true; printErrors: false }

  function calls() {
    callsFile.reload()
    return callsFile.text().trim()
  }

  // Up to 5 s for the start's power mode, and a moment more for anything
  // that should not come.
  property int tries: 0
  Timer {
    interval: 50
    repeat: true
    running: true
    onTriggered: {
      if (test.calls() === "" && ++test.tries < 100) return
      stop()
      settle.start()
    }
  }

  Timer {
    id: settle
    interval: 300
    onTriggered: {
      test.check(test.calls() === "nova-power-profile restore", "the start puts the power mode back, once, and warns of nothing")
      battery.look()
      test.check(test.calls() === "nova-power-profile restore", "no battery: a look warns of nothing")
      test.check(!battery.data.some(child => String(child).startsWith("QQmlTimer")), "no clock of its own")
      console.log("DONE")
      Qt.quit()
    }
  }
}
