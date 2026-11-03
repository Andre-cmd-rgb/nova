import QtQuick
import qs.Commons
import qs.Commons as Commons

// The head of a panel, as wide as its parent: a large icon, then a bold
// title with an outlined <detail> tag at the far end of its line, and under
// them a line of <meta> in small capitals. <trailingControl>, a ToggleSwitch
// or a small button, sits at the very end, and the words leave it room. Every
// part is centred on the head's height.
Item {
  id: hero

  property Component iconComponent: null
  property string title: ""
  property string meta: ""
  property string detail: ""
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

    // The title takes what the tag leaves it and elides. The line is as
    // tall as what it holds even when the title has no room at all.
    Item {
      id: titleLine
      width: parent.width
      height: Math.max(hero.title !== "" ? heading.implicitHeight : 0, hero.detail !== "" ? tag.implicitHeight : 0)
      visible: hero.title !== "" || hero.detail !== ""

      Text {
        id: heading
        width: Math.min(implicitWidth, Math.max(0, titleLine.width - (hero.detail !== "" ? tag.implicitWidth + Style.space(8) : 0)))
        visible: hero.title !== ""
        textFormat: Text.PlainText
        text: hero.title
        color: hero.foreground
        font.family: hero.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      BorderSurface {
        id: tag
        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(heading.width, titleLine.width - implicitWidth)
        visible: hero.detail !== ""
        implicitWidth: tagWord.implicitWidth + Style.space(10)
        implicitHeight: tagWord.implicitHeight + Style.space(4)
        radius: Style.cornerRadius
        color: "transparent"
        borderSpec: Border.controlSpec("normal", hero.foreground, Commons.Color.accent)

        Text {
          id: tagWord
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: hero.detail
          color: hero.dim
          font.family: hero.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
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
