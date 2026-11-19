import QtQuick
import Quickshell.Io
import qs.Ui

// Lit while gpu-screen-recorder runs (nova-capture-screenrecording starts
// it). A click stops the recording, or with none, opens the menu's choices
// for one. It looks as the bar comes up, and again whenever the
// recorder asks the indicators to (nova-shell nova.indicators refresh).
BarIndicator {
  id: indicator

  // What the search found when it last looked.
  property bool recorderFound: false
  // Asked while it looked: it looks once more after, as the recorder may
  // have started or stopped after it did.
  property bool askedAgain: false

  function look() {
    if (!bar) return
    if (search.running) askedAgain = true
    else search.running = true
  }

  lit: recorderFound
  glyph: "\u{F0EC2}"
  tipLit: "Stop recording"
  tipDark: "Screen Recording"

  onClicked: if (bar) bar.run(recorderFound ? "nova-capture-screenrecording --stop-recording" : "nova-menu toggle capture.screenrecord")
  onBarChanged: look()
  Component.onCompleted: look()

  Process {
    id: search
    command: ["nova-session-pgrep", "-f", "^gpu-screen-recorder"]
    onExited: function(exitCode) {
      indicator.recorderFound = exitCode === 0
      if (!indicator.askedAgain) return
      indicator.askedAgain = false
      running = true
    }
  }

  // A recorder that ends by itself (killed, out of memory, the disk full)
  // asks nothing: while one is lit, the indicator looks every few seconds.
  Timer {
    interval: 4000
    repeat: true
    running: indicator.recorderFound
    onTriggered: indicator.look()
  }

  Connections {
    target: indicator.host
    ignoreUnknownSignals: true
    function onRefreshRequested() { indicator.look() }
  }
}
