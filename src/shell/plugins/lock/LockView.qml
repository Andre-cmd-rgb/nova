import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// What the lock screen and the greeter show: the background, blurred, and a
// password field in the middle. Whoever holds the view (the lock service, the
// greeter) holds the password and checks it; the view shows it as dots, says
// how the check went, and reports each keystroke back.
Item {
  id: root

  property string backgroundPath: ""
  // Raised when the background changes under the same path, to load it again.
  property int backgroundVersion: 0
  property bool loadBackground: true
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property bool inputEnabled: true
  property string passwordText: ""

  signal passwordTextEdited(string password)
  signal submitPassword(string password)
  signal clearFailureRequested()
  // Any key or pointer movement: the screen should stay on.
  signal wakeRequested()

  readonly property bool failed: failureMessage.length > 0
  // No cursor while a password is checked or a failure is shown.
  readonly property bool cursorWanted: inputEnabled && !authenticatingPassword && !failed
  readonly property int textSize: Math.round(Style.font.heading * 1.125)
  readonly property int dotSize: Math.round(Style.font.heading * 1.33)
  readonly property int dotSpacing: Math.round(Style.font.heading * 0.19)
  readonly property int padding: 18
  // The fingerprint mark sits inside the field's right edge; the same room is
  // kept on both sides, so the dots stay centred and never run under it.
  readonly property real markRoom: fingerprintConfigured ? Math.round(fingerprintMark.implicitWidth + 12) : 0
  // A password wider than the field draws smaller dots, so every keystroke
  // still shows.
  readonly property real dotScale: allDots.advanceWidth > 0 ? Math.min(1, (field.width - 4) / allDots.advanceWidth) : 1

  // The field changes the password only through passwordTextEdited; a change
  // from outside (a reset after a failure) is copied in without echoing back.
  property bool copyingIn: false

  function focusField() {
    field.forceActiveFocus()
  }

  function copyPasswordIn() {
    if (field.text === passwordText) return
    copyingIn = true
    field.text = passwordText
    copyingIn = false
  }

  // The path as a file URL, its parts escaped, with the version as a query so
  // a new background at the same path is loaded rather than taken from cache.
  function backgroundUrl() {
    if (!backgroundPath) return ""
    return "file://" + String(backgroundPath).split("/").map(encodeURIComponent).join("/") + "?v=" + backgroundVersion
  }

  onPasswordTextChanged: copyPasswordIn()
  onInputEnabledChanged: if (inputEnabled) Qt.callLater(focusField)
  Component.onCompleted: {
    copyPasswordIn()
    if (inputEnabled) Qt.callLater(focusField)
  }

  // The password's dots at full size, which dotScale fits into the field.
  TextMetrics {
    id: allDots
    font.family: Style.font.family
    font.pixelSize: root.dotSize
    font.letterSpacing: root.dotSpacing
    text: "●".repeat(field.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background

    Image {
      id: background
      anchors.fill: parent
      source: root.loadBackground ? root.backgroundUrl() : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: background
      source: background
      autoPaddingEnabled: false
      blurEnabled: root.loadBackground && background.status === Image.Ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onPositionChanged: root.wakeRequested()
      onClicked: {
        root.wakeRequested()
        root.focusField()
      }
    }

    BorderSurface {
      id: box
      width: 381
      height: 67
      anchors.centerIn: parent
      color: Commons.Color.lock.background
      borderSpec: root.failed
        ? Border.surfaceSpec("lock", "border-error", Commons.Color.lock.borderError, 3, "border-alpha")
        : Border.surfaceSpec("lock", "border-active", Commons.Color.lock.borderActive, 3, "border-alpha")
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: field
        anchors {
          fill: parent
          topMargin: box.borderTop
          bottomMargin: box.borderBottom
          leftMargin: box.borderLeft + root.padding + root.markRoom
          rightMargin: box.borderRight + root.padding + root.markRoom
        }
        horizontalAlignment: TextInput.AlignHCenter
        verticalAlignment: TextInput.AlignVCenter
        clip: true
        activeFocusOnPress: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "●"
        passwordMaskDelay: 0
        color: Commons.Color.lock.text
        selectionColor: Commons.Color.lock.selection
        selectedTextColor: Commons.Color.lock.text
        font.family: Style.font.family
        // Dots once there is a password; the hint's size while it is empty.
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.dotSize * root.dotScale)) : root.textSize
        font.letterSpacing: text.length > 0 ? root.dotSpacing * root.dotScale : 0
        cursorVisible: activeFocus && root.cursorWanted && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Commons.Color.lock.text
          visible: field.cursorVisible
        }

        onTextChanged: {
          if (!root.copyingIn) root.passwordTextEdited(text)
          if (text.length === 0) return
          root.wakeRequested()
          // Typing again puts the failure away.
          if (root.failed) root.clearFailureRequested()
        }

        onAccepted: {
          var password = root.passwordText
          root.passwordTextEdited("")
          if (password.length > 0) root.submitPassword(password)
        }

        // Escape and Ctrl+U clear the field, as in a terminal.
        Keys.onPressed: function(event) {
          root.wakeRequested()
          if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
            root.passwordTextEdited("")
            event.accepted = true
          }
        }
      }

      // In the empty field: the hint, "Checking…" while the password is
      // checked, or why the last one failed.
      Text {
        anchors.fill: field
        visible: field.text.length === 0
        textFormat: Text.PlainText
        text: root.authenticatingPassword ? "Checking…" : root.failed ? root.failureMessage : "Enter Password"
        color: root.authenticatingPassword ? Commons.Color.lock.text : root.failed ? Commons.Color.lock.textError : Commons.Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: root.textSize
        font.italic: !root.authenticatingPassword && root.failed
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      // A fingerprint enrolled: the mark says a touch unlocks too.
      Text {
        id: fingerprintMark
        objectName: "fingerprintIndicator"
        anchors.right: parent.right
        anchors.rightMargin: box.borderRight + root.padding
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: "󰈷"
        color: Commons.Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.textSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
