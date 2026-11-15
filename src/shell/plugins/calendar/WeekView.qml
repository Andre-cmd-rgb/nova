import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// A week: the days across, their all-day events and tasks along the top, and
// the hours down, the timed events in them as boxes. A box is dragged to
// another time or day, and made longer or shorter by its bottom edge; a drag
// over the empty hours makes a new event as long, and a double click one of
// an hour.
Item {
  id: view

  required property var calendar

  readonly property var days: calendar.days
  readonly property var occs: calendar.occs
  readonly property int hourHeight: Style.space(44)
  readonly property int gutter: Style.space(58)
  readonly property real columnWidth: Math.max(0, (width - gutter) / 7)
  readonly property int chipHeight: Style.space(22)
  readonly property int chipGap: Style.space(2)

  // The all-day row shows three a day, or all of them once asked.
  property bool expanded: false
  readonly property var dayLists: days.map(function (d) { return Model.dayItems(view.occs, d) })
  readonly property int most: dayLists.reduce(function (n, l) { return Math.max(n, l.length) }, 0)
  readonly property int rows: expanded ? most : Math.min(most, 3)

  // Where a drag would land in the hours: its column, and its start.
  // In the hours' own terms, scrolled or not.
  readonly property var dragPos: {
    if (!calendar.dragging) return Qt.point(-1, -1)
    var p = grid.mapFromItem(calendar.content, calendar.dragPoint.x, calendar.dragPoint.y)
    return Qt.point(p.x, p.y + grid.contentY)
  }
  readonly property int dropColumn: {
    if (!calendar.dragging) return -1
    var p = grid.mapFromItem(calendar.content, calendar.dragPoint.x, calendar.dragPoint.y)
    if (p.y < 0 || p.y > grid.height || p.x < gutter || p.x >= width) return -1
    return Math.floor((p.x - gutter) / columnWidth)
  }
  readonly property int dropMinutes: {
    if (dropColumn < 0) return 0
    var top = (dragPos.y - calendar.dragGrab.y) * 60 / hourHeight - calendar.dragBefore
    return Math.max(0, Math.min(1440 - 15, Model.snap(top, 15)))
  }
  readonly property int dropLength: {
    var o = calendar.dragOcc
    if (!o || o.item.kind === "task") return 30
    if (o.item.allDay) return 60
    return Math.max(15, Math.round((o.end - o.start) / Model.MINUTE))
  }

  function minutesAt(y) {
    return Math.max(0, Math.min(1440, y * 60 / hourHeight))
  }

  // Seven in the morning at the top, or, this week, three hours before now.
  function scrollToMorning() {
    var today = days.indexOf(calendar.today)
    var minutes = today >= 0 ? Math.max(7 * 60, Model.minutesInDay(calendar.now) - 3 * 60) : 7 * 60
    grid.contentY = Math.max(0, Math.min(grid.contentHeight - grid.height, minutes * hourHeight / 60))
  }

  Component.onCompleted: Qt.callLater(scrollToMorning)

  // ---- the days

  Row {
    id: header
    x: view.gutter
    height: Style.space(46)

    Repeater {
      model: view.days

      Item {
        id: dayHead
        required property var modelData
        readonly property bool isToday: modelData === view.calendar.today
        width: view.columnWidth
        height: header.height

        Column {
          anchors.centerIn: parent
          spacing: Style.space(1)
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: view.calendar.weekdayName(dayHead.modelData)
            color: dayHead.isToday ? Commons.Color.accent : Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: new Date(dayHead.modelData).getDate()
            color: dayHead.isToday ? Commons.Color.accent : Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: dayHead.isToday
          }
        }
      }
    }
  }

  // ---- all day

  Item {
    id: allDay
    anchors.top: header.bottom
    width: parent.width
    height: Math.max(1, view.rows) * (view.chipHeight + view.chipGap) + Style.space(6) + (expander.visible ? expander.height : 0)
    // Over the hours: a drag here is for a day, not for a time.
    z: 2

    Text {
      width: view.gutter - Style.space(8)
      y: Style.space(4)
      horizontalAlignment: Text.AlignRight
      text: "all-day"
      color: Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Row {
      x: view.gutter
      height: parent.height

      Repeater {
        model: view.days

        DropArea {
          id: cell
          required property var modelData
          required property int index
          readonly property var list: view.dayLists[index] || []
          width: view.columnWidth
          height: allDay.height
          keys: ["nova-calendar"]
          onDropped: function (drop) { view.calendar.dropAt("allday", modelData, 0) }

          Rectangle {
            anchors.fill: parent
            color: cell.containsDrag ? Style.hoverFill : "transparent"
          }
          Rectangle {
            width: 1
            height: parent.height
            color: Qt.alpha(Commons.Color.foreground, 0.08)
          }

          MouseArea {
            anchors.fill: parent
            onPressed: view.calendar.focusKeys()
            onDoubleClicked: view.calendar.newEvent(cell.modelData, Model.addDays(cell.modelData, 1), true)
          }

          Column {
            x: Style.space(3)
            y: Style.space(3)
            width: parent.width - Style.space(6)
            spacing: view.chipGap

            Repeater {
              model: cell.list.slice(0, view.expanded ? cell.list.length : (cell.list.length > 3 ? 2 : 3))

              Chip {
                required property var modelData
                occ: modelData
                calendar: view.calendar
                day: cell.modelData
              }
            }
            Text {
              visible: !view.expanded && cell.list.length > 3
              height: view.chipHeight
              leftPadding: Style.space(4)
              verticalAlignment: Text.AlignVCenter
              text: "+" + (cell.list.length - 2) + " more"
              color: Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              TapHandler { onTapped: view.expanded = true }
            }
          }
        }
      }
    }

    Text {
      id: expander
      visible: view.expanded && view.most > 3
      anchors.bottom: parent.bottom
      x: view.gutter + Style.space(7)
      height: Style.space(18)
      text: "Show less"
      color: Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      TapHandler { onTapped: view.expanded = false }
    }
  }

  Rectangle {
    id: rule
    anchors.top: allDay.bottom
    width: parent.width
    height: 1
    color: Qt.alpha(Commons.Color.foreground, 0.12)
  }

  // ---- the hours

  Flickable {
    id: grid
    anchors.top: rule.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    contentWidth: width
    contentHeight: 24 * view.hourHeight
    boundsBehavior: Flickable.StopAtBounds
    clip: true

    Item {
      id: gridContent
      width: grid.width
      height: grid.contentHeight

      Repeater {
        model: 24

        Item {
          required property int index
          y: index * view.hourHeight
          width: gridContent.width
          height: view.hourHeight

          Text {
            visible: index > 0
            width: view.gutter - Style.space(8)
            y: -height / 2
            horizontalAlignment: Text.AlignRight
            text: view.calendar.hourLabel(index)
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Rectangle {
            x: view.gutter
            width: parent.width - view.gutter
            height: 1
            color: Qt.alpha(Commons.Color.foreground, 0.08)
          }
        }
      }

      Repeater {
        model: view.days

        Item {
          id: column
          required property var modelData
          required property int index
          readonly property real day: modelData
          readonly property bool isToday: day === view.calendar.today
          // A new event dragged out over the empty hours, in minutes.
          property int pickFrom: -1
          property int pickTo: -1
          property int pickStart: 0
          property real pickY: 0

          x: view.gutter + index * view.columnWidth
          width: view.columnWidth
          height: gridContent.height

          Rectangle {
            width: 1
            height: parent.height
            color: Qt.alpha(Commons.Color.foreground, 0.08)
          }

          MouseArea {
            anchors.fill: parent
            preventStealing: true
            onPressed: function (mouse) {
              view.calendar.focusKeys()
              column.pickStart = Math.floor(view.minutesAt(mouse.y) / 15) * 15
              column.pickY = mouse.y
            }
            onPositionChanged: function (mouse) {
              if (column.pickFrom < 0 && Math.abs(mouse.y - column.pickY) < Style.space(6)) return
              var at = view.minutesAt(mouse.y)
              column.pickFrom = Math.min(column.pickStart, Math.floor(at / 15) * 15)
              column.pickTo = Math.max(column.pickStart + 15, Math.ceil(at / 15) * 15)
            }
            onReleased: {
              if (column.pickFrom < 0) return
              view.calendar.newEvent(Model.atMinutes(column.day, column.pickFrom), Model.atMinutes(column.day, column.pickTo), false)
              column.pickFrom = column.pickTo = -1
            }
            onCanceled: column.pickFrom = column.pickTo = -1
            onDoubleClicked: function (mouse) {
              var start = Math.min(1440 - 60, Math.floor(view.minutesAt(mouse.y) / 30) * 30)
              view.calendar.newEvent(Model.atMinutes(column.day, start), Model.atMinutes(column.day, start + 60), false)
            }
          }

          // The new event being dragged out.
          Rectangle {
            visible: column.pickFrom >= 0
            x: Style.space(1)
            width: parent.width - Style.space(4)
            y: column.pickFrom * view.hourHeight / 60
            height: (column.pickTo - column.pickFrom) * view.hourHeight / 60
            radius: Style.cornerRadius > 0 ? Style.space(4) : 0
            color: Qt.alpha(Commons.Color.accent, 0.3)
            Text {
              x: Style.space(6)
              y: Style.space(3)
              text: view.calendar.clock(Model.atMinutes(column.day, column.pickFrom)) + "–" + view.calendar.clock(Model.atMinutes(column.day, column.pickTo))
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: Model.dayLayout(view.occs, column.day)

            EventBox {
              calendar: view.calendar
              day: column.day
              hourHeight: view.hourHeight
              columnWidth: view.columnWidth
            }
          }

          // Where the dragged item would go.
          Rectangle {
            visible: view.dropColumn === column.index
            x: Style.space(1)
            width: parent.width - Style.space(4)
            y: view.dropMinutes * view.hourHeight / 60
            height: Math.max(Style.space(3), Math.min(1440 - view.dropMinutes, view.dropLength) * view.hourHeight / 60)
            radius: Style.cornerRadius > 0 ? Style.space(4) : 0
            color: "transparent"
            border.width: Style.space(2)
            border.color: Commons.Color.accent
            Text {
              x: Style.space(6)
              y: Style.space(3)
              text: view.calendar.clock(Model.atMinutes(column.day, view.dropMinutes))
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // Now.
          Rectangle {
            visible: column.isToday
            y: Model.minutesInDay(view.calendar.now) * view.hourHeight / 60 - height / 2
            width: parent.width
            height: Style.space(2)
            color: Commons.Color.urgent
            Rectangle {
              x: -width / 2
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(8)
              height: width
              radius: width / 2
              color: Commons.Color.urgent
            }
          }
        }
      }
    }
  }

  TouchpadScroll {
    anchors.fill: grid
    flickable: grid
  }

  // The hours a drag can land in: over what is in view of them, not the
  // hours scrolled away under the all-day row.
  Row {
    x: view.gutter
    y: grid.y
    height: grid.height

    Repeater {
      model: view.days

      DropArea {
        required property var modelData
        width: view.columnWidth
        height: grid.height
        keys: ["nova-calendar"]
        onDropped: function (drop) { view.calendar.dropAt("time", modelData, view.dropMinutes) }
      }
    }
  }

  // Near the top or the bottom, a drag scrolls the hours.
  Timer {
    interval: 30
    repeat: true
    running: view.calendar.dragging
    onTriggered: {
      var p = grid.mapFromItem(view.calendar.content, view.calendar.dragPoint.x, view.calendar.dragPoint.y)
      if (p.x < view.gutter || p.x > grid.width) return
      var edge = Style.space(28)
      var step = p.y < edge && p.y > -edge ? -Style.space(10) : (p.y > grid.height - edge && p.y < grid.height + edge ? Style.space(10) : 0)
      if (step !== 0) grid.contentY = Math.max(0, Math.min(grid.contentHeight - grid.height, grid.contentY + step))
    }
  }
}
