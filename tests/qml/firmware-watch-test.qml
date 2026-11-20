// stub: bin/nova-firmware-job nova-firmware-job
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/settings" as Settings

// Settings' firmware section on the Updates page, as it opens on a computer
// with fwupd: it checks once a boot, and follows the job's state file as the
// job writes it (whole, then moved into place), the first one included,
// with nothing looking at the file on a clock meanwhile.
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova"

  FileView {
    id: calls
    path: Quickshell.env("HOME") + "/stub-calls"
    printErrors: false
    blockLoading: true
  }

  function asked(words) {
    calls.reload()
    return String(calls.text()).split("\n").filter(function (l) { return l === words }).length
  }

  // A job's state, written as nova-firmware-job writes it.
  Process {
    id: job
    command: ["sh", "-c", "printf '%s' \"$2\" >\"$1/firmware.new\" && mv -f \"$1/firmware.new\" \"$1/firmware.json\"", "sh", test.runDir,
      '{"running":false,"checked":true,"action":"check","devices":[{"id":"abc","name":"System Firmware","current":"0.1.53","version":"0.1.55","summary":"","status":"available","progress":0}]}']
    onExited: seen.start()
  }

  Process {
    id: clean
    command: ["rm", "-f", test.runDir + "/firmware.json"]
    onExited: loader.active = true
  }

  Loader {
    id: loader
    active: false
    sourceComponent: Settings.FirmwareView { monitor: true; width: 600 }
  }

  Timer {
    id: opened
    interval: 1500
    running: loader.status === Loader.Ready
    onTriggered: {
      test.check(test.asked("nova-firmware-job check") === 1, "opened with no check this boot, it checks once")
      test.check(!loader.item.shown, "  and shows nothing before the job has said")
      job.running = true
    }
  }

  Timer {
    id: seen
    interval: 1000
    onTriggered: {
      test.check(loader.item.devices.length === 1 && loader.item.shown, "the job's first state file is read as it appears")
      console.log("DONE")
      Qt.quit()
    }
  }

  Component.onCompleted: clean.running = true
}
