import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// A timed event in the week's hours, beside the ones it overlaps. Clicked,
// it opens; dragged, it goes to another time or day; its bottom edge, where
// it ends on this day, makes it longer or shorter, a quarter of an hour at
// a time.
Rectangle {
  id: box

  // { occ, top, bottom, column, columns }, as Model.dayLayout lays it out.
  required property var modelData
  required property var calendar
  required property real day
  required property int hourHeight
  required property real columnWidth

  readonly property var occ: modelData.occ
  readonly property bool dragged: calendar.dragging && calendar.dragOcc !== null && calendar.dragOcc.uid === occ.uid &&
    calendar.dragOcc.instance === occ.instance
  // Its end, in minutes, while the bottom edge is dragged.
  property int stretch: -1
  readonly property int bottomMinutes: stretch >= 0 ? stretch : modelData.bottom
  readonly property bool endsToday: occ.end <= Model.addDays(day, 1)

  x: modelData.column * columnWidth / modelData.columns + Style.space(1)
  y: modelData.top * hourHeight / 60
  width: columnWidth / modelData.columns - Style.space(4)
  height: Math.max(Style.space(14), (bottomMinutes - modelData.top) * hourHeight / 60 - Style.space(1))
  z: stretch >= 0 ? 5 : 1
  radius: Style.cornerRadius > 0 ? Style.space(4) : 0
  color: Qt.alpha(Commons.Color.accent, hover.hovered || stretch >= 0 ? 0.34 : 0.24)
  opacity: dragged ? 0.4 : 1
  clip: true

  Rectangle {
    width: Style.space(3)
    height: parent.height
    color: Commons.Color.accent
  }

  Column {
    x: Style.space(7)
    y: Style.space(2)
    width: parent.width - Style.space(10)
    spacing: 0

    Text {
      width: parent.width
      text: box.occ.item.title || "Event"
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideRight
      // Two lines where there is room for them.
      wrapMode: box.height > Style.space(52) ? Text.Wrap : Text.NoWrap
      maximumLineCount: 2
      textFormat: Text.PlainText
    }
    Text {
      visible: box.height > Style.space(30)
      width: parent.width
      text: box.calendar.clock(box.occ.start) + "–" + box.calendar.clock(box.stretch >= 0 ? Model.atMinutes(box.day, box.stretch) : box.occ.end) +
        (box.occ.recurring ? "  󰑖" : "")
      color: Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
    Text {
      visible: box.occ.item.location !== "" && box.height > Style.space(62)
      width: parent.width
      text: box.occ.item.location
      color: Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
  }

  HoverHandler { id: hover }

  MouseArea {
    anchors.fill: parent
    anchors.bottomMargin: edge.visible ? edge.height : 0
    preventStealing: true
    cursorShape: Qt.PointingHandCursor
    property point pressedAt
    onPressed: function (mouse) {
      pressedAt = Qt.point(mouse.x, mouse.y)
      box.calendar.focusKeys()
    }
    onPositionChanged: function (mouse) {
      if (!box.calendar.dragging && Math.abs(mouse.x - pressedAt.x) + Math.abs(mouse.y - pressedAt.y) > Style.space(6)) {
        // One from the day before lands by its true start, not where midnight cuts it.
        var before = box.occ.start < box.day ? Math.round((box.day - box.occ.start) / Model.MINUTE) : 0
        box.calendar.beginDrag(box.occ, box, pressedAt, box.day, before)
      }
      if (box.calendar.dragging) box.calendar.moveDrag(mapToItem(box.calendar.content, mouse.x, mouse.y))
    }
    onReleased: {
      if (box.calendar.dragging) box.calendar.endDrag()
      else box.calendar.openItem(box.occ)
    }
    onCanceled: box.calendar.cancelDrag()
  }

  // The bottom edge, which says when it ends.
  MouseArea {
    id: edge
    visible: box.endsToday
    anchors.bottom: parent.bottom
    width: parent.width
    height: Style.space(6)
    preventStealing: true
    cursorShape: Qt.SizeVerCursor
    onPressed: box.calendar.focusKeys()
    onPositionChanged: function (mouse) {
      var y = mapToItem(box.parent, mouse.x, mouse.y).y
      box.stretch = Math.max(box.modelData.top + 15, Math.min(1440, Model.snap(y * 60 / box.hourHeight, 15)))
    }
    onReleased: {
      if (box.stretch < 0) return
      var end = Model.atMinutes(box.day, box.stretch)
      box.stretch = -1
      if (end !== box.occ.end) box.calendar.resizeEvent(box.occ, end)
    }
    onCanceled: box.stretch = -1
  }

  Component.onDestruction: if (calendar.dragSource === box) calendar.cancelDrag()
}
