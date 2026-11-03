import QtQuick
import qs.Commons
import qs.Commons as Commons

// The card PopupCard and KeyboardPanel show: the popups' background and
// border round their content, fading in and out over 140 ms with <shown>.
// KeyboardPanel also fades the content alone, while another panel takes its
// place (<contentShown>, <contentFades>).
BorderSurface {
  id: face

  property bool shown: false
  property bool fades: true
  property bool contentShown: true
  property bool contentFades: false

  default property alias content: inner.children

  radius: Style.cornerRadius
  color: Commons.Color.popups.background
  opacity: shown ? 1.0 : 0

  Behavior on opacity {
    enabled: face.fades
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }

  Item {
    id: inner
    anchors.fill: parent
    anchors.topMargin: face.contentTopInset
    anchors.rightMargin: face.contentRightInset
    anchors.bottomMargin: face.contentBottomInset
    anchors.leftMargin: face.contentLeftInset
    opacity: face.contentShown ? 1.0 : 0

    Behavior on opacity {
      enabled: face.contentFades
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
  }
}
