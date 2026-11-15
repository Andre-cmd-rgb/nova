import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

FocusScope {
  id: root

  property bool opened: false
  default property alias content: form.data
  signal canceled()

  visible: opened
  onOpenedChanged: if (opened) forceActiveFocus()
  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Escape) root.canceled()
    else if (!(event.modifiers & Qt.ControlModifier)) return
    event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Commons.Color.background, 0.7)
    MouseArea {
      anchors.fill: parent
      onClicked: root.canceled()
      onWheel: function (wheel) { wheel.accepted = true }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(32), Style.space(420))
      height: form.implicitHeight + inset.top + inset.bottom
      padding: Style.space(22)
      color: Commons.Color.background
      frame: Border.flat(Commons.Color.accent, Style.normalBorderWidth)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: form
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: card.inset.left
        anchors.rightMargin: card.inset.right
        anchors.topMargin: card.inset.top
        spacing: Style.space(12)
      }
    }
  }
}
