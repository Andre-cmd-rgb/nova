import QtQuick
import Quickshell.Io
import qs.Ui

// Whether a screen recording runs (gpu-screen-recorder, which
// nova-capture-screenrecording starts), looked for once for every copy of
// the screen recording indicator (../indicators/ScreenRecording.qml), each
// screen's and each row's, which hold it: as the first comes, whenever the
// recorder asks the indicators to (nova-shell nova.indicators refresh), and
// every few seconds while one is found, as a recorder that ends by itself
// (killed, out of memory, the disk full) asks nothing.
BarWidgetService {
  id: recorder

  // What the search found when it last looked.
  property bool found: false
  // Asked while it looked: it looks once more after, as the recorder may
  // have started or stopped after it did.
  property bool askedAgain: false

  // Asked by several in a turn (a copy in each row, on each screen), it
  // looks once.
  function look() {
    Qt.callLater(recorder.lookNow)
  }

  function lookNow() {
    if (!wanted) return
    if (search.running) askedAgain = true
    else search.running = true
  }

  onWantedChanged: if (wanted) look()

  Process {
    id: search
    command: ["nova-session-pgrep", "-f", "^gpu-screen-recorder"]
    onExited: function(exitCode) {
      recorder.found = exitCode === 0
      if (!recorder.askedAgain) return
      recorder.askedAgain = false
      running = true
    }
  }

  Timer {
    interval: 4000
    repeat: true
    running: recorder.wanted && recorder.found
    onTriggered: recorder.look()
  }
}
