import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The clock panel's month (Panel.qml): six weeks, so the panel is as tall in
// any month, with the ISO week numbers down the left past a gutter and the
// days' names over the columns. The W over the week numbers switches the
// day weeks start on; its tooltip names the day, as nothing else says what
// it does.
//
// Today is outlined, as a filled cell would shout in so quiet a grid, and
// the day chosen is tinted. With Nova's calendar on, a day with something
// on it has a dot, a click on a day chooses it, and a double click opens
// the calendar there.
Row {
  id: grid

  required property var panel

  readonly property color ink: panel.ink
  readonly property int dayWidth: Style.space(52)
  readonly property int dayHeight: Style.space(34)
  readonly property int headHeight: Style.space(16)
  readonly property int lineGap: Style.space(3)
  // Days are named in English, as all of Nova's text is; the day weeks start
  // on is the region's custom, not a word.
  readonly property var english: Qt.locale("en_US")

  spacing: Style.space(2)

  // The W, then the week numbers.
  Column {
    spacing: grid.lineGap

    Rectangle {
      width: Style.space(32)
      height: grid.headHeight
      radius: Style.cornerRadius
      color: startPointer.containsMouse ? Style.hoverFillFor(grid.ink, Commons.Color.accent) : "transparent"

      Heading {
        anchors.centerIn: parent
        text: "W"
        color: startPointer.containsMouse ? Style.hoverStateColor(grid.ink, Commons.Color.accent) : Qt.darker(grid.ink, 1.9)
      }

      MouseArea {
        id: startPointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: grid.panel.clock.toggleWeekStart()
      }

      PanelToolTip {
        visible: startPointer.containsMouse
        text: "Start weeks on " + grid.english.dayName(Model.otherWeekStart(grid.panel.clock.weekStart), Locale.LongFormat)
        fontFamily: grid.panel.family
      }
    }

    Repeater {
      model: grid.panel.weeks

      Text {
        required property var modelData
        width: Style.space(32)
        height: grid.dayHeight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: modelData.week
        color: Qt.darker(grid.ink, 1.9)
        font.family: grid.panel.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // The gutter, with a hairline down it beside the weeks, not the names.
  Item {
    width: Style.space(14)
    height: days.height

    Rectangle {
      x: Math.round((parent.width - width) / 2)
      y: grid.headHeight + grid.lineGap
      width: Style.spacing.hairline
      height: parent.height - y
      color: grid.ink
      opacity: 0.1
    }
  }

  Grid {
    id: days
    columns: 7
    columnSpacing: grid.spacing
    rowSpacing: grid.lineGap

    Repeater {
      model: Model.weekdayOrder(grid.panel.clock.weekStart)

      Heading {
        required property int modelData
        width: grid.dayWidth
        height: grid.headHeight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: String(grid.english.dayName(modelData, Locale.ShortFormat)).toUpperCase()
        color: Qt.darker(grid.ink, 1.5)
      }
    }

    Repeater {
      model: grid.panel.days

      Rectangle {
        id: cell

        required property var modelData
        readonly property string key: modelData.key

        width: grid.dayWidth
        height: grid.dayHeight
        radius: Style.cornerRadius
        color: key === grid.panel.chosen && !modelData.today ? Style.hoverFillFor(grid.ink, Commons.Color.accent) : "transparent"
        border.width: modelData.today ? Style.spacing.hairline : 0
        border.color: Style.normalBorderFor(grid.ink, Commons.Color.accent)

        // Something on the day.
        Rectangle {
          visible: grid.panel.busy[cell.key] === true
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(4)
          width: Style.space(4)
          height: width
          radius: width / 2
          color: Style.selectedStateColor(grid.ink, Commons.Color.accent)
        }

        TapHandler {
          enabled: grid.panel.calendar !== null
          onTapped: grid.panel.choose(cell.key)
          onDoubleTapped: grid.panel.openCalendar(cell.key)
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: cell.modelData.day
          color: !cell.modelData.inMonth ? Qt.darker(grid.ink, 2.2) : cell.modelData.weekend ? Qt.darker(grid.ink, 1.45) : grid.ink
          font.family: grid.panel.family
          font.pixelSize: Style.font.body
          font.bold: cell.modelData.today
        }
      }
    }
  }

  // A column's name, in bold small capitals.
  component Heading: Text {
    textFormat: Text.PlainText
    font.family: grid.panel.family
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
    font.bold: true
  }
}
