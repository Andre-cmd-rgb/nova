import QtQuick
import Quickshell.Io
import qs.Ui

// Lit while gpu-screen-recorder runs (nova-capture-screenrecording starts
// it). A click stops the recording, or with none, opens the menu's choices
// for one. pgrep looks as the bar comes up, and again whenever the
// recorder asks the indicators to (nova-shell nova.indicators refresh).
BarIndicator {
  id: indicator

  property bool recording: false

  function refresh() {
    if (bar && !pgrep.running) pgrep.running = true
  }

  active: recording
  activeText: "\u{F0EC2}"
  activeTooltipText: "Stop recording"
  inactiveTooltipText: "Screen Recording"

  onPressed: {
    if (!bar) return
    bar.run(recording ? "nova-capture-screenrecording --stop-recording" : "nova-menu toggle capture.screenrecord")
  }
  onBarChanged: refresh()
  Component.onCompleted: refresh()

  Process {
    id: pgrep
    command: ["pgrep", "--quiet", "-f", "^gpu-screen-recorder"]
    onExited: function(exitCode) { indicator.recording = exitCode === 0 }
  }

  Connections {
    target: indicator.indicatorHost
    ignoreUnknownSignals: true
    function onRefreshRequested() { indicator.refresh() }
  }
}
