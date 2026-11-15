import QtQuick
import qs.Commons
import qs.Commons as Commons

// A button on the bar: its <text> in the bar's font and ink (the urgent
// colour while <urgent>), a click from any of the three buttons, a turn of
// the wheel, and the bar's tooltip, <tip>, while the pointer is on it.
//
// It is as thick as the bar. Along the bar it is its text and <margin> at
// each end, or <uprightMargin> on a bar up a side; a caller that draws its
// own content says so with <hasContent> and sets the size itself. A button
// with nothing to show is gone, unless it <holdsPlace>; a <veiled> one is
// unseen but keeps its place.
//
// The bar keeps a list of its buttons, so that a click on the bar under an
// open panel's surface still reaches the button there: each button puts
// itself on its bar's list, and takes itself off again.
Item {
  id: button

  property var bar: null
  property string text: ""
  property string tip: ""
  property bool urgent: false
  property color foreground: bar ? bar.textColour : Commons.Color.foreground
  property real fontSize: Style.font.body
  property bool hasContent: text !== ""
  property bool holdsPlace: false
  property bool veiled: false
  property bool pressable: true
  property real margin: 8.5
  property real uprightMargin: 6

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int thickness: bar ? bar.thickness : Style.bar.sizeHorizontal
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // The bar shows the tooltip of a button that is pointed at, shown and
  // pressable.
  readonly property bool pointedAt: visible && pressable && !veiled && hand.containsMouse
  // The text's own width, for marks lined up with the words rather than
  // the button.
  readonly property real textWidth: words.implicitWidth
  // What the text, or a glyph drawn in its place, is drawn in.
  property color ink: urgent ? (bar ? bar.urgent : Commons.Color.urgent) : foreground

  signal clicked(int which)
  signal scrolled(int delta)
  // The pointer came onto the button or left it; the tooltip has been asked
  // for or taken back already.
  signal crossed(bool over)

  // A click, from the pointer or passed on by the bar: the tooltip goes
  // first.
  function click(which) {
    if (bar) bar.tip.withdraw(button)
    clicked(which)
  }

  // The bar whose list it is on.
  property var _listedOn: null

  // Off the list of the bar it was on, onto <next>'s.
  function _list(next) {
    _listedOn?.listButton(button, false)
    _listedOn = next
    next?.listButton(button, true)
  }

  visible: hasContent || holdsPlace
  opacity: hasContent && !veiled ? 1 : 0
  implicitWidth: vertical ? thickness : Math.max(12, words.implicitWidth + 2 * Style.spaceReal(margin))
  implicitHeight: vertical ? Math.max(12, words.implicitHeight + 2 * Style.spaceReal(uprightMargin)) : thickness

  onBarChanged: _list(bar)
  Component.onCompleted: _list(bar)
  Component.onDestruction: _list(null)
  // Hidden, veiled, made inert or left: the tooltip goes too.
  onPointedAtChanged: if (!pointedAt && bar) bar.tip.withdraw(button)

  Behavior on opacity {
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }

  Text {
    id: words
    anchors.centerIn: parent
    text: button.text
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    color: button.ink
    font.family: button.fontFamily
    font.pixelSize: button.fontSize

    // Not while the bar recolours everything at once.
    Behavior on color {
      enabled: !button.bar || button.bar.textFades
      ColorAnimation { duration: 160 }
    }
  }

  MouseArea {
    id: hand
    anchors.fill: parent
    enabled: button.pressable
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    onEntered: {
      if (button.bar) button.bar.tip.ask(button, button.tip)
      button.crossed(true)
    }
    onExited: button.crossed(false)
    onClicked: mouse => button.click(mouse.button)
    onWheel: wheel => button.scrolled(wheel.angleDelta.y)
  }
}
