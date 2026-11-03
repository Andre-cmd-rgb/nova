import QtQuick
import qs.Commons
import qs.Commons as Commons

// A question over its parent, which it dims: a card with <message> over two
// buttons, <cancelText> and <confirmText>, the second in the urgent colour
// as it is the one that does something. A click on one answers with
// canceled() or confirmed(); a click on the dimmed parent cancels. The
// button Return presses is <selectedIndex> (0 cancel, 1 confirm); the
// pointer moves it. The host hands its keys to handleKey() while the dialog
// is open.
Item {
  id: dialog

  property bool opened: false
  property string message: ""
  property string cancelText: "Cancel"
  property string confirmText: "Confirm"
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

  function _answer(index) {
    if (index === 0) canceled()
    else confirmed()
  }

  // Escape cancels; Left, Right, Tab and Backtab go to the other button;
  // Return and Enter press the one chosen. True for a key the dialog took,
  // which no key is while it is closed.
  function handleKey(event) {
    if (!opened) return false
    switch (event.key) {
    case Qt.Key_Escape:
      canceled()
      break
    case Qt.Key_Left:
    case Qt.Key_Right:
    case Qt.Key_Tab:
    case Qt.Key_Backtab:
      selectedIndex = selectedIndex === 0 ? 1 : 0
      break
    case Qt.Key_Return:
    case Qt.Key_Enter:
      _answer(selectedIndex)
      break
    default:
      return false
    }
    return true
  }

  // One of the two buttons: chosen, at full strength and filled; else only
  // outlined, faintly.
  component Choice: BorderSurface {
    id: choice

    required property int index
    property string label
    readonly property bool chosen: dialog.selectedIndex === index
    readonly property bool urgent: index === 1
    readonly property color _strong: urgent ? Commons.Color.urgent : dialog.selectedText

    width: Style.space(88)
    height: Style.space(34)
    radius: 0
    color: !chosen ? "transparent" : urgent ? Util.alpha(Commons.Color.urgent, 0.22) : dialog.selectedBackground
    borderSpec: Border.flat(chosen ? _strong : Util.alpha(urgent ? Commons.Color.urgent : dialog.foreground, urgent ? 0.56 : 0.38),
      Style.normalBorderWidth)

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: choice.label
      color: choice.chosen ? choice._strong : dialog.foreground
      font.family: dialog.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: dialog.selectedIndex = choice.index
      onClicked: dialog._answer(choice.index)
    }
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: dialog.scrim

    MouseArea {
      anchors.fill: parent
      onClicked: dialog.canceled()
    }

    // As tall as the wrapped message needs, so a narrow host (the menu's
    // card) does not push the words into the buttons.
    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(32), Style.space(370))
      height: body.implicitHeight + contentTopInset + contentBottomInset
      radius: dialog.cornerRadius
      padding: Style.space(18)
      color: dialog.background
      borderSpec: Border.flat(dialog.selectedText, Style.normalBorderWidth)

      // A click on the card is not one on the dimmed parent.
      MouseArea {
        anchors.fill: parent
      }

      Column {
        id: body
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        spacing: Style.space(20)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: dialog.message
          color: dialog.foreground
          font.family: dialog.fontFamily
          font.pixelSize: Style.font.title
          wrapMode: Text.WordWrap
        }

        Row {
          anchors.right: parent.right
          spacing: Style.space(10)

          Choice { index: 0; label: dialog.cancelText }
          Choice { index: 1; label: dialog.confirmText }
        }
      }
    }
  }
}
