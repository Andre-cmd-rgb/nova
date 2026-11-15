import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Beside the calendar: the tasks it has no day for, and those left undone
// from days gone by. One is dragged from here onto a day or a time; a task
// dragged here has its day taken away.
DropArea {
  id: list

  required property var calendar

  readonly property var items: calendar.store ? calendar.store.items : []
  readonly property var overdue: Model.overdueTasks(items, calendar.today)
  readonly property var undated: Model.undatedTasks(items)

  keys: ["nova-calendar"]
  onDropped: function (drop) { calendar.dropAt("undated", 0, 0) }

  function occOf(task) {
    return { item: task, uid: task.uid, start: task.due === null ? 0 : task.due, end: task.due === null ? 0 : task.due, instance: task.due === null ? 0 : task.due, recurring: false }
  }

  function addTyped() {
    var title = field.text.trim()
    if (title === "") return
    calendar.store.addTask({ title: title, due: null })
    field.text = ""
  }

  Rectangle {
    anchors.fill: parent
    color: list.containsDrag && list.calendar.dragOcc && list.calendar.dragOcc.item.kind === "task" ? Style.hoverFill : Qt.alpha(Commons.Color.foreground, 0.03)
  }

  component Heading: Text {
    width: parent.width
    topPadding: Style.space(10)
    bottomPadding: Style.space(4)
    color: Commons.Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
    font.bold: true
  }

  Column {
    id: top
    x: Style.space(12)
    y: Style.space(14)
    width: parent.width - Style.space(24)
    spacing: Style.space(8)

    Text {
      text: "Tasks"
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    TextField {
      id: field
      width: parent.width
      placeholderText: "Add a task"
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      onAccepted: list.addTyped()
      Keys.onEscapePressed: function (event) {
        text = ""
        list.calendar.focusKeys()
        event.accepted = true
      }
    }
  }

  Flickable {
    id: scroll
    anchors.top: top.bottom
    anchors.bottom: parent.bottom
    x: top.x
    width: top.width
    contentHeight: rows.implicitHeight + Style.space(12)
    boundsBehavior: Flickable.StopAtBounds
    clip: true

    Column {
      id: rows
      width: parent.width
      spacing: Style.space(2)

      Heading {
        visible: list.overdue.length > 0
        text: "OVERDUE"
      }
      Repeater {
        model: list.overdue

        Chip {
          required property var modelData
          occ: list.occOf(modelData)
          calendar: list.calendar
          day: Model.dayStart(modelData.due)
          lead: Qt.formatDate(new Date(modelData.due), "d MMM")
        }
      }

      Heading {
        text: "NO DAY"
      }
      Repeater {
        model: list.undated

        Chip {
          required property var modelData
          occ: list.occOf(modelData)
          calendar: list.calendar
        }
      }
      Text {
        visible: list.undated.length === 0
        width: parent.width
        topPadding: Style.space(2)
        text: "Tasks for no day in particular, or dragged here off one."
        color: Commons.Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
    }
  }

  TouchpadScroll {
    anchors.fill: scroll
    flickable: scroll
  }
}
