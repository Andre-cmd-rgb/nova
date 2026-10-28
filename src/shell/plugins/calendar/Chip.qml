import QtQuick
import qs.Commons
import qs.Commons as Commons

// One line of an item: an all-day event, a task with its box to tick, or a
// timed event in a month's day. Clicked, it opens; dragged, it is carried by
// the window's drag (Panel.qml) to a day, a time or the tasks with no day.
Item {
  id: chip

  required property var occ
  required property var calendar
  // The day it is shown on: an event over several days moves by as many
  // days as this one is dragged.
  property real day: 0
  // Before the title, muted: a timed event's start, an overdue task's day.
  property string lead: ""

  readonly property var item: occ.item
  readonly property bool isTask: item.kind === "task"
  readonly property bool dragged: calendar.dragging && calendar.dragOcc !== null && calendar.dragOcc.uid === occ.uid &&
    calendar.dragOcc.instance === occ.instance

  width: parent ? parent.width : 0
  height: Style.space(22)
  opacity: dragged ? 0.4 : 1

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: chip.isTask ? (hover.hovered ? Style.hoverFill : "transparent")
      : Qt.alpha(Commons.Color.accent, hover.hovered ? 0.32 : 0.2)
  }

  Row {
    anchors.fill: parent
    anchors.leftMargin: Style.space(4)
    anchors.rightMargin: Style.space(4)
    spacing: Style.space(4)

    // The box to tick, which takes its own click and does not open the task.
    Text {
      id: box
      visible: chip.isTask
      width: Style.space(16)
      anchors.verticalCenter: parent.verticalCenter
      text: chip.item.done ? "󰄵" : "󰄱"
      color: chip.item.done ? Commons.Color.muted : Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.icon
      TapHandler { onTapped: chip.calendar.toggleTask(chip.item) }
    }
    Text {
      visible: chip.lead !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: chip.lead
      color: Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, parent.width - x)
      text: chip.item.title || (chip.isTask ? "Task" : "Event")
      color: chip.item.done ? Commons.Color.muted : Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.strikeout: chip.item.done
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
  }

  HoverHandler { id: hover }

  MouseArea {
    anchors.fill: parent
    anchors.leftMargin: chip.isTask ? box.width + Style.space(6) : 0
    preventStealing: true
    cursorShape: Qt.PointingHandCursor
    property point pressedAt
    onPressed: function (mouse) {
      pressedAt = Qt.point(mouse.x, mouse.y)
      chip.calendar.focusKeys()
    }
    onPositionChanged: function (mouse) {
      if (!chip.calendar.dragging && Math.abs(mouse.x - pressedAt.x) + Math.abs(mouse.y - pressedAt.y) > Style.space(6))
        chip.calendar.beginDrag(chip.occ, chip, Qt.point(pressedAt.x + anchors.leftMargin, pressedAt.y), chip.day)
      if (chip.calendar.dragging) chip.calendar.moveDrag(mapToItem(chip.calendar.content, mouse.x, mouse.y))
    }
    onReleased: {
      if (chip.calendar.dragging) chip.calendar.endDrag()
      else chip.calendar.openItem(chip.occ)
    }
    onCanceled: chip.calendar.cancelDrag()
  }

  // Made again under the pointer when the calendar changes on disk: the
  // release would never come.
  Component.onDestruction: if (calendar.dragSource === chip) calendar.cancelDrag()
}
