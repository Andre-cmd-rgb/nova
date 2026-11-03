import QtQuick
import qs.Commons

// A Rectangle with a border from a Border spec. A flat border of one width
// all round is the Rectangle's own, which costs nothing; a gradient, or
// sides of different widths, is a BorderOverlay drawn over it. Content sits
// inside the content insets: each side's border width plus its padding.
Rectangle {
  id: root

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

  readonly property real contentTopInset: topPadding + borderTop
  readonly property real contentRightInset: rightPadding + borderRight
  readonly property real contentBottomInset: bottomPadding + borderBottom
  readonly property real contentLeftInset: leftPadding + borderLeft

  readonly property bool usesOverlayBorder: Border.needsOverlay(borderSpec)

  border {
    color: Border.canUseNative(borderSpec) ? Border.color(borderSpec) : "transparent"
    width: Border.canUseNative(borderSpec) ? Border.uniformWidth(borderSpec) : 0
  }

  Loader {
    anchors.fill: parent
    active: root.usesOverlayBorder
    sourceComponent: BorderOverlay {
      radius: root.radius
      borderSpec: root.borderSpec
    }
  }
}
