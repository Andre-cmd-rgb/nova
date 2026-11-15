import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The device firmware fwupd has updates for, under Nova's own: there only
// while one is found, goes in or waits for a restart. Updates' Check looks
// for it with Nova's, and opening the page does once a boot.
Section {
  id: root
  title: "FIRMWARE"
  property bool monitor: true
  property var state: ({})
  property string failure: ""
  property bool confirmRestart: false
  readonly property var devices: state.devices || []
  readonly property bool busy: launcher.running || state.running === true
  // An install's: a check that fails says nothing, as Nova's own says when
  // the network is down. The end of fwupdmgr's output, which says what went
  // wrong; Details is not worth a page of it.
  readonly property string error: failure !== "" ? failure
    : state.action !== "install" ? ""
    : String(state.error || "").trim().split("\n").slice(-3).join("\n").slice(-300)
  readonly property bool restart: state.reboot === true && !busy
  readonly property bool shown: devices.length > 0 || error !== "" || restart
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

  // Where fwupd is not, Settings leaves it off, and there is nothing to ask.
  function check() {
    if (monitor) start("check")
  }

  Process {
    id: probe
    running: root.monitor
    command: ["nova-firmware-job", "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.readState(text)
        // Its state is in the runtime folder: none yet this boot.
        if (root.state.checked !== true && !root.busy) root.check()
      }
    }
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
      if (code !== 0 && command[1] === "install") root.failure = launchError.text.trim() || "Could not start the firmware job."
      stateFile.reload()
    }
  }
  Process { id: reboot; command: ["systemctl", "reboot"] }

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
    text: root.error
  }
  Line {
    visible: root.restart
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
