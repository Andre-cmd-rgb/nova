import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Mobile Data's page in Settings: the modem's state and its switch, and the
// one way back for a modem kept off since it found no SIM at its first start
// (`nova mobile-data check`).
Column {
  id: root
  spacing: Style.space(22)

  // `nova-mobile-data info`, as an object. Not `state`: that is Item's.
  property var info: ({})
  property bool loaded: false
  property string failure: ""

  readonly property string modem: info.state || ""
  readonly property bool parked: modem === "parked"
  readonly property bool radioOn: ["connected", "connecting", "disconnected", "searching", "noprofile", "starting"].indexOf(modem) >= 0
  readonly property bool busy: actionProc.running

  Component.onCompleted: load()

  function load() {
    if (!infoProc.running) infoProc.running = true
  }

  function run(argv) {
    if (actionProc.running) return
    failure = ""
    actionProc.command = argv
    actionProc.running = true
  }

  function bytes(value) {
    var n = Number(value || 0)
    if (n >= 1e9) return (n / 1e9).toFixed(2) + " GB"
    if (n >= 1e6) return Math.round(n / 1e6) + " MB"
    return Math.round(n / 1e3) + " kB"
  }

  readonly property string summary: {
    switch (modem) {
    case "connected": return "Connected to " + (info.operator || "the network") + (info.tech ? ", on " + info.tech : "") + "."
    case "connecting": return "Connecting…"
    case "disconnected": return "On " + (info.operator || "the network") + ", not connected."
    case "searching": return "Searching for a network…"
    case "starting": return "The modem is starting."
    case "noprofile": return "There is no connection profile yet: nova mobile-data setup <APN> makes one."
    case "nosim": return "There is no SIM in the slot."
    case "locked": return "The SIM is locked, and needs its PIN."
    case "disabled": return "Off."
    default: return ""
    }
  }

  Timer {
    interval: 5000
    repeat: true
    running: !root.busy
    onTriggered: root.load()
  }

  Process {
    id: infoProc
    command: ["nova-mobile-data", "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = {}
        String(text || "").split("\n").forEach(function (line) {
          var at = line.indexOf("=")
          if (at > 0) next[line.slice(0, at)] = line.slice(at + 1)
        })
        if (next.state) {
          root.info = next
          root.loaded = true
        }
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      id: actionErrors
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var message = String(actionErrors.text || "").trim().split("\n").pop().replace(/^mobile-data: /, "")
      if (exitCode !== 0)
        root.failure = message.length > 0 ? message.charAt(0).toUpperCase() + message.slice(1) + "." : "That did not work."
      root.load()
    }
  }

  Caption {
    width: parent.width
    visible: !root.loaded
    text: "Asking the modem…"
  }

  Section {
    visible: root.loaded && root.modem === "absent"
    Caption {
      width: parent.width
      text: "This computer has no mobile broadband modem."
    }
  }

  // Kept off since its first start found no SIM, or nothing to read one with.
  Section {
    visible: root.parked
    Line {
      label: "Mobile Data"
      detail: root.info.parked === "no-modemmanager"
        ? "Off: ModemManager, which reads the SIM, is not installed."
        : "Off: there was no SIM when the modem first started. It stays off, and out of the menu bar, to save power."
      Button {
        text: root.busy ? "Checking…" : root.info.parked === "no-modemmanager" ? "Check Again" : "Check for a SIM"
        bordered: true
        enabled: !root.busy
        onClicked: root.run(["nova-mobile-data", "check"])
      }
    }
    Caption {
      width: parent.width
      text: root.info.parked === "no-modemmanager"
        ? "Install it first, in a terminal: sudo pacman -S modemmanager"
        : "Put the SIM in first. Checking switches the modem on and waits up to a minute and a half for it; with a SIM, mobile data stays on for good."
    }
  }

  Section {
    visible: root.loaded && !root.parked && root.modem !== "absent"
    Toggle {
      width: parent.width
      label: "Mobile Data"
      description: root.busy ? (root.radioOn ? "Turning off…" : "Turning on…") : root.summary
      checked: root.radioOn
      onClicked: if (!root.busy) root.run(["nova-mobile-data", root.radioOn ? "off" : "on"])
    }
  }

  Section {
    title: "CONNECTION"
    visible: root.modem === "connected" || root.modem === "disconnected"
    Repeater {
      model: [
        { label: "Network", value: root.info.operator || "" },
        { label: "Technology", value: root.info.tech || "" },
        { label: "Signal", value: Number(root.info.signal || 0) > 0 ? root.info.signal + "%" : "" },
        { label: "Address", value: root.info.ip || "" },
        { label: "Used this month", value: root.bytes(root.info.used_bytes) + (root.info.next_reset ? ", counted again from " + root.info.next_reset : "") }
      ]
      delegate: Line {
        required property var modelData
        visible: modelData.value.length > 0
        label: modelData.label
        Text {
          text: modelData.value
          color: Commons.Color.foreground
          opacity: 0.75
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          textFormat: Text.PlainText
        }
      }
    }
  }

  Caption {
    width: parent.width
    visible: root.failure.length > 0
    color: Commons.Color.urgent
    opacity: 1
    text: root.failure
  }
}
