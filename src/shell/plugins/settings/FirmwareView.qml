import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Section {
  id: root
  title: "FIRMWARE"
  property bool monitor: true
  property var state: ({})
  property string failure: ""
  property bool confirmRestart: false
  readonly property var devices: state.devices || []
  readonly property bool busy: launcher.running || state.running === true
  readonly property string statePath: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/firmware.json"

  function readState(text) {
    try {
      var value = JSON.parse(text)
      if (value && typeof value === "object" && !Array.isArray(value)) state = value
    } catch (e) { /* An absent file has no job yet. */ }
  }

  function start(action, ids) {
    if (busy) return
    failure = ""
    confirmRestart = false
    launcher.command = ["nova-firmware-job", action].concat(ids || [])
    launcher.running = true
  }

  function installAll() {
    start("install", devices.filter(function (d) { return d.status === "available" }).map(function (d) { return d.id }))
  }

  Process {
    id: probe
    running: root.monitor
    command: ["nova-firmware-job", "status"]
    stdout: StdioCollector { onStreamFinished: root.readState(text) }
  }
  FileView {
    id: stateFile
    path: root.monitor ? root.statePath : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readState(text())
  }
  // Also covers the first job, before there was a file for FileView to watch.
  Timer { interval: 1000; repeat: true; running: root.monitor; onTriggered: stateFile.reload() }
  Process {
    id: launcher
    stderr: StdioCollector { id: launchError }
    onExited: function (code) {
      if (code !== 0) root.failure = launchError.text.trim() || "Could not start the firmware job."
      stateFile.reload()
    }
  }
  Process { id: reboot; command: ["systemctl", "reboot"] }

  Line {
    label: root.busy ? (root.state.action === "install" ? "Installing…" : "Checking…")
      : (root.state.checked && root.devices.length === 0 ? "Up to Date" : "Device Firmware")
    Row {
      spacing: Style.space(8)
      Button { text: "Check"; bordered: true; enabled: !root.busy; onClicked: root.start("check") }
      Button {
        text: "Install All"
        visible: root.devices.some(function (d) { return d.status === "available" })
        enabled: !root.busy
        bordered: true
        onClicked: root.installAll()
      }
    }
  }
  Repeater {
    model: root.devices
    Column {
      id: deviceRow
      required property var modelData
      width: root.width
      spacing: Style.space(4)
      Line {
        label: deviceRow.modelData.name
        detail: deviceRow.modelData.current + " → " + deviceRow.modelData.version
        Button {
          text: deviceRow.modelData.status === "installed" ? "Installed"
            : (deviceRow.modelData.status === "queued" ? "Waiting" : "Install")
          enabled: !root.busy && deviceRow.modelData.status === "available"
          bordered: true
          onClicked: root.start("install", [deviceRow.modelData.id])
        }
      }
      Caption { width: parent.width; text: deviceRow.modelData.summary }
      Rectangle {
        visible: deviceRow.modelData.status === "installing" || deviceRow.modelData.status === "queued"
        width: parent.width
        height: Style.space(4)
        color: Commons.Color.muted
        Rectangle {
          width: parent.width * deviceRow.modelData.progress / 100
          height: parent.height
          color: Commons.Color.accent
        }
      }
      Caption {
        visible: deviceRow.modelData.status === "installing" || deviceRow.modelData.status === "queued"
        text: deviceRow.modelData.status === "queued" ? "Waiting" : deviceRow.modelData.progress + "%"
      }
    }
  }
  Caption {
    width: parent.width
    visible: text.length > 0
    // The end of fwupdmgr's output, which says what went wrong; Details is
    // not worth a page of it.
    text: root.failure || String(root.state.error || "").trim().split("\n").slice(-3).join("\n").slice(-300)
  }
  Line {
    visible: root.state.reboot === true && !root.busy
    label: "Restart to finish"
    Row {
      spacing: Style.space(8)
      Button {
        text: root.confirmRestart ? "Restart Now" : "Restart…"
        bordered: true
        onClicked: {
          if (root.confirmRestart) reboot.running = true
          else root.confirmRestart = true
        }
      }
      Button { visible: root.confirmRestart; text: "Cancel"; onClicked: root.confirmRestart = false }
    }
  }
}
