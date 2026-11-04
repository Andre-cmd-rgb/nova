import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// A tooltip in the theme's [tooltip] colours and border, for anything in a
// panel. It goes inside the item it explains, shown while the pointer is
// over that item:
//   PanelToolTip {
//     visible: pointer.containsMouse
//     text: "Forget network"
//   }
// The words sit the controls' padding inside the border. A <square> one
// (Button's) has no rounded corners and, where [tooltip] gives no border
// width, a border of at least a pixel.
ToolTip {
  id: tip

  property string fontFamily: Style.font.family
  property bool square: false

  readonly property var _edge: Border.surfaceSpec("tooltip", "border", Commons.Color.tooltip.border,
    Math.max(square ? 1 : 0, Style.normalBorderWidth))

  delay: 400
  topPadding: Border.top(_edge) + Style.spacing.controlPaddingY
  rightPadding: Border.right(_edge) + Style.spacing.controlPaddingX
  bottomPadding: Border.bottom(_edge) + Style.spacing.controlPaddingY
  leftPadding: Border.left(_edge) + Style.spacing.controlPaddingX

  background: BorderSurface {
    radius: tip.square ? 0 : Style.cornerRadius
    color: Commons.Color.tooltip.background
    borderSpec: tip._edge
  }

  contentItem: Text {
    text: tip.text
    textFormat: Text.PlainText
    color: Commons.Color.tooltip.text
    font.family: tip.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
