import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A calendar's name and colour, one of the theme's; a subscription is also
// ended here.
Sheet {
  id: sheet

  required property var calendar

  readonly property var store: calendar.store
  property var entry: null
  readonly property var current: entry && store ? store.entry(entry.id) || entry : entry
  property bool confirming: false
  readonly property var colors: ["accent", "red", "orange", "yellow", "green", "cyan", "blue", "magenta"]

  cardWidth: Style.space(420)
  onCanceled: done()

  function edit(c) {
    entry = c
    confirming = false
    name.text = c.name
    opened = true
    Qt.callLater(function () { name.forceActiveFocus() })
  }

  function done() {
    var typed = name.text.trim()
    if (current && typed && typed !== current.name) store.setCalendar(current.id, "name", typed)
    opened = false
  }

  Keys.onReturnPressed: done()
  Keys.onEnterPressed: done()

  Text {
    width: parent.width
    text: sheet.current ? (sheet.current.kind === "subscription" ? "Subscription" : "Calendar") : ""
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.heading
    font.bold: true
  }

  Row {
    spacing: Style.space(8)
    Text {
      width: Style.space(70)
      anchors.verticalCenter: parent.verticalCenter
      text: "Name"
      color: Commons.Color.mutedText
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    TextField {
      id: name
      width: Style.space(280)
    }
  }

  Row {
    spacing: Style.space(8)
    height: Style.space(30)
    Text {
      width: Style.space(70)
      anchors.verticalCenter: parent.verticalCenter
      text: "Colour"
      color: Commons.Color.mutedText
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Repeater {
      model: sheet.colors

      Rectangle {
        required property string modelData
        readonly property bool chosen: sheet.current !== null && sheet.current.color === modelData
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(24)
        height: width
        radius: width / 2
        color: Commons.Color.hue(modelData)
        border.width: chosen ? Style.space(2) : 0
        border.color: Commons.Color.foreground
        Rectangle {
          anchors.centerIn: parent
          visible: parent.chosen
          width: parent.width - Style.space(8)
          height: width
          radius: width / 2
          color: "transparent"
          border.width: Style.space(2)
          border.color: Commons.Color.background
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: sheet.store.setCalendar(sheet.current.id, "color", parent.modelData)
        }
      }
    }
  }

  Text {
    readonly property string words: sheet.current && sheet.current.kind === "subscription" && sheet.store ? sheet.store.stateWords(sheet.current.id) : ""
    visible: words !== "" || (sheet.current !== null && sheet.current.kind === "subscription")
    width: parent.width
    text: words !== "" ? words : (sheet.current && sheet.current.host ? sheet.current.host : "")
    color: words !== "" ? Commons.Color.urgent : Commons.Color.mutedText
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
  }

  Text {
    visible: sheet.confirming
    width: parent.width
    text: "End this subscription?"
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  Item {
    width: parent.width
    height: doneButton.implicitHeight

    Button {
      visible: sheet.current !== null && sheet.current.kind === "subscription"
      anchors.left: parent.left
      text: sheet.confirming ? "Unsubscribe" : "Unsubscribe…"
      foreground: Commons.Color.urgent
      bordered: true
      selected: sheet.confirming
      onClicked: {
        if (!sheet.confirming) {
          sheet.confirming = true
          return
        }
        sheet.store.remove(sheet.current.id)
        sheet.opened = false
      }
    }
    Row {
      anchors.right: parent.right
      spacing: Style.space(8)
      Button {
        visible: sheet.confirming
        text: "Cancel"
        bordered: true
        onClicked: sheet.confirming = false
      }
      Button {
        id: doneButton
        visible: !sheet.confirming
        text: "Done"
        bordered: true
        selected: true
        onClicked: sheet.done()
      }
    }
  }
}
