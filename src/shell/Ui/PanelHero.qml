import QtQuick
import qs.Commons
import qs.Commons as Commons

// The head of a panel, as wide as its parent: a large icon, then a bold
// title, and under it a line of <meta> in small capitals. <trailingControl>,
// a ToggleSwitch or a small button, sits at the very end, and the words leave
// it room. Every part is centred on the head's height.
Item {
  id: hero

  property Component iconComponent: null
  property string title: ""
  property string meta: ""
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property real iconOpacity: 1.0
  property alias metaOpacity: metaLine.opacity
  property Component trailingControl: null

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property real trailingInset: trailing.item && trailing.item.visible ? trailing.width + Style.space(12) : 0

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(icon.implicitHeight, words.implicitHeight, trailing.implicitHeight)

  Loader {
    id: icon
    anchors.verticalCenter: parent.verticalCenter
    opacity: hero.iconOpacity
    sourceComponent: hero.iconComponent
  }

  Column {
    id: words
    anchors.verticalCenter: parent.verticalCenter
    x: icon.width + Style.space(14)
    width: hero.width - x - hero.trailingInset
    spacing: Style.space(2)

    // The title elides. Its line is as tall as the title even when the
    // title has no room at all, which the Column would pass over.
    Item {
      id: titleLine
      width: parent.width
      height: heading.implicitHeight
      visible: hero.title !== ""

      Text {
        id: heading
        width: Math.min(implicitWidth, Math.max(0, titleLine.width))
        textFormat: Text.PlainText
        text: hero.title
        color: hero.foreground
        font.family: hero.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }
    }

    Text {
      id: metaLine
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      text: hero.meta.toUpperCase()
      color: hero.dim
      font.family: hero.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
      elide: Text.ElideRight
    }
  }

  Loader {
    id: trailing
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    sourceComponent: hero.trailingControl
  }
}
