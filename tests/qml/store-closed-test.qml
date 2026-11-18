// platform: wayland
// stub: bin/nova-apps-catalog apps
// stub: bin/nova-apps-installed record
// stub: bin/nova-apps-refresh apps
// warns: nova-apps-installed
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/store" as Store

// The App Center with its window shut does not look at what is installed
// (pacman and flatpak, a few processes) because a job ended: at login the
// status of an earlier run is there, and a job can end under the CLI's own
// hand. Opening the window reads it, once.
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/apps"

  FileView {
    id: calls
    path: Quickshell.env("HOME") + "/stub-calls"
    printErrors: false
    blockLoading: true
  }

  function asked() {
    calls.reload()
    return String(calls.text()).split("\n").filter(function (l) { return l.indexOf("nova-apps-installed") === 0 }).length
  }

  Process {
    id: prepare
    command: ["sh", "-c", "mkdir -p \"$1\" && printf '{\"org.gimp.GIMP\":{\"action\":\"install\",\"state\":\"done\",\"progress\":100,\"time\":%s}}\\n' \"$(date +%s)\" >\"$1/status.json\"", "sh", test.runDir]
    onExited: {
      loader.active = true
      wait.start()
    }
  }

  Loader {
    id: loader
    active: false
    sourceComponent: Store.Panel {}
  }

  Timer {
    id: wait
    interval: 1500
    onTriggered: {
      test.check(test.asked() === 0, "a job ended while the window is shut: nothing is read")
      loader.item.open("{}")
      again.start()
    }
  }

  Timer {
    id: again
    interval: 1500
    onTriggered: {
      test.check(test.asked() === 1, "opening the window reads what is installed, once")
      console.log("DONE")
      Qt.quit()
    }
  }

  Component.onCompleted: prepare.running = true
}
