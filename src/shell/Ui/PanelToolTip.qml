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
// The panel* colours stand in for the theme's where a tooltip must differ;
// ToolTip has a background and a font of its own, hence the prefix. Button's
// tooltip is square (<cornerRadius> 0) and, where [tooltip] gives no border
// width, keeps at least <minimumBorderWidth> of the controls' one.
ToolTip {
  id: tip

  property color panelForeground: Commons.Color.tooltip.text
  property color panelBackground: Commons.Color.tooltip.background
  property color panelBorder: Commons.Color.tooltip.border
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall
  property real cornerRadius: Style.cornerRadius
  property int minimumBorderWidth: 0

  readonly property var panelBorderSpec: Border.localOrSurfaceSpec("tooltip", "border", panelBorder, Commons.Color.tooltip.border,
    Math.max(minimumBorderWidth, Style.normalBorderWidth))

  // The words sit the controls' padding inside the border.
  delay: 400
  topPadding: Border.top(panelBorderSpec) + Style.spacing.controlPaddingY
  rightPadding: Border.right(panelBorderSpec) + Style.spacing.controlPaddingX
  bottomPadding: Border.bottom(panelBorderSpec) + Style.spacing.controlPaddingY
  leftPadding: Border.left(panelBorderSpec) + Style.spacing.controlPaddingX

  background: BorderSurface {
    radius: tip.cornerRadius
    color: tip.panelBackground
    borderSpec: tip.panelBorderSpec
  }

  contentItem: Text {
    textFormat: Text.PlainText
    text: tip.text
    color: tip.panelForeground
    font.family: tip.fontFamily
    font.pixelSize: tip.fontSize
  }
}
