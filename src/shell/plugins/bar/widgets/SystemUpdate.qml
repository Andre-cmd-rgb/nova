import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A badge while an update waits, a new Nova or app updates, with what it is
// as its tooltip; a click opens Settings on Updates. It asks
// nova-update-check every six hours, and again once an update run says it
// is done. nova-shell nova.system-update refresh asks now, and clear puts
// the badge away until the next answer.
BarWidget {
  id: root
  moduleName: "nova.system-update"

  // What waits, in the tooltip's words; "" while nothing does.
  property string waiting: ""

  function refresh() {
    if (!check.running) check.running = true
  }

  function clear() {
    waiting = ""
  }

  // nova-update-check's answer, a line: "available <version>", "unfinished
  // <version>", "apps <app>...", or "current". Another answer leaves the
  // badge as it is.
  function heard(answer) {
    if (answer.startsWith("available ")) waiting = "Nova " + answer.slice(10) + " is available"
    else if (answer.startsWith("unfinished ")) waiting = "The update to Nova " + answer.slice(11) + " did not finish"
    else if (answer.startsWith("apps ")) waiting = "App updates are available"
    else if (answer === "current") waiting = ""
  }

  visible: waiting !== ""
  implicitWidth: badge.implicitWidth
  implicitHeight: badge.implicitHeight

  Process {
    id: check
    command: ["nova-update-check", "--notify"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.heard(String(text).trim())
    }
  }

  Timer {
    interval: 6 * 60 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // An update run keeps its state in $XDG_RUNTIME_DIR/nova/update/
  // status.json. Its directory is made first, as a file can be watched only
  // in a directory that is there.
  readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/update"
  property string runState: ""

  Process {
    command: ["mkdir", "-p", root.runDir]
    running: true
    onExited: root.runState = root.runDir + "/status.json"
  }

  FileView {
    path: root.runState
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      let state = ""
      try {
        state = JSON.parse(text()).state
      } catch (error) {
        return
      }
      if (state === "done") root.refresh()
    }
  }

  BarIconButton {
    id: badge
    anchors.fill: parent
    bar: root.bar
    text: "\uf021"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.waiting
    onPressed: root.bar?.run("nova-settings updates")
  }
}
