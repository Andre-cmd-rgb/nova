import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// What the search finds (Model.search), over the week or the month: each at
// its next time, or its last, the coming ones first. A click goes to its day
// and opens it.
Item {
  id: results

  required property var calendar
  property string query: ""
  readonly property var found: calendar.store && query.trim() !== "" ? Model.search(calendar.store.items, query, calendar.now) : []

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background
  }
  // The clicks and the wheel are the results', not the calendar's under them.
  MouseArea {
    anchors.fill: parent
    onWheel: function (wheel) { wheel.accepted = true }
  }

  function when(o) {
    if (o.item.kind === "task" && o.item.due === null) return "No day"
    var day = Model.dayStart(o.start)
    var name = day === calendar.today ? "Today" : day === Model.addDays(calendar.today, 1) ? "Tomorrow"
      : Qt.formatDate(new Date(o.start), new Date(o.start).getFullYear() === new Date(calendar.today).getFullYear() ? "ddd d MMM" : "ddd d MMM yyyy")
    return name
  }

  function time(o) {
    if (o.item.kind === "task") return o.item.dueTime ? calendar.clock(o.start) : ""
    return o.item.allDay ? "All day" : calendar.clock(o.start)
  }

  Text {
    visible: results.found.length === 0
    anchors.horizontalCenter: parent.horizontalCenter
    y: Style.space(40)
    text: "No results"
    color: Commons.Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  ListView {
    id: view
    anchors.fill: parent
    anchors.margins: Style.space(12)
    model: results.found
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    spacing: Style.space(2)

    delegate: Item {
      id: row
      required property var modelData
      required property int index
      readonly property bool past: modelData.start > 0 && Math.max(modelData.end, modelData.start + 1) <= results.calendar.now
      width: view.width
      height: Style.space(40)

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius > 0 ? Style.space(4) : 0
        color: hover.hovered ? Style.hoverFill : "transparent"
      }
      HoverHandler { id: hover }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: results.calendar.showResult(row.modelData)
      }
      Rectangle {
        x: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(4)
        height: parent.height - Style.space(14)
        radius: width / 2
        color: results.calendar.colorOf(row.modelData.item)
      }
      Text {
        id: whenText
        x: Style.space(20)
        width: Style.space(140)
        anchors.verticalCenter: parent.verticalCenter
        text: results.when(row.modelData)
        color: row.past ? Commons.Color.muted : Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        textFormat: Text.PlainText
      }
      Text {
        id: timeText
        anchors.left: whenText.right
        width: Style.space(80)
        anchors.verticalCenter: parent.verticalCenter
        text: results.time(row.modelData)
        color: Commons.Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        textFormat: Text.PlainText
      }
      Text {
        anchors.left: timeText.right
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: (row.modelData.item.title || (row.modelData.item.kind === "task" ? "Task" : "Event")) +
          (row.modelData.item.location ? "  ·  " + row.modelData.item.location : "")
        color: row.past ? Commons.Color.muted : Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.strikeout: row.modelData.item.kind === "task" && row.modelData.item.done
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
    }
  }

  TouchpadScroll {
    anchors.fill: view
    flickable: view
  }
}
