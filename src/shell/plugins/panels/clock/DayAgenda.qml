import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// What the day chosen in the clock's panel (Panel.qml) holds, from Nova's
// calendar: its all-day events, its others by their start, then its tasks.
// A task's box ticks the task; a click anywhere else on a row, on Open
// Calendar or on the line saying how many more opens the calendar on the
// day.
Column {
  id: agenda

  required property var panel

  readonly property color ink: panel.ink
  readonly property var entries: panel.agenda
  // The rows shown at most; past them, the last says how many more.
  readonly property int rows: 6
  readonly property bool cut: entries.length > rows
  // An event that began before this is one from the day before.
  readonly property real dayBegins: panel.dayStart(panel.chosen)

  spacing: Style.space(2)

  // What a row starts with: a task's time when it has one; an event's
  // start, "All day", or for one from the day before, its end.
  function lead(entry) {
    const calendar = panel.calendar
    if (entry.item.kind === "task") return entry.item.dueTime ? calendar.clock(entry.start) : ""
    if (entry.item.allDay) return "All day"
    return entry.start < dayBegins ? "…" + calendar.clock(entry.end) : calendar.clock(entry.start)
  }

  function openDay() {
    panel.openCalendar(panel.chosen)
  }

  Rectangle {
    width: parent.width
    height: Style.spacing.hairline
    color: agenda.ink
    opacity: 0.1
  }

  Item {
    width: parent.width
    height: openButton.implicitHeight + Style.space(8)

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: agenda.panel.chosen === agenda.panel.dayKey ? "TODAY" : Qt.formatDate(Model.noonOf(agenda.panel.chosen), "ddd d MMMM").toUpperCase()
      color: Qt.darker(agenda.ink, 1.4)
      font.family: agenda.panel.family
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 1
    }

    Button {
      id: openButton
      anchors.right: parent.right
      anchors.rightMargin: -Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "Open Calendar"
      foreground: agenda.ink
      fontFamily: agenda.panel.family
      fontSize: Style.font.bodySmall
      onClicked: agenda.openDay()
    }
  }

  Text {
    visible: agenda.entries.length === 0
    height: Style.space(24)
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    text: "Nothing on this day"
    color: Qt.darker(agenda.ink, 1.9)
    font.family: agenda.panel.family
    font.pixelSize: Style.font.body
  }

  Repeater {
    model: agenda.cut ? agenda.entries.slice(0, agenda.rows - 1) : agenda.entries

    Entry {}
  }

  Text {
    visible: agenda.cut
    height: Style.space(22)
    leftPadding: Style.space(6)
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    text: "+" + (agenda.entries.length - agenda.rows + 1) + " more"
    color: Qt.darker(agenda.ink, 1.6)
    font.family: agenda.panel.family
    font.pixelSize: Style.font.bodySmall

    TapHandler {
      onTapped: agenda.openDay()
    }
  }

  // One thing the day holds: its time, or a task's box with any time past
  // it, then its title and place.
  component Entry: Rectangle {
    id: entry

    required property var modelData
    readonly property var item: modelData.item
    readonly property bool task: item.kind === "task"
    readonly property bool done: task && item.done
    readonly property color faded: Qt.darker(agenda.ink, 1.9)

    width: agenda.width
    height: Style.space(26)
    radius: Style.cornerRadius
    color: hover.hovered ? Style.hoverFillFor(agenda.ink, Commons.Color.accent) : "transparent"

    HoverHandler {
      id: hover
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: agenda.openDay()
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Item {
        width: Style.space(64)
        height: Style.space(20)

        Text {
          visible: !entry.task || entry.item.dueTime
          anchors.left: parent.left
          anchors.leftMargin: entry.task ? Style.space(24) : 0
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: agenda.lead(entry.modelData)
          color: Qt.darker(agenda.ink, 1.5)
          font.family: agenda.panel.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: entry.task
          anchors.verticalCenter: parent.verticalCenter
          text: entry.done ? "󰄵" : "󰄱"
          color: entry.done ? entry.faded : Style.selectedStateColor(agenda.ink, Commons.Color.accent)
          font.family: agenda.panel.family
          font.pixelSize: Style.font.icon

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            cursorShape: Qt.PointingHandCursor
            onClicked: agenda.panel.calendar.toggleTask(entry.modelData.uid)
          }
        }
      }

      Text {
        width: parent.width - x
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: (entry.item.title || (entry.task ? "Task" : "Event")) + (entry.item.location ? "  ·  " + entry.item.location : "")
        color: entry.done ? entry.faded : agenda.ink
        font.family: agenda.panel.family
        font.pixelSize: Style.font.body
        font.strikeout: entry.done
        elide: Text.ElideRight
      }
    }
  }
}
