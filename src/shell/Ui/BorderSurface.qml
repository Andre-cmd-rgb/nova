import QtQuick
import qs.Commons

// A Rectangle bordered by a Border spec ({ color, widths, gradient }). A
// border of one colour and one width all round is the Rectangle's own, which
// costs nothing; a gradient, or sides of different widths, is a BorderOverlay
// laid over the Rectangle, made only for a spec that needs it. Content goes
// inside the content insets: each side's border and its padding together.
Rectangle {
  id: surface

  property var borderSpec: Border.none()
  property real padding: 0
  property real topPadding: padding
  property real rightPadding: padding
  property real bottomPadding: padding
  property real leftPadding: padding

  readonly property real borderTop: Border.top(borderSpec)
  readonly property real borderRight: Border.right(borderSpec)
  readonly property real borderBottom: Border.bottom(borderSpec)
  readonly property real borderLeft: Border.left(borderSpec)

  readonly property real contentTopInset: borderTop + topPadding
  readonly property real contentRightInset: borderRight + rightPadding
  readonly property real contentBottomInset: borderBottom + bottomPadding
  readonly property real contentLeftInset: borderLeft + leftPadding

  readonly property bool usesOverlayBorder: Border.needsOverlay(borderSpec)
  // The Rectangle draws the border itself; with the overlay it draws none.
  readonly property bool _ownBorder: Border.canUseNative(borderSpec)

  border.width: _ownBorder ? Border.uniformWidth(borderSpec) : 0
  border.color: _ownBorder ? Border.color(borderSpec) : "transparent"

  Loader {
    anchors.fill: parent
    active: surface.usesOverlayBorder
    sourceComponent: BorderOverlay {
      borderSpec: surface.borderSpec
      radius: surface.radius
    }
  }
}
