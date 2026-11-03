import QtQuick
import Quickshell.Io
import qs.Ui

// Lit while gpu-screen-recorder runs, which nova-capture-screenrecording
// starts; a click stops it, or opens the menu's recording choices. Looked for
// as the bar comes up and whenever the recorder asks the indicators to
// refresh (nova-shell nova.indicators refresh).
BarIndicator {
  id: indicator

  property bool recording: false

  active: recording
  activeText: "󰻂"
  activeTooltipText: "Stop recording"
  inactiveTooltipText: "Screen Recording"

  function refresh() {
    if (bar && !recorder.running) recorder.running = true
  }

  onBarChanged: refresh()
  Component.onCompleted: refresh()

  onPressed: {
    if (bar) bar.run(recording ? "nova-capture-screenrecording --stop-recording" : "nova-menu toggle capture.screenrecord")
  }

  Connections {
    target: indicator.indicatorHost
    ignoreUnknownSignals: true
    function onRefreshRequested() { indicator.refresh() }
  }

  Process {
    id: recorder
    command: ["pgrep", "--quiet", "-f", "^gpu-screen-recorder"]
    onExited: function(exitCode) { indicator.recording = exitCode === 0 }
  }
}
