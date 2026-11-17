import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// AirDrop's page in Settings: its doorbell. Switched on, Bluetooth listens
// for the user's iPhone, and AirDrop goes on when that iPhone's share sheet
// shows AirDrop and off when the sheet closes (the AirDrop plugin does
// that). The iPhone is learned once, here. The menu's AirDrop row stays
// the way to switch AirDrop on by hand.
Column {
  id: root
  spacing: Style.space(22)

  // Whether the doorbell is switched on, as Settings' state has it.
  property bool bell: false
  signal command(var argv)

  // What the doorbell says while this page is open (`nova airdrop bell watch`).
  property var live: ({ state: "off" })
  property real now: Date.now() / 1000
  readonly property bool listening: live.state === "listening"
  readonly property int phones: Number(live.phones) || 0
  readonly property real learningLeft: Number(live.learning) > 0 ? Math.max(0, Number(live.learning) - now) : 0

  function clock(seconds) {
    var left = Math.ceil(seconds)
    return Math.floor(left / 60) + ":" + String(left % 60).padStart(2, "0")
  }

  Process {
    running: root.bell
    command: ["nova-airdrop", "bell", "watch"]
    stdout: SplitParser {
      onRead: function (line) {
        try {
          var next = JSON.parse(String(line))
          if (next && typeof next.state === "string") root.live = next
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.learningLeft > 0
    onTriggered: root.now = Date.now() / 1000
  }

  Section {
    Toggle {
      width: parent.width
      label: "Let my iPhone turn on AirDrop"
      checked: root.bell
      onClicked: root.command(["nova-airdrop", "bell", checked ? "off" : "on"])
    }
  }

  Section {
    title: "MY IPHONE"
    visible: root.bell

    Line {
      label: root.live.state === "deaf" ? "Not listening"
        : !root.listening ? "Starting…"
        : root.learningLeft > 0 ? "Learning your iPhone"
        : root.phones === 0 ? "No iPhone"
        : root.phones === 1 ? "Your iPhone" : root.phones + " iPhones"
      detail: root.live.state === "deaf" ? String(root.live.why || "")
        : !root.listening ? ""
        : root.learningLeft > 0 ? "On your iPhone nearby: Share, then AirDrop. " + root.clock(root.learningLeft) + " left"
        : root.live.near === true ? "Showing AirDrop now"
        : ""

      Button {
        visible: root.listening && root.learningLeft <= 0
        text: root.phones === 0 ? "Learn" : "Forget"
        bordered: true
        onClicked: root.command(["nova-airdrop", "bell", root.phones === 0 ? "learn" : "forget"])
      }
    }
  }
}
