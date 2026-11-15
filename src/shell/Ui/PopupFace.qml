import QtQuick
import qs.Commons
import qs.Commons as Commons

// The card BarPopup and PanelSurface show: the popups' background, and
// their border round the content, or a plain one in <edgeColor> when the
// card is given a colour of its own. It fades in and out over 140 ms with
// <shown>. PanelSurface also fades the content alone, while another panel
// takes its place (<contentShown>, <contentFades>).
BorderSurface {
  id: face

  property color edgeColor: Commons.Color.popups.border
  property bool shown: false
  property bool fades: true
  property bool contentShown: true
  property bool contentFades: false

  // What the card adds above and below its content: the padding and the
  // border, top and bottom.
  readonly property real verticalInset: padding * 2 + edge.top + edge.bottom

  default property alias content: inner.children

  padding: Style.spacing.popupPadding
  radius: Style.cornerRadius
  color: Commons.Color.popups.background
  frame: Border.popupSpec(edgeColor, Math.max(1, Style.space(2)))
  opacity: shown ? 1.0 : 0

  Behavior on opacity {
    enabled: face.fades
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }

  Item {
    id: inner
    anchors.fill: parent
    anchors.topMargin: face.inset.top
    anchors.rightMargin: face.inset.right
    anchors.bottomMargin: face.inset.bottom
    anchors.leftMargin: face.inset.left
    opacity: face.contentShown ? 1.0 : 0

    Behavior on opacity {
      enabled: face.contentFades
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
  }
}
