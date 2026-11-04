import QtQuick
import qs.Commons
import qs.Ui

// A row of the menu's list: its glyph or app icon, its label with the line
// under it, and a › on one that opens a menu. The pointer moving onto it
// takes the cursor; a click does what it is for.
BorderSurface {
  id: row

  required property var menu
  required property var look
  required property int index
  required property string kind
  required property string glyph
  required property string appIcon
  required property string label
  required property string line

  readonly property bool lit: index === menu.cursor
  readonly property color inkNow: lit ? look.cursorInk : look.ink
  // The glyph, the icon and the › stand on the middle of the label's line.
  readonly property real labelMiddle: lines.y + name.y + name.height / 2

  width: ListView.view.width
  height: line ? look.tallRowHeight : look.rowHeight
  radius: look.radius
  color: lit ? look.cursorPaper : "transparent"
  borderSpec: lit ? look.cursorFrame : Border.none()

  Text {
    id: glyph
    visible: row.glyph !== "" && row.kind !== "app"
    x: row.look.cursorLeft + row.look.glyphInset
    y: row.labelMiddle - height / 2
    width: row.look.glyphColumn
    textFormat: Text.PlainText
    text: row.glyph
    color: row.inkNow
    font.family: row.look.font
    font.pixelSize: Style.font.iconLarge
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }

  Image {
    visible: row.kind === "app"
    x: glyph.x + (row.look.glyphColumn - width) / 2
    y: row.labelMiddle - height / 2
    width: Style.font.iconLarge
    height: width
    fillMode: Image.PreserveAspectFit
    // Decoded at the screen's pixels: one decoded at the logical size is
    // blurred when scaled up on a HiDPI screen.
    sourceSize.width: width * Screen.devicePixelRatio
    sourceSize.height: height * Screen.devicePixelRatio
    source: row.kind === "app" && row.menu.apps ? row.menu.apps.iconSource(row.appIcon) : ""
    asynchronous: true
  }

  Column {
    id: lines
    readonly property bool afterGlyph: row.glyph !== "" || row.kind === "app"
    anchors.left: parent.left
    anchors.leftMargin: afterGlyph ? glyph.x + row.look.glyphColumn + row.look.glyphGap : row.look.cursorLeft + row.look.bareInset
    anchors.right: chevron.left
    anchors.rightMargin: row.look.glyphGap
    anchors.verticalCenter: parent.verticalCenter
    spacing: row.look.lineGap

    Text {
      id: name
      width: parent.width
      textFormat: Text.PlainText
      text: row.label
      color: row.inkNow
      font.family: row.look.font
      font.pixelSize: Style.font.heading
      font.weight: Font.Medium
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      visible: row.line !== ""
      textFormat: Text.PlainText
      text: row.line
      color: row.look.ink
      opacity: 0.52
      font.family: row.look.font
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  Text {
    id: chevron
    visible: row.kind === "menu"
    anchors.right: parent.right
    anchors.rightMargin: row.look.cursorRight + row.look.glyphInset
    y: row.labelMiddle - height / 2
    width: row.look.chevronWidth
    textFormat: Text.PlainText
    text: "›"
    color: row.inkNow
    opacity: 0.36
    font.family: row.look.font
    font.pixelSize: Style.font.heading
    font.weight: Font.Normal
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: row.menu.pointAt(row.index, row, { x: pointer.mouseX, y: pointer.mouseY })
    onPositionChanged: function(mouse) { row.menu.pointAt(row.index, row, mouse) }
    onClicked: {
      row.menu.cursor = row.index
      row.menu.take(row.index, true)
    }
  }
}
