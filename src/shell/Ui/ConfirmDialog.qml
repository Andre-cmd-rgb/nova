import QtQuick
import qs.Commons
import qs.Commons as Commons

// A question over its parent, which it dims: a card with <message> over two
// answers, Cancel and <confirmText>, the second in the urgent colour as it
// is the one that does something. A click on an answer gives it, canceled()
// or confirmed(); a click on the dimmed parent cancels. <selectedIndex> is
// the answer Return gives (0 cancel, 1 confirm), and the pointer moves it.
// The host hands its keys to handleKey() while the dialog is open.
Item {
  id: dialog

  property bool opened: false
  property string message: ""
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

  function _give(answer) {
    if (answer === 0) canceled()
    else confirmed()
  }

  // Escape cancels; Left, Right, Tab and Backtab go to the other answer;
  // Return and Enter give the one chosen. True for a key the dialog took,
  // which no key is while it is closed.
  function handleKey(event) {
    if (!opened) return false
    const key = event.key
    if (key === Qt.Key_Escape) canceled()
    else if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Tab, Qt.Key_Backtab].indexOf(key) >= 0) selectedIndex = selectedIndex === 0 ? 1 : 0
    else if (key === Qt.Key_Return || key === Qt.Key_Enter) _give(selectedIndex)
    else return false
    return true
  }

  visible: opened

  // The dimmed parent: a click on it cancels.
  Rectangle {
    anchors.fill: parent
    color: dialog.scrim

    MouseArea {
      anchors.fill: parent
      onClicked: dialog.canceled()
    }

    // As tall as the wrapped message needs, so a narrow host (the menu's
    // card) does not push the words into the answers.
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
          text: dialog.message
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: dialog.foreground
          font.family: dialog.fontFamily
          font.pixelSize: Style.font.title
        }

        Row {
          anchors.right: parent.right
          spacing: Style.space(10)

          Repeater {
            model: ["Cancel", dialog.confirmText]

            // An answer: the chosen one at full strength and filled, the
            // other only outlined, faintly. Confirm's strength is the
            // urgent colour.
            BorderSurface {
              id: answer

              required property int index
              required property string modelData
              readonly property bool chosen: dialog.selectedIndex === index
              readonly property color strong: index === 1 ? Commons.Color.urgent : dialog.selectedText
              readonly property color faint: index === 1 ? Util.alpha(Commons.Color.urgent, 0.56) : Util.alpha(dialog.foreground, 0.38)
              readonly property color filled: index === 1 ? Util.alpha(Commons.Color.urgent, 0.22) : dialog.selectedBackground

              width: Style.space(88)
              height: Style.space(34)
              radius: 0
              color: chosen ? filled : "transparent"
              borderSpec: Border.flat(chosen ? strong : faint, Style.normalBorderWidth)

              Text {
                anchors.centerIn: parent
                text: answer.modelData
                textFormat: Text.PlainText
                color: answer.chosen ? answer.strong : dialog.foreground
                font.family: dialog.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: dialog.selectedIndex = answer.index
                onClicked: dialog._give(answer.index)
              }
            }
          }
        }
      }
    }
  }
}
