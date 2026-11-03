import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// A one-line text field in the controls' colours and states. It is Qt
// Quick Controls' TextField, so text, placeholderText, validator, accepted()
// and the rest are there as they are. The focus, the pointer and the panel
// cursor (<hasCursor>) take the same states as on Button, Toggle and
// Dropdown. A caller that wants to hear the pointer come and go reads the
// inherited <hovered>; a signal of that name here would hide it.
//
// Its height is the font and <verticalPadding>: a dialog's field by
// default; a field inside a row (network's passphrase) takes less padding to
// fit the row.
TextField {
  id: root

  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color selectionTint: Style.selectionFillFor(foreground, accent)
  property bool password: false
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY
  property bool hasCursor: false

  readonly property bool _focused: activeFocus
  readonly property bool _hot: hovered || hasCursor
  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : _hot ? "hover-cursor" : "normal", foreground, accent)

  echoMode: password ? TextInput.Password : TextInput.Normal
  font.family: Style.font.family
  font.pixelSize: Style.font.body
  color: foreground
  placeholderTextColor: Qt.darker(foreground, 1.6)
  selectionColor: selectionTint
  selectedTextColor: foreground

  topPadding: Border.top(_borderSpec) + verticalPadding
  rightPadding: Border.right(_borderSpec) + horizontalPadding
  bottomPadding: Border.bottom(_borderSpec) + verticalPadding
  leftPadding: Border.left(_borderSpec) + horizontalPadding

  background: BorderSurface {
    radius: Style.cornerRadius
    color: Style.controlFill(root._focused, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
  }
}
