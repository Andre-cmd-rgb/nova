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
// Button's tooltip is square (<cornerRadius> 0) and, where [tooltip] gives
// no border width, keeps at least <minimumBorderWidth> of the controls' one.
ToolTip {
  id: tip

  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall
  property real cornerRadius: Style.cornerRadius
  property int minimumBorderWidth: 0

  readonly property var panelBorderSpec: Border.surfaceSpec("tooltip", "border", Commons.Color.tooltip.border,
    Math.max(minimumBorderWidth, Style.normalBorderWidth))

  // The words sit the controls' padding inside the border.
  delay: 400
  topPadding: Border.top(panelBorderSpec) + Style.spacing.controlPaddingY
  rightPadding: Border.right(panelBorderSpec) + Style.spacing.controlPaddingX
  bottomPadding: Border.bottom(panelBorderSpec) + Style.spacing.controlPaddingY
  leftPadding: Border.left(panelBorderSpec) + Style.spacing.controlPaddingX

  background: BorderSurface {
    radius: tip.cornerRadius
    color: Commons.Color.tooltip.background
    borderSpec: tip.panelBorderSpec
  }

  contentItem: Text {
    textFormat: Text.PlainText
    text: tip.text
    color: Commons.Color.tooltip.text
    font.family: tip.fontFamily
    font.pixelSize: tip.fontSize
  }
}
