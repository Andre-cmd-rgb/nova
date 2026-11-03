import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A badge while an update waits: Nova's, or only an app's (Chrome, VS Code).
// nova-update-check answers every six hours, again as an update Settings ran
// ends, and on nova-shell nova.system-update refresh; a click opens the
// updates in Settings.
BarWidget {
  id: root
  moduleName: "nova.system-update"

  property bool updateAvailable: false
  property string tooltip: "Pending Nova Updates"

  function refresh() {
    if (!check.running) check.running = true
  }

  function clear() { updateAvailable = false }

  // Its answer, one line: "available <version>", "apps <name>...", or
  // "current". Nothing when offline, which leaves the badge as it was.
  function answered(line) {
    if (line.startsWith("available ")) {
      tooltip = "Nova " + line.slice(10) + " is available"
      updateAvailable = true
    } else if (line.startsWith("apps ")) {
      tooltip = "App updates are available"
      updateAvailable = true
    } else if (line === "current") {
      updateAvailable = false
    }
  }

  visible: updateAvailable
  implicitWidth: badge.implicitWidth
  implicitHeight: badge.implicitHeight

  // --notify: a notification as well, once for each update it finds.
  Process {
    id: check
    command: ["nova-update-check", "--notify"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.answered(String(text).trim())
    }
  }

  Timer {
    interval: 6 * 60 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Settings writes status.json as its update runs. Quickshell sees a file
  // appear only in a folder that was there when it began to look, so the
  // folder is made first.
  readonly property string statusDir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/update"
  property bool statusDirMade: false

  Process {
    command: ["mkdir", "-p", root.statusDir]
    running: true
    onExited: root.statusDirMade = true
  }

  FileView {
    path: root.statusDirMade ? root.statusDir + "/status.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        if (JSON.parse(text()).state === "done") root.refresh()
      } catch (e) {
        // Settings writes it whole and moves it into place: one that does
        // not parse is not its, and is ignored.
      }
    }
  }

  BarIconButton {
    id: badge
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.tooltip
    onPressed: if (root.bar) root.bar.run("nova-settings updates")
  }
}
