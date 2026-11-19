import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The notes of an item: lines of text, in the kit's text field's frame.
Controls.TextArea {
  id: root

  readonly property bool _hot: hovered
  readonly property var _borderSpec: Border.controlSpec(activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), Commons.Color.foreground, Commons.Color.accent)

  font.family: Style.font.family
  font.pixelSize: Style.font.body
  color: Commons.Color.foreground
  selectionColor: Style.selectionFill
  selectedTextColor: Commons.Color.foreground
  placeholderTextColor: Commons.Color.quieter(Commons.Color.foreground, Commons.Color.background, 0.62)
  wrapMode: TextEdit.Wrap

  leftPadding: Style.spacing.controlPaddingX + Border.left(_borderSpec)
  rightPadding: Style.spacing.controlPaddingX + Border.right(_borderSpec)
  topPadding: Style.spacing.inputPaddingY + Border.top(_borderSpec)
  bottomPadding: Style.spacing.inputPaddingY + Border.bottom(_borderSpec)

  background: BorderSurface {
    color: Style.controlFill(root.activeFocus, root._hot, Commons.Color.foreground, Commons.Color.accent)
    frame: root._borderSpec
    radius: Style.cornerRadius
  }
}
