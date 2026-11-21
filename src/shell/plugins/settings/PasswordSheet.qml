import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

SettingsSheet {
  id: root

  property alias currentPassword: current.text
  property alias newPassword: next.text
  property alias repeatedPassword: repeated.text
  property bool busy: false
  property string error: ""
  // The helper that makes the change; a test names one that is not there.
  property var helper: ["nova-password-change"]
  signal changed()

  function wipe() {
    current.clear()
    next.clear()
    repeated.clear()
  }

  function open() {
    if (busy) return
    wipe()
    error = ""
    opened = true
    current.forceActiveFocus()
  }

  // Not while the change is being made: stopped halfway, nobody could say
  // which password the account and its keyring have.
  function cancel() {
    if (busy) return
    opened = false
    wipe()
  }

  function submit() {
    if (busy || !opened) return
    if (next.text !== repeated.text) {
      error = "The new passwords are not the same."
      next.clear()
      repeated.clear()
      next.forceActiveFocus()
      return
    }
    if (!current.text || !next.text) {
      error = "Enter all three passwords."
      return
    }
    error = ""
    busy = true
    changeProc.running = true
  }

  function finish(exitCode, output) {
    if (!busy) return
    busy = false
    wipe()
    var result = {}
    try { result = JSON.parse(output) } catch (e) {}
    if (exitCode === 0 && result.ok === true) {
      opened = false
      changed()
    } else {
      error = String(result.error || "Could not change the password.").slice(0, 160)
      current.forceActiveFocus()
    }
  }

  onCanceled: cancel()
  Component.onDestruction: cancel()

  Process {
    id: changeProc
    command: root.helper
    stdinEnabled: true
    onStarted: {
      if (!root.busy) { running = false; return }
      write(current.text + "\0" + next.text + "\0" + repeated.text + "\0")
      root.wipe()
    }
    stdout: StdioCollector { id: result; waitForEnd: true }
    onExited: function (exitCode) { root.finish(exitCode, result.text) }
    // A helper that cannot start is never heard to exit, only to stop
    // running; after an exit, finish has already let the sheet go.
    onRunningChanged: if (!running) root.finish(-1, "")
  }

  Text {
    width: parent.width
    text: "Change Password"
    textFormat: Text.PlainText
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.title
  }
  Secret {
    id: current
    placeholderText: "Current password"
    onAccepted: next.forceActiveFocus()
  }
  Secret {
    id: next
    placeholderText: "New password"
    onAccepted: repeated.forceActiveFocus()
  }
  Secret {
    id: repeated
    placeholderText: "New password again"
    onAccepted: root.submit()
  }
  Text {
    width: parent.width
    visible: root.busy || root.error.length > 0
    text: root.busy ? "Changing…" : root.error
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.error ? Commons.Color.urgent : Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
  Row {
    anchors.right: parent.right
    spacing: Style.space(10)
    Button { text: "Cancel"; bordered: true; tabStop: true; enabled: !root.busy; opacity: enabled ? 1 : 0.5; onClicked: root.cancel() }
    Button { text: "Change"; bordered: true; tabStop: true; enabled: !root.busy; opacity: enabled ? 1 : 0.5; onClicked: root.submit() }
  }

  // A password's field: dots for what is typed, shut while the change runs.
  component Secret: TextField {
    width: parent.width
    echoMode: TextInput.Password
    enabled: !root.busy
  }
}
