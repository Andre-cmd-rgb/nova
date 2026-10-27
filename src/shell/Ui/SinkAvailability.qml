import QtQuick
import Quickshell.Io

// Which outputs can be chosen, for a list of them on screen: sink name ->
// false for one with nothing plugged in (HDMI, say), and for the speakers a
// speaker tuning stands in front of. Asked when it turns active, then again
// only when PipeWire says a card or the sinks changed (a cable in a jack, a
// tuning applied), not every few seconds.
Item {
  id: root

  property bool active: false
  property var plugged: ({})
  property bool loaded: false

  onActiveChanged: if (active) probe()
  Component.onCompleted: if (active) probe()

  // A change while a probe runs asks again once it ends: that probe may have
  // read the old sinks.
  property bool stale: false

  function probe() {
    if (probeProc.running) stale = true
    else probeProc.running = true
  }

  Process {
    id: probeProc
    command: ["nova-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = {}
        String(text || "").split("\n").forEach(function (line) {
          var parts = line.trim().split("\t")
          if (parts.length >= 2) next[parts[0]] = parts[1] !== "0"
        })
        root.plugged = next
        root.loaded = true
      }
    }
    onExited: {
      if (!root.stale) return
      root.stale = false
      Qt.callLater(root.probe)
    }
  }

  // One change comes as a few events.
  Timer {
    id: settle
    interval: 250
    onTriggered: root.probe()
  }

  // A sink's own changes are mostly its volume, and a port plugged in shows
  // on its card.
  Process {
    command: ["pactl", "subscribe"]
    running: root.active
    stdout: SplitParser {
      onRead: function (line) {
        if (/ on card #|'(new|remove)' on sink #/.test(line)) settle.restart()
      }
    }
  }
}
