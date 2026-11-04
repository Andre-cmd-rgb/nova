import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// A one-line field to type in, with a ControlFace behind it in the
// controls' states: focus while it has the focus, hover-cursor under the
// pointer, normal otherwise, as Toggle's and Dropdown's faces go. It is Qt
// Quick Controls' TextField, so text, placeholderText, validator, accepted()
// and the rest are as Qt has them; a caller that wants the pointer coming
// and going reads the inherited <hovered>, which a signal of that name here
// would hide.
//
// The text starts inside the face's content insets: whatever border the
// state draws, then <horizontalPadding> and <verticalPadding>. A dialog's
// field has the default padding; a field inside a row (network's
// passphrase) asks for less.
TextField {
  id: field

  property color foreground: Commons.Color.foreground
  property bool password: false
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY

  topPadding: face.contentTopInset
  rightPadding: face.contentRightInset
  bottomPadding: face.contentBottomInset
  leftPadding: face.contentLeftInset

  echoMode: password ? TextInput.Password : TextInput.Normal
  font {
    family: Style.font.family
    pixelSize: Style.font.body
  }
  color: foreground
  placeholderTextColor: Qt.darker(foreground, 1.6)
  selectedTextColor: foreground
  selectionColor: Style.selectionFillFor(foreground, Commons.Color.accent)

  background: ControlFace {
    id: face

    readonly property string look: field.activeFocus ? "focus" : field.hovered ? "hover-cursor" : "normal"

    tint: field.foreground
    fillState: look
    edgeState: look
    horizontalPadding: field.horizontalPadding
    verticalPadding: field.verticalPadding
    radius: Style.cornerRadius
  }
}
