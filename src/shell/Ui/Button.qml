import QtQuick
import qs.Commons
import qs.Commons as Commons

// The button for anything clicked in a panel: words, an icon, or both.
//
// Its fill is the first state that holds of: pressed; focus, as a Tab stop
// with the focus; hover-cursor, under the pointer or the panel's cursor;
// selected, when <selected> or <lit>; else its <restColor>. Its border is
// focus, then hover-cursor, then selected where the theme gives a selected
// border a width, then normal when <bordered>, else none, so that the
// keyboard's place always shows. A <selected> button's words are bold and in
// the selected colour; a <lit> one only has the fill.
//
// It keeps room round its content for the widest border any of its states
// can draw, so it keeps its size as the pointer and the focus come and go.
// hovered() follows the pointer, for panels whose cursor follows it too.
Pressable {
  id: button

  property string text: ""
  property bool selected: false
  property bool lit: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property real fontSize: Style.font.body
  property real iconSize: Style.font.icon

  readonly property bool hot: _pointer.containsMouse || hasCursor

  // On each side, the widest border of the states this button can be in.
  readonly property var _room: {
    const states = ["hover-cursor", "selected"].concat(tabStop ? ["focus"] : [], bordered ? ["normal"] : [])
    const widths = states.map(state => Border.controlWidths(state))
    const widest = side => Math.max(0, ...widths.map(w => w[side]))
    return { top: widest("top"), right: widest("right"), bottom: widest("bottom"), left: widest("left") }
  }
  readonly property color _ink: selected ? Style.selectedStateColor(foreground, accent) : foreground

  tint: foreground
  tintAccent: accent
  fade: 120
  fillState: _pointer.pressed ? "pressed"
    : _ringed ? "focus"
    : hot ? "hover-cursor"
    : selected || lit ? "selected"
    : ""
  edgeState: _ringed ? "focus"
    : hot ? "hover-cursor"
    : selected && Border.controlHasWidth("selected") ? "selected"
    : bordered ? "normal"
    : ""

  padX: Style.spacing.controlPaddingX
  padY: Style.spacing.controlPaddingY
  implicitWidth: _room.left + padX + words.implicitWidth + padX + _room.right
  implicitHeight: _room.top + padY + words.implicitHeight + padY + _room.bottom

  _buttons: Qt.LeftButton | Qt.RightButton
  _tip.square: true

  Row {
    id: words
    anchors.centerIn: parent
    spacing: Style.spacing.controlGap

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      text: button.iconText
      textFormat: Text.PlainText
      color: button._ink
      font.family: button.fontFamily
      font.pixelSize: button.iconSize
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      text: button.text
      textFormat: Text.PlainText
      color: button._ink
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      font.bold: button.selected
    }
  }

  HoverHandler {
    onHoveredChanged: button.hovered(hovered)
  }
}
