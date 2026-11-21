import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "AirDropModel.js" as Model

// Send with AirDrop: a card over the dimmed screen, in the menu's colours,
// with the iPhones nearby as they appear, one a row. A click on one, or
// Return on the one the arrows moved to, sends it the files (picked): the
// one chosen is kept by its id, so that the list changing under it does not
// move Return to another, and one that goes is not replaced by whichever
// comes to its row. The pointer chooses a row only when it moves onto it,
// not when the list moves a row under a pointer that stays still. One that
// takes AirDrop from its contacts only is listed, dimmed, with what it
// needs. One picked that went before it could be asked brings the window
// back, saying so (went). While there is nobody to send to, it says what
// makes an iPhone show. Escape, Cancel and a click beside the card stop the
// send (dismissed). How the send goes after the pick is said in
// notifications.
PanelWindow {
  id: window

  property bool opened: false
  // What is sent, in a few words.
  property string what: ""
  // The receivers: each an id, a name, and whether it takes AirDrop from this computer.
  property var receivers: []
  // Why Bluetooth cannot wake an iPhone; "" while it does.
  property string bluetooth: ""
  // AirDrop is being switched on for the send.
  property bool starting: false
  // The one picked went before it could be asked: said so ("" for nothing).
  property string went: ""
  // The receiver the arrows, or the pointer, are on: its id, and its row (-1 for none).
  property string chosenId: ""
  readonly property int chosen: {
    for (var i = 0; i < receivers.length; i++) if (receivers[i].id === chosenId) return i
    return -1
  }

  readonly property bool anyone: receivers.some(function (r) { return r.accepts })
  readonly property int rowHeight: Math.max(Style.space(36), Style.font.title + Style.spacing.controlPaddingY * 2)

  signal picked(string id)
  signal dismissed()
  // Settings → Bluetooth, where Bluetooth and its Low Energy are switched on.
  signal bluetoothSettings()

  function pick(at) {
    var receiver = receivers[at]
    if (receiver && receiver.accepts) picked(receiver.id)
  }

  function choose(at) {
    if (at >= 0 && at < receivers.length) chosenId = receivers[at].id
  }

  // The arrows: a row up or down from the one chosen; from none, the first.
  function move(by) {
    choose(chosen < 0 ? 0 : Math.max(0, Math.min(receivers.length - 1, chosen + by)))
  }

  // Return: the one chosen, if there is one.
  function enter() {
    if (chosen >= 0) pick(chosen)
  }

  // Where the pointer was over the rows, in the window, when last seen
  // (null: not since the window opened): a row is chosen by the pointer
  // only when it has moved, as a hover is also said when a row moves under
  // it. The first seen is only where it is.
  property var pointer: null
  function hovered(at, point) {
    var moved = pointer !== null && (point.x !== pointer.x || point.y !== pointer.y)
    pointer = Qt.point(point.x, point.y)
    if (moved) choose(at)
  }

  // Each opening starts on the first row, with the keys; a window made
  // open starts so too.
  function begin() {
    chosenId = ""
    pointer = null
    choose(0)
    keyCatcher.forceActiveFocus()
  }

  onOpenedChanged: if (opened) begin()
  Component.onCompleted: if (opened) begin()
  // The first to show is chosen, until another is.
  onReceiversChanged: if (chosenId === "") choose(0)

  visible: opened
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "nova-airdrop-send"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.menu.scrim
  }

  MouseArea {
    anchors.fill: parent
    onClicked: window.dismissed()
  }

  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: Math.min(Style.space(400), window.width - Style.gapsOut * 2)
    height: card.inset.top + body.implicitHeight + card.inset.bottom
    radius: Style.cornerRadius
    color: Commons.Color.menu.background
    frame: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
    padding: Style.spacing.panelPadding

    MouseArea {
      anchors.fill: parent
      onClicked: {}
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function (event) {
        switch (event.key) {
        case Qt.Key_Escape:
          window.dismissed()
          break
        case Qt.Key_Up:
        case Qt.Key_Backtab:
          window.move(-1)
          break
        case Qt.Key_Down:
        case Qt.Key_Tab:
          window.move(1)
          break
        case Qt.Key_Return:
        case Qt.Key_Enter:
          window.enter()
          break
        default:
          return
        }
        event.accepted = true
      }
    }

    Column {
      id: body
      x: card.inset.left
      y: card.inset.top
      width: card.width - card.inset.left - card.inset.right
      spacing: Style.spacing.md

      Text {
        width: parent.width
        text: "Send " + window.what + " with AirDrop"
        textFormat: Text.PlainText
        elide: Text.ElideMiddle
        color: Commons.Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.heading
      }

      Text {
        width: parent.width
        visible: window.went !== ""
        text: window.went
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Commons.Color.urgent
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }

      Repeater {
        model: window.receivers

        Rectangle {
          id: row
          required property var modelData
          required property int index
          readonly property bool chosen: window.chosen === index

          width: body.width
          height: window.rowHeight
          radius: Style.cornerRadius
          color: chosen ? Commons.Color.menu.selectedBackground : "transparent"
          opacity: modelData.accepts ? 1 : 0.6

          Text {
            id: phone
            x: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "\u{F011C}"
            color: row.chosen ? Commons.Color.menu.selectedText : Commons.Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
          }

          Column {
            anchors.left: phone.right
            anchors.leftMargin: Style.spacing.controlGap
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter

            Text {
              width: parent.width
              text: row.modelData.name
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: row.chosen ? Commons.Color.menu.selectedText : Commons.Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
            }

            Text {
              width: parent.width
              visible: !row.modelData.accepts
              text: "Takes AirDrop from its contacts only"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Commons.Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: row.modelData.accepts ? Qt.PointingHandCursor : Qt.ArrowCursor
            onPositionChanged: function (mouse) { window.hovered(row.index, mapToItem(null, mouse.x, mouse.y)) }
            onClicked: window.pick(row.index)
          }
        }
      }

      Text {
        width: parent.width
        visible: window.receivers.length === 0
        text: window.starting ? "Switching AirDrop on. The Wi-Fi is off the network until the send is over."
          : "Looking for iPhones nearby…"
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Commons.Color.quieter(Commons.Color.menu.text, Commons.Color.menu.background, 0.7)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }

      // What makes an iPhone show, while none can be sent to.
      Text {
        width: parent.width
        visible: !window.anyone
        text: Model.EVERYONE + " It shows here then, unlocked and nearby."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Commons.Color.quieter(Commons.Color.menu.text, Commons.Color.menu.background, 0.7)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }

      Text {
        width: parent.width
        visible: window.bluetooth !== ""
        text: window.bluetooth
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Commons.Color.urgent
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }

      Item {
        width: parent.width
        height: cancel.height

        BorderSurface {
          id: toSettings
          visible: window.bluetooth !== ""
          anchors.right: cancel.left
          anchors.rightMargin: Style.space(8)
          width: Style.space(150)
          height: Style.space(34)
          color: settingsHover.containsMouse ? Commons.Color.menu.selectedBackground : "transparent"
          frame: Border.flat(settingsHover.containsMouse ? Commons.Color.menu.selectedText : Util.alpha(Commons.Color.menu.text, 0.38), Style.normalBorderWidth)

          Text {
            anchors.centerIn: parent
            text: "Bluetooth Settings"
            textFormat: Text.PlainText
            color: settingsHover.containsMouse ? Commons.Color.menu.selectedText : Commons.Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: settingsHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: window.bluetoothSettings()
          }
        }

        BorderSurface {
          id: cancel
          anchors.right: parent.right
          width: Style.space(88)
          height: Style.space(34)
          color: hover.containsMouse ? Commons.Color.menu.selectedBackground : "transparent"
          frame: Border.flat(hover.containsMouse ? Commons.Color.menu.selectedText : Util.alpha(Commons.Color.menu.text, 0.38), Style.normalBorderWidth)

          Text {
            anchors.centerIn: parent
            text: "Cancel"
            textFormat: Text.PlainText
            color: hover.containsMouse ? Commons.Color.menu.selectedText : Commons.Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: window.dismissed()
          }
        }
      }
    }
  }
}
