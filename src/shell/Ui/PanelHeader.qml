import QtQuick
import qs.Commons
import qs.Commons as Commons

// The top of a bar panel, across its width: the panel's glyph, large, then
// its title in bold over a <note> in spaced small capitals (the state in a
// few words), and at the far end whatever the panel puts in <end>, a switch
// or a button, which the words leave room for. All of it is centred on the
// header's height.
//
// The glyph is in <glyphColor>, the ink unless the panel warns with it; a
// <dimmed> glyph is at half strength, for a radio that is off or a speaker
// that is muted. <noteOpacity> lets a panel fade the note while it changes.
Item {
  id: header

  property string glyph: ""
  property color glyphColor: ink
  property bool dimmed: false
  property string title: ""
  property string note: ""
  property alias noteOpacity: noteLine.opacity
  property color ink: Commons.Color.foreground
  property string family: Style.font.family
  property alias end: endSlot.data

  readonly property real _endRoom: endSlot.visibleChildren.length > 0 ? endSlot.width + Style.space(12) : 0

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(mark.implicitHeight, words.implicitHeight, endSlot.height)

  Text {
    id: mark
    anchors.verticalCenter: parent.verticalCenter
    text: header.glyph
    textFormat: Text.PlainText
    color: header.dimmed ? Commons.Color.quieter(header.glyphColor, Commons.Color.popups.background, 0.5) : header.glyphColor
    font.family: header.family
    font.pixelSize: Style.font.display
  }

  Column {
    id: words
    anchors.verticalCenter: parent.verticalCenter
    x: mark.width + Style.space(14)
    width: header.width - x - header._endRoom
    spacing: Style.space(2)

    // A title with no room at all still takes its line's height, which the
    // Column would otherwise skip.
    Item {
      width: parent.width
      height: titleText.implicitHeight
      visible: header.title !== ""

      Text {
        id: titleText
        width: Math.min(implicitWidth, Math.max(0, parent.width))
        text: header.title
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: header.ink
        font.family: header.family
        font.pixelSize: Style.font.title
        font.bold: true
      }
    }

    Text {
      id: noteLine
      width: parent.width
      visible: header.note !== ""
      text: header.note.toUpperCase()
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Commons.Color.quieter(header.ink, Commons.Color.popups.background, 0.71)
      font.family: header.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }
  }

  Item {
    id: endSlot
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: childrenRect.width
    height: childrenRect.height
  }
}
