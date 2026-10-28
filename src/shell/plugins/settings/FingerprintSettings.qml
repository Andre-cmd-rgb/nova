import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Fingerprints.js" as Fingerprints

Section {
  id: root

  property Item overlayParent: null
  property bool active: visible
  property var enrolled: []
  property int stages: 0
  property bool singleDelete: false
  property string removing: ""
  property string error: ""
  readonly property bool reading: listProc.running || deviceProc.running || stagesProc.running || deleteHelpProc.running
  readonly property bool busy: reading || deleteProc.running

  title: "FINGERPRINT"
  onActiveChanged: if (active) refresh(); else enrollment.cancel()
  Component.onCompleted: if (active) refresh()

  function refresh() {
    if (!active || busy) return
    error = ""
    listProc.running = true
    deviceProc.running = true
    deleteHelpProc.running = true
  }

  function remove() {
    if (!removing || busy) return
    deleteProc.command = Fingerprints.deleteCommand(removing, singleDelete)
    removing = ""
    error = ""
    deleteProc.running = true
  }

  Process {
    id: listProc
    command: ["sh", "-c", 'exec fprintd-list "$(id -un)"']
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: listOutput; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 0) root.enrolled = Fingerprints.enrolled(listOutput.text)
      else root.error = "Could not read fingerprints."
    }
  }
  Process {
    id: deviceProc
    command: ["busctl", "--system", "call", "net.reactivated.Fprint", "/net/reactivated/Fprint/Manager", "net.reactivated.Fprint.Manager", "GetDefaultDevice"]
    stdout: StdioCollector { id: deviceOutput; waitForEnd: true }
    onExited: function (exitCode) {
      var device = exitCode === 0 ? Fingerprints.device(deviceOutput.text) : ""
      root.stages = 0
      if (!device) { root.error = "No fingerprint sensor."; return }
      stagesProc.command = ["busctl", "--system", "get-property", "net.reactivated.Fprint", device, "net.reactivated.Fprint.Device", "num-enroll-stages"]
      stagesProc.running = true
    }
  }
  Process {
    id: stagesProc
    stdout: StdioCollector { id: stagesOutput; waitForEnd: true }
    onExited: function (exitCode) {
      root.stages = exitCode === 0 ? Fingerprints.stages(stagesOutput.text) : 0
      if (root.stages === 0) root.error = "Could not read the sensor."
    }
  }
  Process {
    id: deleteHelpProc
    command: ["fprintd-delete", "--help"]
    environment: ({ LC_ALL: "C" })
    stdout: StdioCollector { id: helpOutput; waitForEnd: true }
    onExited: function (exitCode) { root.singleDelete = exitCode === 0 && /-f\b/.test(helpOutput.text) }
  }
  Process {
    id: deleteProc
    environment: ({ LC_ALL: "C" })
    onExited: function (exitCode) {
      if (exitCode === 0) root.refresh()
      else root.error = "Could not remove the fingerprint."
    }
  }

  Line {
    label: "Unlock with your fingerprint"
    detail: "After the first unlock with your password, which also opens your keyring."
    Button {
      text: root.enrolled.length ? "Add a Finger…" : "Set Up…"
      bordered: true
      enabled: !root.busy && root.stages > 0 && enrollment.available.length > 0
      opacity: enabled ? 1 : 0.5
      onClicked: enrollment.open()
    }
  }
  Repeater {
    model: root.enrolled
    Line {
      required property string modelData
      label: Fingerprints.label(modelData)
      Button {
        text: root.singleDelete ? "Remove…" : "Remove All…"
        bordered: true
        enabled: !root.busy
        opacity: enabled ? 1 : 0.5
        onClicked: root.removing = modelData
      }
    }
  }
  Caption { width: parent.width; visible: root.error.length > 0; text: root.error }

  FingerprintSheet {
    id: enrollment
    parent: root.overlayParent
    anchors.fill: parent
    z: 100
    stages: root.stages
    enrolled: root.enrolled
    onSaved: root.refresh()
  }

  SettingsSheet {
    parent: root.overlayParent
    anchors.fill: parent
    z: 100
    opened: root.removing.length > 0
    onCanceled: root.removing = ""
    Text {
      width: parent.width
      text: root.singleDelete ? "Remove " + Fingerprints.label(root.removing).toLowerCase() + "?" : "Remove all fingerprints?"
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }
    Row {
      anchors.right: parent.right
      spacing: Style.space(10)
      Button { text: "Cancel"; bordered: true; focusable: true; onClicked: root.removing = "" }
      Button { text: "Remove"; bordered: true; focusable: true; onClicked: root.remove() }
    }
  }
}
