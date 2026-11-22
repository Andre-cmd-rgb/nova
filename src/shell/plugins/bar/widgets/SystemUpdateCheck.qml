import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// What the update badge (SystemUpdate.qml) shows, asked once for every
// screen's copy of it, while a copy holds it: nova-update-check every six
// hours, and again once an update run says it is done. Its answers are said
// as a notification by the check itself (--notify), once.
BarWidgetService {
  id: check

  // What waits, in the tooltip's words; "" while nothing does.
  property string waiting: ""

  // Only while a copy holds it.
  function refresh() {
    if (wanted && !checker.running) checker.running = true
  }

  function clear() {
    waiting = ""
  }

  // nova-update-check's answer, a line: "available <version>", "unfinished
  // <version>", "apps <app>...", "repair" or "current". Another answer
  // leaves the badge as it is. A repair alone lights none: Settings →
  // Updates offers it and every update makes it, and one declined would
  // keep the badge lit for good.
  function heard(answer) {
    if (answer.startsWith("available ")) waiting = "Nova " + answer.slice(10) + " is available"
    else if (answer.startsWith("unfinished ")) waiting = "The update to Nova " + answer.slice(11) + " did not finish"
    else if (answer.startsWith("apps ")) waiting = "App updates are available"
    else if (answer === "current" || answer === "repair") waiting = ""
  }

  Process {
    id: checker
    command: ["nova-update-check", "--notify"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: check.heard(String(text).trim())
    }
    // No answer: offline, as a session often still is when its bar starts.
    // Asked again in a few minutes, not at the next of the six-hourly checks.
    onExited: function(exitCode) {
      if (exitCode !== 0 && check.wanted) again.restart()
    }
  }

  Timer {
    id: again
    interval: 5 * 60 * 1000
    onTriggered: check.refresh()
  }

  Timer {
    interval: 6 * 60 * 60 * 1000
    running: check.wanted
    repeat: true
    triggeredOnStart: true
    onTriggered: check.refresh()
  }

  // An update run keeps its state in $XDG_RUNTIME_DIR/nova/update/
  // status.json. Its directory is made first, as a file can be watched only
  // in a directory that is there.
  readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/update"
  property bool runDirMade: false

  onWantedChanged: {
    if (!wanted) again.stop()
    else if (!runDirMade && !mkdir.running) mkdir.running = true
  }

  Process {
    id: mkdir
    command: ["mkdir", "-p", check.runDir]
    onExited: check.runDirMade = true
  }

  WatchedFile {
    path: check.wanted && check.runDirMade ? check.runDir + "/status.json" : ""
    onLoaded: {
      let state = ""
      try {
        state = JSON.parse(text()).state
      } catch (error) {
        return
      }
      // Nova updated, with or without an app that could not be.
      if (state === "done" || state === "problems") check.refresh()
    }
  }
}
