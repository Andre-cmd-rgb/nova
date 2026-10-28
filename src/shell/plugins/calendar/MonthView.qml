import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// A month: six weeks of days, each with what it has on it, as many as fit.
// An item is dragged to another day, keeping its time; a double click on a
// day makes an event on it, and its number opens its week.
Item {
  id: view

  required property var calendar

  readonly property var weeks: calendar.monthDays
  readonly property var occs: calendar.occs
  readonly property real cellWidth: width / 7
  readonly property real cellHeight: (height - header.height) / 6
  readonly property int chipHeight: Style.space(22)
  readonly property int chipGap: Style.space(2)
  readonly property int dayLabelHeight: Style.space(24)
  // The lines a day has room for, one of them kept for "+3 more".
  readonly property int fits: Math.max(1, Math.floor((cellHeight - dayLabelHeight - Style.space(4)) / (chipHeight + chipGap)))

  Row {
    id: header
    height: Style.space(28)

    Repeater {
      model: view.weeks.length ? view.weeks[0] : []

      Text {
        required property var modelData
        width: view.cellWidth
        height: header.height
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: view.calendar.weekdayName(modelData)
        color: Commons.Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
        font.bold: true
      }
    }
  }

  Grid {
    anchors.top: header.bottom
    columns: 7

    Repeater {
      model: [].concat.apply([], view.weeks)

      DropArea {
        id: cell
        required property var modelData
        required property int index
        readonly property real day: modelData
        readonly property bool inMonth: new Date(day).getMonth() === view.calendar.month
        readonly property bool isToday: day === view.calendar.today
        readonly property var list: Model.agenda(view.occs, day)
        readonly property int shown: list.length > view.fits ? view.fits - 1 : list.length

        width: view.cellWidth
        height: view.cellHeight
        keys: ["nova-calendar"]
        onDropped: function (drop) { view.calendar.dropAt("day", day, 0) }

        Rectangle {
          anchors.fill: parent
          color: cell.containsDrag ? Style.hoverFill : (cell.inMonth ? "transparent" : Qt.alpha(Commons.Color.foreground, 0.025))
        }
        Rectangle {
          width: parent.width
          height: 1
          color: Qt.alpha(Commons.Color.foreground, 0.08)
        }
        Rectangle {
          width: 1
          height: parent.height
          visible: cell.index % 7 > 0
          color: Qt.alpha(Commons.Color.foreground, 0.08)
        }

        MouseArea {
          anchors.fill: parent
          onPressed: view.calendar.focusKeys()
          onDoubleClicked: view.calendar.newEvent(cell.day, Model.addDays(cell.day, 1), true)
        }

        // The day's number, which opens its week.
        Rectangle {
          x: Style.space(4)
          y: Style.space(3)
          width: Math.max(dayNumber.implicitWidth + Style.space(10), height)
          height: Style.space(20)
          radius: Style.cornerRadius > 0 ? height / 2 : 0
          color: cell.isToday ? Commons.Color.accent : (numberHover.hovered ? Style.hoverFill : "transparent")

          Text {
            id: dayNumber
            anchors.centerIn: parent
            text: new Date(cell.day).getDate() === 1 ? Qt.formatDate(new Date(cell.day), "d MMM") : new Date(cell.day).getDate()
            color: cell.isToday ? Commons.Color.background : (cell.inMonth ? Commons.Color.foreground : Commons.Color.muted)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: cell.isToday
          }
          HoverHandler { id: numberHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: view.calendar.showDay(cell.day, "week") }
        }

        Column {
          x: Style.space(3)
          y: view.dayLabelHeight
          width: parent.width - Style.space(6)
          spacing: view.chipGap

          Repeater {
            model: cell.list.slice(0, cell.shown)

            Chip {
              required property var modelData
              occ: modelData
              calendar: view.calendar
              day: cell.day
              lead: modelData.item.kind === "event" && !modelData.item.allDay && modelData.start >= cell.day ? view.calendar.clock(modelData.start) : ""
            }
          }
          Text {
            visible: cell.list.length > cell.shown
            height: view.chipHeight
            leftPadding: Style.space(4)
            verticalAlignment: Text.AlignVCenter
            text: "+" + (cell.list.length - cell.shown) + " more"
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            TapHandler { onTapped: view.calendar.showDay(cell.day, "week") }
          }
        }
      }
    }
  }
}
