import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Beside the calendar, on its left: the calendars, the one on this computer
// first, then each account's and the subscriptions, each in its colour and
// shown or hidden by a click. Under an account's name, how its last sync
// went when it did not go well; its settings, and a calendar's, behind the
// button its row shows under the pointer. Add Account at the bottom.
Item {
  id: side

  required property var calendar

  readonly property var store: calendar.store
  readonly property var groups: {
    var list = store ? store.list : []
    var out = [{ key: "local", heading: "On This Computer", account: null, calendars: list.filter(function (c) { return c.kind === "local" }) }]
    ;(store ? store.accounts : []).forEach(function (a) {
      out.push({ key: a.id, heading: a.name, account: a, calendars: list.filter(function (c) { return c.account === a.id }) })
    })
    var subs = list.filter(function (c) { return c.kind === "subscription" })
    if (subs.length) out.push({ key: "subscriptions", heading: "Subscriptions", account: null, calendars: subs })
    return out
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.alpha(Commons.Color.foreground, 0.03)
  }

  Flickable {
    id: scroll
    anchors.top: parent.top
    anchors.bottom: addButton.top
    anchors.bottomMargin: Style.space(8)
    width: parent.width
    contentHeight: column.implicitHeight + Style.space(12)
    boundsBehavior: Flickable.StopAtBounds
    clip: true

    Column {
      id: column
      x: Style.space(10)
      y: Style.space(8)
      width: parent.width - Style.space(20)

      Repeater {
        model: side.groups

        Column {
          id: group
          required property var modelData
          readonly property string words: modelData.account && side.store ? side.store.stateWords(modelData.account.id) : ""
          readonly property var synced: modelData.account && side.store ? side.store.status[modelData.account.id] || null : null
          width: column.width
          bottomPadding: Style.space(6)

          Item {
            width: parent.width
            height: Style.space(30)

            HoverHandler { id: headHover }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              anchors.right: headButtons.left
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(4)
              text: String(group.modelData.heading).toUpperCase()
              color: Commons.Color.mutedText
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
              font.bold: true
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }
            Row {
              id: headButtons
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              Text {
                visible: group.modelData.account !== null && side.store !== null && side.store.syncing
                anchors.verticalCenter: parent.verticalCenter
                text: "󰑓"
                color: Commons.Color.mutedText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Button {
                visible: group.modelData.account !== null
                opacity: headHover.hovered || hot ? 1 : 0
                iconText: "󰇘"
                iconSize: Style.font.caption
                tooltipText: "Account"
                onClicked: side.calendar.manageAccount(group.modelData.account)
              }
            }
          }

          Text {
            visible: group.words !== ""
            width: parent.width
            leftPadding: Style.space(4)
            bottomPadding: Style.space(4)
            text: group.words
            color: group.synced && group.synced.state !== "offline" && group.synced.state !== "ok" ? Commons.Color.urgent : Commons.Color.mutedText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }

          Repeater {
            model: group.modelData.calendars

            Item {
              id: row
              required property var modelData
              readonly property color hue: Commons.Color.hue(modelData.color)
              width: group.width
              height: Style.space(28)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                color: rowHover.hovered ? Style.hoverFill : "transparent"
              }
              HoverHandler { id: rowHover }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: side.store.setCalendar(row.modelData.id, "shown", !row.modelData.shown)
              }

              // Its colour, filled when it is shown.
              Rectangle {
                id: box
                x: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(14)
                height: width
                radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                color: row.modelData.shown ? row.hue : "transparent"
                border.width: Style.space(2)
                border.color: row.hue
                Text {
                  anchors.centerIn: parent
                  visible: row.modelData.shown
                  text: "󰄬"
                  color: Commons.Color.background
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
              Text {
                anchors.left: box.right
                anchors.leftMargin: Style.space(8)
                anchors.right: rowButton.left
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.name
                color: row.modelData.shown ? Commons.Color.foreground : Commons.Color.mutedText
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
              Button {
                id: rowButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                opacity: rowHover.hovered || hot ? 1 : 0
                iconText: "󰇘"
                iconSize: Style.font.caption
                tooltipText: "Calendar"
                onClicked: side.calendar.editCalendar(row.modelData)
              }
            }
          }
        }
      }
    }
  }

  TouchpadScroll {
    anchors.fill: scroll
    flickable: scroll
  }

  Button {
    id: addButton
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(10)
    iconText: "󰐕"
    text: "Add Account"
    fontSize: Style.font.bodySmall
    onClicked: side.calendar.addAccount()
  }
}
