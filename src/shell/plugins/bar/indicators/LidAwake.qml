import QtQuick
import Quickshell.Io
import qs.Ui

// On while `nova lid-awake` holds the lid: closing it turns the screen off and
// nothing else, which is easy to forget with the laptop in a bag. Laptops only.
BarIndicator {
  id: root

  property bool laptop: false
  property bool held: false

  active: held
  activeText: "󰌢"
  inactiveText: laptop ? "󰌢" : ""
  keepSpace: laptop
  activeTooltipText: "Lid Awake: closing the lid only turns the screen off"
  inactiveTooltipText: "Lid Awake"

  function refresh() {
    if (!root.bar || !root.laptop || heldProc.running) return
    heldProc.running = true
  }

  onBarChanged: refresh()
  Component.onCompleted: laptopProc.running = true

  Connections {
    target: root.indicatorHost
    ignoreUnknownSignals: true
    function onRefreshRequested() { root.refresh() }
  }

  Process {
    id: laptopProc
    command: ["nova-hw-laptop"]
    onExited: function(exitCode) {
      root.laptop = exitCode === 0
      root.refresh()
    }
  }

  Process {
    id: heldProc
    command: ["nova-lid-awake", "armed"]
    onExited: function(exitCode) { root.held = exitCode === 0 }
  }

  onPressed: function() {
    if (root.bar) root.bar.run("nova-lid-awake toggle")
  }
}
