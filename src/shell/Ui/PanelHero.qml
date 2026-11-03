import QtQuick
import qs.Commons
import qs.Commons as Commons

// The head of a panel: a large icon, a bold title with an outlined
// <detail> tag at its end, and under it a line of <meta> in small capitals.
// <trailingControl>, a ToggleSwitch or a small button, sits at the far end,
// centred on the text, which leaves room for it.
Item {
  id: root

  property Component iconComponent: null
  property string title: ""
  property string meta: ""
  property string detail: ""
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property real iconSize: Style.font.display
  property real iconOpacity: 1.0
  property alias metaOpacity: metaLine.opacity
  property Component trailingControl: null

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property real trailingInset: trailing.item && trailing.item.visible ? trailing.width + Style.space(12) : 0

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(icon.implicitHeight, labels.implicitHeight, trailing.implicitHeight)

  Loader {
    id: icon
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    sourceComponent: root.iconComponent
    opacity: root.iconOpacity
  }

  Column {
    id: labels
    anchors.left: icon.right
    anchors.leftMargin: Style.space(14)
    anchors.right: parent.right
    anchors.rightMargin: root.trailingInset
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    // The title takes what the tag leaves it, and elides; a spacer pushes
    // the tag to the end of the line. The line is as tall as what it holds
    // even when the title has no room at all, which a Row would pass over.
    Row {
      width: parent.width
      height: Math.max(root.title !== "" ? titleText.implicitHeight : 0, tag.visible ? tag.implicitHeight : 0)
      visible: root.title !== "" || tag.visible

      Text {
        id: titleText
        width: Math.min(implicitWidth, Math.max(0, parent.width - (tag.visible ? tag.implicitWidth + Style.space(8) : 0)))
        visible: root.title !== ""
        textFormat: Text.PlainText
        text: root.title
        color: root.foreground
        font { family: root.fontFamily; pixelSize: Style.font.title; bold: true }
        elide: Text.ElideRight
      }

      Item {
        width: Math.max(0, parent.width - titleText.width - tag.implicitWidth)
        height: 1
      }

      BorderSurface {
        id: tag
        anchors.verticalCenter: parent.verticalCenter
        visible: root.detail !== ""
        implicitWidth: tagText.implicitWidth + Style.space(10)
        implicitHeight: tagText.implicitHeight + Style.space(4)
        radius: Style.cornerRadius
        color: "transparent"
        borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)

        Text {
          id: tagText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.detail
          color: root.dim
          font { family: root.fontFamily; pixelSize: Style.font.body; bold: true }
        }
      }
    }

    Text {
      id: metaLine
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      text: root.meta.toUpperCase()
      color: root.dim
      font { family: root.fontFamily; pixelSize: Style.font.caption; bold: true; letterSpacing: 1.2 }
      elide: Text.ElideRight
    }
  }

  Loader {
    id: trailing
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    sourceComponent: root.trailingControl
  }
}
