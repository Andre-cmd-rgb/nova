import QtQuick
import qs.Commons
import qs.Commons as Commons

// A yes-or-no question asked over a menu-like surface (the menu, the
// clipboard picker), in the menu's colours: the surface dimmed, and on it a
// card with <question> and two answers, Cancel and <yes>, the second in the
// urgent colour as the one that does something.
//
// The answer under the pointer, or the one the arrows and Tab moved to, is
// <choice> (0 Cancel, 1 <yes>); each asking starts on <yes>. A click on an
// answer, or Return, gives it: kept() or confirmed(). Escape and a click on
// the dimmed surface keep. While it asks, the host passes its keys to key().
Item {
  id: dialog

  property bool asking: false
  property string question: ""
  property string yes: "Confirm"
  property int choice: 1

  signal kept()
  signal confirmed()

  function _answer(which) {
    if (which === 1) confirmed()
    else kept()
  }

  // True for a key the question took.
  function key(event) {
    if (!asking) return false
    switch (event.key) {
    case Qt.Key_Escape:
      kept()
      break
    case Qt.Key_Return:
    case Qt.Key_Enter:
      _answer(choice)
      break
    case Qt.Key_Left:
    case Qt.Key_Right:
    case Qt.Key_Tab:
    case Qt.Key_Backtab:
      choice = 1 - choice
      break
    default:
      return false
    }
    return true
  }

  visible: asking
  onAskingChanged: if (asking) choice = 1

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.menu.scrim

    MouseArea {
      anchors.fill: parent
      onClicked: dialog.kept()
    }
  }

  // As tall as the words wrap to, so that a narrow host (the menu's card)
  // does not push them into the answers.
  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(32), Style.space(370))
    height: inset.top + words.implicitHeight + Style.space(20) + answers.height + inset.bottom
    padding: Style.space(18)
    radius: Style.cornerRadius
    color: Commons.Color.menu.background
    frame: Border.flat(Commons.Color.menu.selectedText, Style.normalBorderWidth)

    // Clicks on the card stay off the dimmed surface.
    MouseArea {
      anchors.fill: parent
    }

    Text {
      id: words
      x: card.inset.left
      y: card.inset.top
      width: card.width - card.inset.left - card.inset.right
      text: dialog.question
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Commons.Color.menu.text
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.title
    }

    Row {
      id: answers
      anchors.right: parent.right
      anchors.rightMargin: card.inset.right
      anchors.bottom: parent.bottom
      anchors.bottomMargin: card.inset.bottom
      spacing: Style.space(10)

      Answer { which: 0; label: "Cancel" }
      Answer { which: 1; label: dialog.yes }
    }
  }

  // An answer, outlined faintly; filled and at full strength while chosen.
  // The doing one's strength is the urgent colour, Cancel's the menu's
  // selected text.
  component Answer: BorderSurface {
    id: answer

    required property int which
    required property string label
    readonly property bool chosen: dialog.choice === which
    readonly property color strength: which === 1 ? Commons.Color.urgent : Commons.Color.menu.selectedText

    width: Style.space(88)
    height: Style.space(34)
    color: !chosen ? "transparent" : which === 1 ? Util.alpha(Commons.Color.urgent, 0.22) : Commons.Color.menu.selectedBackground
    frame: Border.flat(chosen ? strength : which === 1 ? Util.alpha(Commons.Color.urgent, 0.56) : Util.alpha(Commons.Color.menu.text, 0.38), Style.normalBorderWidth)

    Text {
      anchors.centerIn: parent
      text: answer.label
      textFormat: Text.PlainText
      color: answer.chosen ? answer.strength : Commons.Color.menu.text
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: dialog.choice = answer.which
      onClicked: dialog._answer(answer.which)
    }
  }
}
