import QtQuick
import qs.Commons
import qs.Commons as Commons

// A label on the left, a control on the right.
Item {
  id: line
  property string label: ""
  property string detail: ""
  default property alias control: slot.data
  width: parent ? parent.width : 0
  implicitHeight: Math.max(labels.implicitHeight, slot.childrenRect.height)

  Column {
    id: labels
    anchors.left: parent.left
    anchors.right: slot.left
    anchors.rightMargin: Style.space(16)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)
    Text {
      width: parent.width
      text: line.label
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
    Caption {
      width: parent.width
      text: line.detail
      visible: text.length > 0
    }
  }

  Item {
    id: slot
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: childrenRect.width
    height: childrenRect.height
  }
}
