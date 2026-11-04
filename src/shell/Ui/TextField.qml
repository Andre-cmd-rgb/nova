import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// A one-line field to type in, in the controls' states. It is Qt Quick
// Controls' TextField underneath, so text, placeholderText, validator,
// accepted() and the rest are as Qt has them; a caller that wants the
// pointer coming and going reads the inherited <hovered>, which a signal of
// that name here would hide. Its face is in the focus state with the focus,
// in hover-cursor under the pointer, else normal, as Toggle's and Dropdown's
// are.
//
// Its height is the font and <verticalPadding>: a dialog's field by default,
// and less padding for a field inside a row (network's passphrase).
TextField {
  id: field

  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color selectionTint: Style.selectionFillFor(foreground, accent)
  property bool password: false
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY

  echoMode: password ? TextInput.Password : TextInput.Normal
  color: foreground
  placeholderTextColor: Qt.darker(foreground, 1.6)
  selectionColor: selectionTint
  selectedTextColor: foreground
  font.family: Style.font.family
  font.pixelSize: Style.font.body

  // The text starts inside the face's border, whichever state draws it.
  topPadding: face.borderTop + verticalPadding
  rightPadding: face.borderRight + horizontalPadding
  bottomPadding: face.borderBottom + verticalPadding
  leftPadding: face.borderLeft + horizontalPadding

  background: ControlFace {
    id: face
    readonly property string _state: field.activeFocus ? "focus" : field.hovered ? "hover-cursor" : "normal"
    tint: field.foreground
    tintAccent: field.accent
    fillState: _state
    edgeState: _state
    radius: Style.cornerRadius
  }
}
