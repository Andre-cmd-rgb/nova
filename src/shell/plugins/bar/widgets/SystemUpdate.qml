import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "nova.system-update"

  property bool updateAvailable: false
  property string tooltip: "Pending Nova Updates"

  function refresh() {
    if (!updateProc.running) updateProc.running = true
  }

  function clear() { updateAvailable = false }

  // Settings runs it, with a bar for how far it is and no terminal.
  function runUpdate() {
    if (root.bar) root.bar.run("nova-settings updates")
  }

  visible: updateAvailable
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: updateProc
    // And a notification, once for each update found.
    command: ["nova-update-check", "--notify"]
    // "available <version>", "apps <name>..." when only Chrome or VS Code is
    // behind, or "current"; nothing when offline, which keeps the badge as it
    // was.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var answer = String(text).trim()
        if (answer.startsWith("available ")) {
          root.tooltip = "Nova " + answer.slice(10) + " is available"
          root.updateAvailable = true
        } else if (answer.startsWith("apps ")) {
          root.tooltip = "App updates are available"
          root.updateAvailable = true
        } else if (answer === "current") {
          root.updateAvailable = false
        }
      }
    }
  }

  // An update Settings ran asks again as it ends, rather than in six hours.
  // Watched once its folder exists: Quickshell sees a file appear in a folder
  // that is there, not in one made after it started looking.
  readonly property string statusDir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/update"
  property bool watching: false

  Process {
    command: ["mkdir", "-p", root.statusDir]
    running: true
    onExited: root.watching = true
  }

  FileView {
    path: root.watching ? root.statusDir + "/status.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        if (JSON.parse(text()).state === "done") root.refresh()
      } catch (e) {
        // Written whole, then moved into place: a bad read is someone else's.
      }
    }
  }

  Timer {
    interval: 21600000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf021"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.tooltip
    onPressed: root.runUpdate()
  }
}
