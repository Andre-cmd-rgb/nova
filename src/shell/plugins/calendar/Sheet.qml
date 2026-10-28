import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A card over the window, which the rest waits behind: the editor, and the
// question of which times of a repeating event a change is for.
FocusScope {
  id: root

  property bool opened: false
  property real cardWidth: Style.space(440)
  default property alias content: form.data
  signal canceled()

  anchors.fill: parent
  visible: opened
  z: 20
  // When it opened: the second click of a double click on an item is not one
  // on the backdrop, which would close it again.
  property real openedAt: 0
  onOpenedChanged: if (opened) {
    openedAt = Date.now()
    forceActiveFocus()
  }
  // No key gets past it to the calendar behind, but Tab, which goes from
  // one field to the next.
  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) return
    if (event.key === Qt.Key_Escape) root.canceled()
    event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Commons.Color.background, 0.7)
    MouseArea {
      anchors.fill: parent
      onClicked: if (Date.now() - root.openedAt > 500) root.canceled()
      onWheel: function (wheel) { wheel.accepted = true }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(32), root.cardWidth)
      height: Math.min(parent.height - Style.space(32), form.implicitHeight + contentTopInset + contentBottomInset)
      padding: Style.space(22)
      color: Commons.Color.background
      borderSpec: Border.flat(Commons.Color.accent, Style.normalBorderWidth)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: form
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.topMargin: card.contentTopInset
        spacing: Style.space(12)
      }
    }
  }
}
