import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The lock screen, for the lock service and the greeter alike: the
// desktop's background, blurred, under a password field. The holder keeps
// the password and checks it. The field shows it as dots, hands every edit
// back, and says how the last check went.
Item {
  id: view

  property string backgroundPath: ""
  // Raised when a new background lands at the same path, to load it again.
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
  // A key, a click or the pointer moving: the screens should stay on.
  signal wakeRequested()

  // shell.toml's [lock] colours.
  readonly property QtObject colors: Commons.Color.lock
  readonly property bool failed: failureMessage !== ""
  // No cursor while a password is checked or a failure shows.
  readonly property bool cursorWanted: inputEnabled && !authenticatingPassword && !failed
  // The hint, and the failure, at a little over the heading's size; the
  // dots bigger again, a little apart.
  readonly property int textSize: headingTimes(1.125)
  readonly property int dotSize: headingTimes(1.33)
  readonly property int dotSpacing: headingTimes(0.19)

  function headingTimes(factor) {
    return Math.round(Style.font.heading * factor)
  }

  function focusField() {
    field.forceActiveFocus()
  }

  onPasswordTextChanged: field.take(passwordText)
  onInputEnabledChanged: if (inputEnabled) Qt.callLater(focusField)
  Component.onCompleted: {
    field.take(passwordText)
    if (inputEnabled) Qt.callLater(focusField)
  }

  // The background fills the screen, blurred, with a little contrast taken
  // out; until it has loaded, the palette's background shows.
  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background

    Image {
      id: picture
      anchors.fill: parent
      // The version as a query: a new file at the same path is read again
      // instead of coming from the cache.
      source: view.loadBackground && view.backgroundPath ? Util.fileUrl(view.backgroundPath) + "?v=" + view.backgroundVersion : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: picture
      source: picture
      autoPaddingEnabled: false
      blurEnabled: view.loadBackground && picture.status === Image.Ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onPositionChanged: view.wakeRequested()
    onClicked: {
      view.wakeRequested()
      view.focusField()
    }
  }

  // The field's card, in the middle of the screen, its border the failure's
  // colour while a failure shows.
  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: 381
    height: 67
    radius: Style.cornerRadius
    clip: true
    color: view.colors.background
    borderSpec: view.failed
      ? Border.surfaceSpec("lock", "border-error", view.colors.borderError, 3, "border-alpha")
      : Border.surfaceSpec("lock", "border-active", view.colors.borderActive, 3, "border-alpha")

    // Inside the border the field keeps 18 px each side, and as much again
    // as the fingerprint mark takes when there is one, so the dots stay
    // centred and never run under it.
    readonly property real markRoom: view.fingerprintConfigured ? Math.round(mark.implicitWidth + 12) : 0

    TextInput {
      id: field

      // Set while the holder's password is copied in, so it is not handed
      // back as an edit.
      property bool copying: false
      // The dots at full size, wider than the field, are drawn smaller, so
      // every keystroke still shows.
      readonly property real fit: allDots.advanceWidth > 0 ? Math.min(1, (width - 4) / allDots.advanceWidth) : 1
      readonly property bool typed: text.length > 0

      function take(value) {
        if (text === value) return
        copying = true
        text = value
        copying = false
      }

      anchors.fill: parent
      anchors.topMargin: card.borderTop
      anchors.bottomMargin: card.borderBottom
      anchors.leftMargin: card.borderLeft + 18 + card.markRoom
      anchors.rightMargin: card.borderRight + 18 + card.markRoom
      clip: true

      echoMode: TextInput.Password
      passwordCharacter: "●"
      passwordMaskDelay: 0
      // No typing while a password is checked.
      enabled: view.inputEnabled && !view.authenticatingPassword
      readOnly: view.authenticatingPassword
      activeFocusOnPress: true

      horizontalAlignment: TextInput.AlignHCenter
      verticalAlignment: TextInput.AlignVCenter
      font.family: Style.font.family
      font.pixelSize: typed ? Math.max(1, Math.floor(view.dotSize * fit)) : view.textSize
      font.letterSpacing: typed ? view.dotSpacing * fit : 0
      color: view.colors.text
      selectionColor: view.colors.selection
      selectedTextColor: view.colors.text

      // A cursor only in a field with dots in it. TextInput turns it on
      // itself as it takes focus, and only a change of what this reads turns
      // it off again, so it reads the wish as one value.
      cursorVisible: activeFocus && view.cursorWanted && text.length > 0
      cursorDelegate: Rectangle {
        width: 2
        visible: field.cursorVisible
        color: view.colors.text
      }

      // An edit hands the text over; typing again wakes the screens and puts
      // the failure away.
      onTextChanged: {
        if (!copying) view.passwordTextEdited(text)
        if (text === "") return
        view.wakeRequested()
        if (view.failed) view.clearFailureRequested()
      }

      // Return submits what the holder has, and the field starts empty.
      onAccepted: {
        var submitted = view.passwordText
        view.passwordTextEdited("")
        if (submitted !== "") view.submitPassword(submitted)
      }

      // Escape and Ctrl+U empty the field, as a terminal's line does.
      Keys.onPressed: function(event) {
        view.wakeRequested()
        var clears = event.key === Qt.Key_Escape || (event.key === Qt.Key_U && (event.modifiers & Qt.ControlModifier))
        if (!clears) return
        view.passwordTextEdited("")
        event.accepted = true
      }

      TextMetrics {
        id: allDots
        font.family: Style.font.family
        font.pixelSize: view.dotSize
        font.letterSpacing: view.dotSpacing
        text: "●".repeat(field.text.length)
      }
    }

    // In the empty field: "Enter Password", "Checking…" while it is checked,
    // or why the last one failed, in italics.
    Label {
      anchors.fill: field
      visible: !field.typed
      text: view.authenticatingPassword ? "Checking…" : view.failed ? view.failureMessage : "Enter Password"
      textFormat: Text.PlainText
      elide: Text.ElideRight
      font.pixelSize: view.textSize
      font.italic: view.failed && !view.authenticatingPassword
      color: view.authenticatingPassword ? view.colors.text
        : view.failed ? view.colors.textError : view.colors.placeholder
    }

    // With a finger enrolled, the mark inside the right edge says a touch
    // opens the lock too.
    Label {
      id: mark
      objectName: "fingerprintIndicator"
      visible: view.fingerprintConfigured
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: card.borderRight + 18
      text: "\u{F0237}"
      font.pixelSize: Math.round(view.textSize * 1.1)
      color: view.colors.placeholder
    }
  }

  component Label: Text {
    font.family: Style.font.family
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
}
