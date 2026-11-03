import QtQuick
import qs.Commons
import qs.Commons as Commons

// A question over its parent, which it dims: a card with <message> and two
// buttons, <cancelText> and <confirmText>, the second in the urgent colour
// as it is the one that does something. A click on either sends canceled()
// or confirmed(); one on the dimmed parent cancels. The host passes its keys
// through handleKey() while the dialog is open.
Item {
  id: root

  property bool opened: false
  property string message: ""
  property string cancelText: "Cancel"
  property string confirmText: "Confirm"
  // The button Return presses: 0 cancel, 1 confirm.
  property int selectedIndex: 1
  property color background: Commons.Color.background
  property color foreground: Commons.Color.foreground
  property color scrim: Util.alpha(Commons.Color.background, 0.7)
  property color selectedBackground: Util.alpha(Commons.Color.foreground, 0.08)
  property color selectedText: Commons.Color.accent
  property string fontFamily: Style.font.family
  property int cornerRadius: Style.cornerRadius

  signal canceled()
  signal confirmed()

  // Escape cancels; Left, Right, Tab and Backtab go to the other button;
  // Return and Enter press the chosen one. True when the key was the
  // dialog's; while it is closed, none is.
  function handleKey(event) {
    if (!opened) return false
    switch (event.key) {
    case Qt.Key_Escape:
      canceled()
      return true
    case Qt.Key_Left:
    case Qt.Key_Right:
    case Qt.Key_Tab:
    case Qt.Key_Backtab:
      root.selectedIndex = selectedIndex === 0 ? 1 : 0
      return true
    case Qt.Key_Return:
    case Qt.Key_Enter:
      if (selectedIndex === 0) canceled()
      else confirmed()
      return true
    }
    return false
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: root.scrim

    MouseArea {
      anchors.fill: parent
      onClicked: root.canceled()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(32), Style.space(370))
      // As tall as the wrapped message needs, so a narrow host (the menu's
      // card) does not push the text into the buttons.
      height: card.contentTopInset + card.contentBottomInset + question.implicitHeight + Style.space(20) + Style.space(34)
      radius: root.cornerRadius
      padding: Style.space(18)
      color: root.background
      borderSpec: Border.flat(root.selectedText, Style.normalBorderWidth)

      // A click on the card is not one on the dimmed parent.
      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Text {
          id: question
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: root.message
          color: root.foreground
          font { family: root.fontFamily; pixelSize: Style.font.title }
          wrapMode: Text.WordWrap
        }

        Row {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.space(10)

          Repeater {
            model: [root.cancelText, root.confirmText]

            BorderSurface {
              id: choice

              required property int index
              required property string modelData

              readonly property bool selected: root.selectedIndex === index
              readonly property bool destructive: index === 1
              // Confirm is drawn in the urgent colour, cancel in the
              // dialog's own; the chosen one at full strength.
              readonly property color _mark: destructive ? Commons.Color.urgent : root.selectedText

              width: Style.space(88)
              height: Style.space(34)
              radius: 0
              color: !selected ? "transparent" : destructive ? Util.alpha(Commons.Color.urgent, 0.22) : root.selectedBackground
              borderSpec: Border.flat(selected ? _mark : destructive ? Util.alpha(Commons.Color.urgent, 0.56) : Util.alpha(root.foreground, 0.38),
                Style.normalBorderWidth)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: choice.modelData
                color: choice.selected ? choice._mark : root.foreground
                font { family: root.fontFamily; pixelSize: Style.font.caption }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = choice.index
                onClicked: {
                  if (choice.index === 0) root.canceled()
                  else root.confirmed()
                }
              }
            }
          }
        }
      }
    }
  }
}
