import QtQuick
import Quickshell.Io
import "Readout.js" as Readout

// The Battery page's live readout: what Nova's power governor has set and
// what the computer is doing under it, read every two seconds while the page
// is open. It is `nova power status --json`, the figures `nova power status
// -v` prints, and it hides where the governor does not run.
Section {
  id: root
  title: "RIGHT NOW"
  // `info`, not `data`: `data` is QQuickItem's default property.
  property var info: ({})
  visible: !!info.governor

  Process {
    id: readProc
    command: ["nova-power", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text))
          if (parsed && typeof parsed === "object") root.info = parsed
        } catch (e) {
          // A torn read keeps the last figures for two seconds.
        }
      }
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!readProc.running) readProc.running = true
  }

  Line { label: "Processor"; detail: Readout.processor(root.info) }
  Line { label: "Limits"; detail: Readout.limits(root.info) }
  Line { label: "Fans"; detail: Readout.fans(root.info); visible: detail.length > 0 }
  Line { label: "Draw"; detail: Readout.battery(root.info); visible: detail.length > 0 }

  Caption {
    width: parent.width
    text: "On battery the governor sets the limits to the work, and climbs a tier only for work that lasts. Plugged in it leaves the firmware's."
  }
}
