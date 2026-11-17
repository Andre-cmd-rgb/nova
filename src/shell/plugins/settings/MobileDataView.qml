import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Mobile Data's page in Settings: the modem's state and its switch, the SIM's
// PIN while it is locked, the APN when the network did not take the one
// looked up, and the one way back for a modem kept off since it found no SIM
// at its first start (`nova mobile-data check`), which switches the modem on
// and waits up to a minute and a half for it; with a SIM, mobile data stays
// on for good.
Column {
  id: root
  spacing: Style.space(22)

  // `nova-mobile-data info`, as an object. Not `state`: that is Item's.
  property var info: ({})
  property bool loaded: false
  property string failure: ""
  // The network did not take the APN: the switch's `on` said so (exit 3).
  property bool askApn: false
  // What runs after the action running now, if it goes well.
  property var afterwards: null

  readonly property string modem: info.state || ""
  readonly property bool parked: modem === "parked"
  // Not set up yet is off: the switch sets it up.
  readonly property bool radioOn: ["connected", "connecting", "disconnected", "searching", "starting"].indexOf(modem) >= 0
  readonly property bool busy: actionProc.running || pinProc.running

  Component.onCompleted: load()

  function load() {
    if (!infoProc.running) infoProc.running = true
  }

  function run(argv, after) {
    if (busy) return
    failure = ""
    afterwards = after || null
    actionProc.command = argv
    actionProc.running = true
  }

  // The SIM's last try before its PUK: the first Unlock says so, and only
  // the next gives it (`pin --last-try`).
  readonly property bool lastTry: modem === "locked" && info.pin_tries === "1"
  property bool lastTryWarned: false

  // The PIN goes in on the standard input, never in the arguments. The field
  // is emptied as it goes, so that Return after a wrong PIN sends nothing.
  function unlock(pin) {
    if (busy || !/^[0-9]{4,8}$/.test(pin)) return
    if (lastTry && !lastTryWarned) {
      lastTryWarned = true
      return
    }
    failure = ""
    pinProc.command = ["nova-mobile-data", "pin"].concat(lastTry ? ["--last-try"] : [])
    pinProc.secret = pin
    pinField.text = ""
    lastTryWarned = false
    pinProc.running = true
  }

  // A sentence from the helper's last line: "mobile-data: the SIM ..." as
  // "The SIM ....".
  function sentence(text) {
    var message = String(text || "").trim().split("\n").pop().replace(/^mobile-data: /, "")
    return message.length > 0 ? message.charAt(0).toUpperCase() + message.slice(1) + "." : "That did not work."
  }

  function bytes(value) {
    var n = Number(value || 0)
    if (n >= 1e9) return (n / 1e9).toFixed(2) + " GB"
    if (n >= 1e6) return Math.round(n / 1e6) + " MB"
    return Math.round(n / 1e3) + " kB"
  }

  // "2026-12-01" as "Dec 1", as the bar's card has it.
  function day(iso) {
    var d = new Date(String(iso || "") + "T00:00:00")
    return isNaN(d.getTime()) ? "" : Qt.formatDate(d, "MMM d")
  }

  readonly property string summary: {
    // The network, its technology and the rest are in the Connection rows.
    switch (modem) {
    case "connected": return "Connected"
    case "connecting": return "Connecting…"
    case "disconnected": return "Not connected"
    case "searching": return "Searching…"
    case "starting": return "Starting…"
    // Turning it on sets it up, with the APN for the SIM.
    case "noprofile": return "Not set up"
    case "nosim": return "No SIM"
    case "locked": return info.unlock === "sim-puk" ? "SIM blocked" : "SIM locked"
    // Off, and no longer trying: turning it on tries again, and Check for
    // Problems says why.
    case "failed": return info.why === "sim-error" ? "Could not read the SIM." : "Could not start the modem. Try again."
    case "denied": return "The network refused the SIM."
    case "noservice": return "The modem service is not running."
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
      var after = root.afterwards
      root.afterwards = null
      root.askApn = exitCode === 3
      if (exitCode !== 0) root.failure = root.sentence(actionErrors.text)
      else if (after) Qt.callLater(() => root.run(after))
      root.load()
    }
  }

  Process {
    id: pinProc
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(pinProc.secret + "\n")
      pinProc.secret = ""
    }
    stderr: StdioCollector {
      id: pinErrors
      waitForEnd: true
    }
    onExited: function (exitCode) {
      root.askApn = exitCode === 3
      if (exitCode !== 0) root.failure = root.sentence(pinErrors.text)
      root.load()
    }
  }

  Caption {
    width: parent.width
    visible: !root.loaded
    text: "Checking the modem…"
  }

  Section {
    visible: root.loaded && root.modem === "absent"
    Caption {
      width: parent.width
      text: "No modem found"
    }
  }

  // Kept off, and out of the menu bar, to save power, since its first start
  // found no SIM.
  Section {
    visible: root.parked
    Line {
      label: "Mobile Data"
      detail: "No SIM. Insert one, then check."
      Button {
        text: root.busy ? "Checking…" : "Check for a SIM"
        bordered: true
        enabled: !root.busy
        onClicked: root.run(["nova-mobile-data", "check"])
      }
    }
  }

  Section {
    visible: root.loaded && !root.parked && root.modem !== "absent"
    Toggle {
      width: parent.width
      label: "Mobile Data"
      detail: root.busy ? (root.radioOn ? "Turning off…" : "Turning on…") : root.summary
      checked: root.radioOn
      onClicked: if (!root.busy) root.run(["nova-mobile-data", root.radioOn ? "off" : "on"])
    }
  }

  // The SIM's PIN, while it asks for one; after three wrong ones only the
  // carrier's PUK unblocks it, which is no field here.
  Section {
    title: "PIN"
    visible: root.modem === "locked" && root.info.unlock !== "sim-puk"
    Row {
      spacing: Style.space(8)
      TextField {
        id: pinField
        width: Style.space(160)
        echoMode: TextInput.Password
        inputMethodHints: Qt.ImhDigitsOnly
        validator: RegularExpressionValidator { regularExpression: /[0-9]{0,8}/ }
        placeholderText: "SIM PIN"
        enabled: !root.busy
        onAccepted: root.unlock(text)
        onVisibleChanged: {
          text = ""
          root.lastTryWarned = false
        }
      }
      Button {
        text: pinProc.running ? "Unlocking…" : "Unlock"
        bordered: true
        enabled: !root.busy && pinField.text.length >= 4
        onClicked: root.unlock(pinField.text)
      }
    }
    Caption {
      width: parent.width
      visible: Number(root.info.pin_tries || 0) > 0
      color: root.lastTryWarned ? Commons.Color.urgent : Commons.Color.foreground
      opacity: root.lastTryWarned ? 1 : 0.6
      text: root.lastTryWarned ? "Last try: a wrong PIN blocks the SIM. Unlock again to use it."
        : root.lastTry ? "Last try: a wrong PIN blocks the SIM." : root.info.pin_tries + " tries left"
    }
  }

  Section {
    visible: root.modem === "locked" && root.info.unlock === "sim-puk"
    Caption {
      width: parent.width
      text: "Unblock it with the PUK from your carrier."
    }
  }

  // The network did not take the APN looked up for the SIM, or the one
  // given: another, which mobile data is turned on with.
  Section {
    title: "APN"
    visible: root.askApn
    Row {
      spacing: Style.space(8)
      TextField {
        id: apn
        width: Style.space(220)
        placeholderText: "From your carrier"
        enabled: !root.busy
        onAccepted: if (text.trim()) root.run(["nova-mobile-data", "apn", text.trim()], ["nova-mobile-data", "on"])
        onVisibleChanged: text = ""
      }
      Button {
        text: "Connect"
        bordered: true
        enabled: !root.busy && apn.text.trim().length > 0
        onClicked: root.run(["nova-mobile-data", "apn", apn.text.trim()], ["nova-mobile-data", "on"])
      }
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
        { label: "IP address", value: root.info.ip || "" },
        { label: "Used this month", value: root.bytes(root.info.used_bytes) + (root.day(root.info.next_reset) ? "  ·  resets " + root.day(root.info.next_reset) : "") }
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
