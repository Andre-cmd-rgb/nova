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
      height: form.implicitHeight + contentTopInset + contentBottomInset
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
