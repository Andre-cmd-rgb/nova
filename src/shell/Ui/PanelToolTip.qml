import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// A tooltip in the theme's [tooltip] colours, for anything in a panel.
// Declared inside the item it explains, with <visible> bound to the
// pointer being over it:
//   PanelToolTip {
//     visible: mouse.containsMouse
//     text: "Forget network"
//   }
// The panel* colours are for a tooltip that must differ from the theme; they
// are named so because ToolTip has a background and a font of its own.
ToolTip {
  id: root

  property color panelForeground: Commons.Color.tooltip.text
  property color panelBackground: Commons.Color.tooltip.background
  property color panelBorder: Commons.Color.tooltip.border
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall

  readonly property var panelBorderSpec: Border.localOrSurfaceSpec("tooltip", "border", panelBorder, Commons.Color.tooltip.border, Style.normalBorderWidth)

  delay: 400
  padding: 0

  background: BorderSurface {
    radius: Style.cornerRadius
    color: root.panelBackground
    borderSpec: root.panelBorderSpec
  }

  contentItem: Text {
    textFormat: Text.PlainText
    text: root.text
    color: root.panelForeground
    font { family: root.fontFamily; pixelSize: root.fontSize }
    topPadding: Border.top(root.panelBorderSpec) + Style.spacing.controlPaddingY
    rightPadding: Border.right(root.panelBorderSpec) + Style.spacing.controlPaddingX
    bottomPadding: Border.bottom(root.panelBorderSpec) + Style.spacing.controlPaddingY
    leftPadding: Border.left(root.panelBorderSpec) + Style.spacing.controlPaddingX
  }
}
