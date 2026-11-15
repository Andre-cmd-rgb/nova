import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// A line to type in. It is Qt Quick Controls' TextField, so text,
// placeholderText, echoMode, validator, accepted() and hovered are Qt's; what
// Nova adds is the face behind it, a ControlFace in the state the controls
// share (focus with the focus, hover-cursor under the pointer, else normal),
// and colours worked out from one <tint>.
//
// The text keeps clear of the face's border, whatever the state draws, and
// of <padX> and <padY> inside it: a dialog's field has the defaults, a field
// within a row (network's passphrase) asks for less.
TextField {
  id: field

  property color tint: Commons.Color.foreground
  property real padX: Style.spacing.controlPaddingX
  property real padY: Style.spacing.inputPaddingY

  leftPadding: face.inset.left
  rightPadding: face.inset.right
  topPadding: face.inset.top
  bottomPadding: face.inset.bottom

  font.family: Style.font.family
  font.pixelSize: Style.font.body
  color: tint
  selectedTextColor: tint
  selectionColor: Style.selectionFillFor(tint, Commons.Color.accent)
  placeholderTextColor: Qt.darker(tint, 1.6)

  background: ControlFace {
    id: face

    readonly property string look: field.activeFocus ? "focus" : field.hovered ? "hover-cursor" : "normal"

    tint: field.tint
    fillState: look
    edgeState: look
    padX: field.padX
    padY: field.padY
    radius: Style.cornerRadius
  }
}
