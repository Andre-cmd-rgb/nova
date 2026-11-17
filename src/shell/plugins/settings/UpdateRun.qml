import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "UpdatesModel.js" as Model

// A run of nova update started from a window (nova-update-run), which goes
// on as a user service of its own: how far it is, from the status.json
// nova update --status writes, which this only reads. Closed and opened
// again, a window finds the run where it is. Settings' Updates page and the
// welcome's apps follow it.
QtObject {
  id: run

  readonly property string dir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/update"
  property var status: ({})
  // Whether the service runs, asked once a status says "running".
  property bool alive: true
  property bool aliveAsked: false
  // Watched once it exists: Quickshell sees a file appear in a folder that
  // is there, not in one made after it started looking.
  property bool watching: false

  readonly property string state: Model.state(status, alive)
  readonly property bool running: state === "running"
  readonly property real fraction: Model.fraction(status)

  function start(args) {
    alive = true
    Util.execArgv(["nova-update-run"].concat(args))
  }

  property Process folder: Process {
    command: ["mkdir", "-p", run.dir]
    running: true
    onExited: run.watching = true
  }

  property FileView file: FileView {
    path: run.watching ? run.dir + "/status.json" : ""
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && typeof parsed === "object") run.status = parsed
      } catch (e) {
        // Written whole, then moved into place: a bad read is someone else's.
      }
      // One stopped from outside left "running" behind it.
      if (run.status.state === "running" && !run.aliveAsked) {
        run.aliveAsked = true
        aliveProc.running = true
      }
    }
    onLoadFailed: run.status = ({})
    onFileChanged: reload()
  }

  property Process aliveProc: Process {
    command: ["systemctl", "--user", "--quiet", "is-active", "nova-update.service"]
    onExited: function (exitCode) { run.alive = exitCode === 0 }
  }
}
