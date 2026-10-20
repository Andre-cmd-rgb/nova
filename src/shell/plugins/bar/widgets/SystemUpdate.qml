import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "nova.system-update"

  property bool updateAvailable: false

  function refresh() {
    if (!updateProc.running) updateProc.running = true
  }

  function clear() { updateAvailable = false }

  function runUpdate() {
    if (root.bar) root.bar.run("nova-launch-floating-terminal-with-presentation nova-update")
  }

  visible: updateAvailable
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "nova.system-update"

    function refresh(): void {
      root.broadcast("refresh")
    }

    function clear(): void {
      root.broadcast("clear")
    }
  }

  Process {
    id: updateProc
    command: ["nova-update-check"]
    // "available <version>" or "current"; nothing when offline, which keeps
    // the badge as it was.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var answer = String(text).trim()
        if (answer.startsWith("available")) root.updateAvailable = true
        else if (answer === "current") root.updateAvailable = false
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
    tooltipText: "Pending Nova Updates"
    onPressed: root.runUpdate()
  }
}
