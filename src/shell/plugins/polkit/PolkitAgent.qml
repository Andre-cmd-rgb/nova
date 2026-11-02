import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PolkitModel.js" as PolkitModel

// The polkit agent: asks for the password, or the finger, when an app needs
// root. One way at a time: the fingerprint while PAM waits on the reader,
// which it does when /etc/pam.d/polkit-1 has it and the lid is open; the
// password field as soon as PAM asks for a password, at once when the lid
// is shut and Nova's lid check skips the reader.
Item {
  id: root

  // The [polkit] colours of the theme's shell.toml.
  property color accent: Commons.Color.polkit.accent
  property color background: Commons.Color.polkit.background
  property color foreground: Commons.Color.polkit.text
  property color errorColor: Commons.Color.polkit.textError
  property string fontFamily: Style.font.menuFamily
  readonly property int fieldHeight: Math.max(Style.space(42), Style.spacing.controlHeight)
  readonly property int contentMargin: Style.spacing.panelPadding

  // The request's message, as polkit worded it.
  property string message: ""
  property bool responseRequired: false
  property bool responseVisible: false
  // A response went to PAM and has no answer yet.
  property bool submitted: false
  // A wrong password, shown in the error colours for a moment.
  property bool errorFlash: false
  // Answered or cancelled, and fading out: the dialog stays a moment.
  property bool closing: false
  property bool fingerprintConfigured: false
  // Looked at for each request: with the lid shut the reader is out of reach.
  property bool laptopClosed: false
  property int shakeOffset: 0

  readonly property bool dialogVisible: polkitAgent.isActive || closing
  readonly property bool fingerprintMode: fingerprintConfigured && !laptopClosed && dialogVisible
    && !responseRequired && !submitted && !errorFlash
  readonly property int cardHeight: panel.height > 0
    ? Math.min(fieldHeight + contentMargin * 2, panel.height - Style.gapsOut * 2)
    : fieldHeight + contentMargin * 2
  // A field for the password; a square round the sensor for the finger.
  readonly property int cardWidth: fingerprintMode
    ? cardHeight
    : Math.min(Style.space(312), Math.max(Style.space(260), panel.width - Style.gapsOut * 2))

  // The flow's state, copied: the dialog draws from these. A new question
  // from PAM takes the "Checking..." off.
  function sync() {
    var flow = polkitAgent.flow
    if (!flow) return
    message = String(flow.message || "Authentication is needed...")
    responseRequired = !!flow.isResponseRequired
    responseVisible = !!flow.responseVisible
    if (responseRequired) submitted = false
  }

  function begin() {
    closeTimer.stop()
    closing = false
    submitted = false
    passwordInput.text = ""
    if (!lidCheck.running) lidCheck.running = true
    sync()
    Qt.callLater(refocus)
  }

  function clear() {
    message = ""
    responseRequired = false
    responseVisible = false
    submitted = false
    errorFlash = false
    passwordInput.text = ""
  }

  // The keys go to the field, or, with no field, to the card, for Escape.
  function refocus() {
    if (!dialogVisible) return
    if (fingerprintMode) keyCatcher.forceActiveFocus()
    else passwordInput.forceActiveFocus()
  }

  function submit() {
    var flow = polkitAgent.flow
    if (!flow || !flow.isResponseRequired) return
    submitted = true
    errorFlash = false
    flow.submit(passwordInput.text)
    passwordInput.text = ""
    keyCatcher.forceActiveFocus()
  }

  function cancel() {
    var flow = polkitAgent.flow
    passwordInput.text = ""
    submitted = false
    fadeOut()
    if (flow) flow.cancelAuthenticationRequest()
  }

  function fadeOut() {
    closing = true
    closeTimer.restart()
  }

  function failed() {
    submitted = false
    errorFlash = true
    passwordInput.text = ""
    errorTimer.restart()
    shake.restart()
    Qt.callLater(refocus)
  }

  Timer {
    id: closeTimer
    interval: 300
    onTriggered: {
      root.closing = false
      root.clear()
    }
  }

  Timer {
    id: errorTimer
    interval: 1200
    onTriggered: root.errorFlash = false
  }

  SequentialAnimation {
    id: shake
    NumberAnimation { target: root; property: "shakeOffset"; to: -8; duration: 35; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 8; duration: 50; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 0; duration: 55; easing.type: Easing.OutQuad }
  }

  FileView {
    path: "/etc/pam.d/polkit-1"
    watchChanges: true
    printErrors: false
    onLoaded: root.fingerprintConfigured = PolkitModel.fingerprintInPam(text())
    onLoadFailed: root.fingerprintConfigured = false
    onFileChanged: reload()
  }

  Process {
    id: lidCheck
    command: ["bash", "-c", "nova-hw-laptop-closed && echo closed || echo open"]
    stdout: StdioCollector { id: lidState; waitForEnd: true }
    onExited: root.laptopClosed = lidState.text.trim() === "closed"
  }

  PolkitAgent {
    id: polkitAgent
    path: "/org/nova/PolkitAgent"

    onAuthenticationRequestStarted: root.begin()
    onIsActiveChanged: {
      if (isActive) root.sync()
      else if (!root.closing) root.clear()
    }
    onIsRegisteredChanged: {
      if (isRegistered) console.log("nova polkit agent registered")
      else console.warn("nova polkit agent is not registered; another agent may be running")
    }
  }

  Connections {
    target: polkitAgent.flow

    function onIsResponseRequiredChanged() {
      root.sync()
      if (!polkitAgent.flow || !polkitAgent.flow.isResponseRequired) passwordInput.text = ""
      Qt.callLater(root.refocus)
    }
    function onInputPromptChanged() { root.sync() }
    function onResponseVisibleChanged() { root.sync() }
    function onSupplementaryMessageChanged() { root.sync() }
    function onFailedChanged() { root.sync() }
    function onAuthenticationFailed() {
      root.sync()
      root.failed()
    }
    function onAuthenticationSucceeded() { root.fadeOut() }
    function onAuthenticationRequestCancelled() { root.fadeOut() }
  }

  PanelWindow {
    id: panel
    visible: root.dialogVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nova-polkit"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.polkit.scrim
    }

    // A click anywhere gives the keys back to the dialog; it does not cancel.
    MouseArea {
      anchors.fill: parent
      onClicked: root.refocus()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: root.shakeOffset
      width: root.cardWidth
      height: root.cardHeight
      radius: Style.cornerRadius
      color: root.background
      borderSpec: Border.surfaceSpec("polkit", root.errorFlash ? "border-error" : "border",
        root.errorFlash ? Commons.Color.polkit.borderError : Commons.Color.polkit.border,
        Math.max(1, Style.space(2)), "border-alpha")
      padding: root.contentMargin

      MouseArea {
        anchors.fill: parent
        onClicked: root.refocus()
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            root.cancel()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.responseRequired) root.submit()
            event.accepted = true
          }
        }
      }

      // The finger: the sensor's glyph, alone in the square.
      OpticalGlyph {
        anchors.centerIn: parent
        width: Math.round(root.fieldHeight * 0.7)
        height: width
        visible: root.fingerprintMode
        text: "\u{F0237}"
        fontFamily: root.fontFamily
        fontSize: Math.round(root.fieldHeight * 0.7)
        color: root.accent
      }

      // The password: a padlock, and the field.
      Row {
        visible: !root.fingerprintMode
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(14)

        Text {
          width: Style.space(26)
          height: root.fieldHeight
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: ""
          color: root.errorFlash ? root.errorColor : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
        }

        Item {
          width: parent.width - Style.space(40)
          height: root.fieldHeight

          TextInput {
            id: passwordInput
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            activeFocusOnPress: true
            clip: true
            enabled: root.dialogVisible
            readOnly: root.submitted || root.errorFlash
            echoMode: root.responseVisible ? TextInput.Normal : TextInput.Password
            passwordCharacter: "•"
            cursorVisible: activeFocus && !root.submitted && !root.errorFlash
            color: root.errorFlash ? root.errorColor : root.foreground
            selectionColor: Util.alpha(root.accent, 0.45)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            onAccepted: root.submit()
            Keys.onPressed: function (event) {
              if (event.key === Qt.Key_Escape) {
                root.cancel()
                event.accepted = true
              }
            }
          }

          // Where the field is at, while it is empty.
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: passwordInput.text.length === 0
            textFormat: Text.PlainText
            text: root.errorFlash ? "Wrong" : root.submitted ? "Checking..." : "Enter password"
            color: root.errorFlash ? root.errorColor : root.foreground
            opacity: root.errorFlash ? 1 : 0.36
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            elide: Text.ElideRight
          }

          // A cursor of its own in the empty field, where the placeholder
          // would hide TextInput's.
          Rectangle {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(1, Style.space(2))
            height: Style.space(24)
            visible: passwordInput.visible && passwordInput.activeFocus && passwordInput.text.length === 0
              && !root.submitted && !root.errorFlash
            color: root.errorFlash ? root.errorColor : root.foreground
          }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            enabled: passwordInput.visible
            onClicked: passwordInput.forceActiveFocus()
          }
        }
      }
    }

    // What the request is for, above the card.
    Rectangle {
      anchors.horizontalCenter: card.horizontalCenter
      anchors.bottom: card.top
      anchors.bottomMargin: Style.space(10)
      width: Math.min(requestText.implicitWidth + Style.space(24), panel.width - Style.gapsOut * 2)
      height: Style.space(28)
      radius: Style.cornerRadius
      color: root.background

      Text {
        id: requestText
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: PolkitModel.requestLabel(root.message)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideMiddle
      }
    }
  }
}
