import QtQuick
import Quickshell.Io

// What Settings' window and the welcome show, and how they change it.
// `nova-settings state` fills <info>; a change is the same command the CLI
// offers (nova-theme set, nova battery limit, ...), run one at a time and in
// order, and the state is read again once the last is done, so what the
// window shows is what is set. A command that fails leaves its last line in
// <failure>.
QtObject {
  id: settings

  // `info`, not `data`: `data` is QQuickItem's default property.
  property var info: ({})
  property bool loaded: false
  property string failure: ""
  property bool reloadWanted: false
  property var queue: []

  function load() {
    if (stateProc.running) reloadWanted = true
    else stateProc.running = true
  }

  function run(argv) {
    failure = ""
    var next = queue.slice()
    next.push(argv)
    queue = next
    pump()
  }

  function pump() {
    if (actionProc.running || queue.length === 0) return
    var next = queue.slice()
    actionProc.command = next.shift()
    queue = next
    actionProc.running = true
  }

  property Process stateProc: Process {
    command: ["nova-settings", "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text))
          if (parsed && typeof parsed === "object") {
            settings.info = parsed
            settings.loaded = true
          }
        } catch (e) {
          // A truncated read keeps what is on screen.
        }
      }
    }
    onExited: {
      if (settings.reloadWanted) {
        settings.reloadWanted = false
        running = true
      }
    }
  }

  property Process actionProc: Process {
    stderr: StdioCollector {
      id: actionErrors
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        var message = String(actionErrors.text || "").trim().split("\n").pop()
        settings.failure = message.length > 0 ? message : "That did not work (exit " + exitCode + ")."
      }
      if (settings.queue.length > 0) settings.pump()
      else settings.load()
    }
  }
}
