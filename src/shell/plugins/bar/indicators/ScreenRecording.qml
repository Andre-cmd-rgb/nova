import QtQuick
import qs.Ui

// Lit while gpu-screen-recorder runs (nova-capture-screenrecording starts
// it). A click stops the recording, or with none, opens the menu's choices
// for one. The looking is the indicators' service's (RecorderSearch.qml),
// once for every copy: as the bar comes up, again whenever the recorder asks
// the indicators to (nova-shell nova.indicators refresh), and every few
// seconds while one runs.
BarIndicator {
  id: indicator

  readonly property var search: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("nova.indicators") : null

  ServiceHold {
    service: indicator.search
    holder: indicator
  }

  lit: !!search && search.found
  glyph: "\u{F0EC2}"
  tipLit: "Stop recording"
  tipDark: "Screen Recording"

  onClicked: if (bar) bar.run(lit ? "nova-capture-screenrecording --stop-recording" : "nova-menu toggle capture.screenrecord")

  Connections {
    target: indicator.host
    ignoreUnknownSignals: true
    function onRefreshRequested() { indicator.search?.look() }
  }
}
