import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Settings → Bluetooth's iPhone notifications: the switch, and while it is on
// how the iPhone is, from what nova-iphone-notifications writes into the
// runtime folder at each change (docs/iphone.md). Pairing is a window of
// three minutes, opened by switching it on with no iPhone paired, or here.
Section {
  id: root

  // Whether it is switched on, as Settings' state has it, whether its
  // service ran then, and whether the radio is on to say anything about.
  property bool on: false
  property bool running: false
  property bool powered: true
  signal command(var argv)

  readonly property string statePath: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/iphone-notifications.json"
  property var live: ({})
  property real now: Date.now() / 1000

  // Whether the service runs: as Settings read it, then as systemd says
  // while there is a doubt (no state, or not running when read). The state
  // file goes with the service however it ends (its unit's ExecStopPost),
  // so that one there is a running service's.
  property bool asked: false
  property bool answered: false
  readonly property bool alive: asked ? answered : running
  onRunningChanged: asked = false
  readonly property bool hasState: typeof live.state === "string" && live.state !== ""

  readonly property string status: !on ? "off" : !alive ? "stopped" : hasState ? live.state : "starting"
  readonly property var phone: (live.phones || [])[0] || null
  readonly property string phoneName: phone && phone.name ? String(phone.name) : "Your iPhone"
  readonly property string computer: String(live.name || "") || "this computer"
  readonly property real secondsLeft: Math.max(0, Number(live.pairingUntil || 0) - now)
  // The iPhones it serves, for the devices' list: they connect by themselves.
  readonly property var addresses: on && alive ? (live.phones || []).map(function (p) { return String(p.address || "") }) : []

  function read(text) {
    try {
      var value = JSON.parse(text)
      live = value && typeof value === "object" && !Array.isArray(value) ? value : ({})
    } catch (e) {
      live = ({})
    }
  }

  function clock(seconds) {
    var whole = Math.ceil(seconds)
    return Math.floor(whole / 60) + ":" + String(whole % 60).padStart(2, "0")
  }

  FileView {
    id: stateFile
    path: root.on ? root.statePath : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.read(text())
    onLoadFailed: root.live = ({})
  }

  Process {
    id: unit
    command: ["systemctl", "--user", "is-active", "--quiet", "nova-iphone-notifications.service"]
    onExited: function (code) {
      root.answered = code === 0
      root.asked = true
    }
  }

  // The countdown, and a file the service has only just written, which a
  // watch set before it was there does not see.
  Timer {
    interval: 1000
    repeat: true
    running: root.on
    triggeredOnStart: true
    onTriggered: {
      root.now = Date.now() / 1000
      stateFile.reload()
      if ((!root.alive || !root.hasState) && !unit.running) unit.running = true
    }
  }

  Toggle {
    width: parent.width
    label: "iPhone notifications"
    checked: root.on
    onClicked: root.command(["nova-notification-iphone", checked ? "off" : "on"])
  }

  Line {
    visible: root.on && root.powered && root.status !== "no-bluetooth" && root.status !== "bluetooth-off"
    label: {
      switch (root.status) {
      case "starting": return "Starting…"
      case "stopped": return "Not running"
      case "no-le": return "Needs Bluetooth Low Energy"
      case "pairing": return "Pair your iPhone"
      case "no-iphone": return "No iPhone"
      default: return root.phoneName
      }
    }
    detail: {
      switch (root.status) {
      case "stopped": return "Switch it off and on to start it again"
      case "pairing": return "On your iPhone, open Settings → Bluetooth and tap “" + root.computer + "”. " + root.clock(root.secondsLeft) + " left"
      case "waiting": return "Not connected"
      case "connecting": return "Connecting…"
      case "not-shared": return "On your iPhone: Settings → Bluetooth → ⓘ → Share System Notifications"
      case "connected": return "Connected"
      default: return ""
      }
    }

    Button {
      visible: root.status === "no-iphone"
      text: "Pair"
      bordered: true
      onClicked: root.command(["nova-notification-iphone", "pair"])
    }
  }
}
