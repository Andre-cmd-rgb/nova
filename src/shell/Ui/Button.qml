import QtQuick
import qs.Commons
import qs.Commons as Commons

// The button for anything clicked in a panel: a label, an icon, or both.
// Its state, for the fill, is the first of: pressed; focus, when focusable;
// hover-cursor, under the pointer or the panel's cursor; selected, when
// <selected> or <active>; else <background>. For the border it is focus,
// then hover-cursor, then selected where the theme gives selected borders a
// width, then normal when <bordered>, else none: the keyboard's place always
// shows. A selected label is bold, in the selected colour.
//
// Round the content the button keeps room for the widest border any of its
// states can draw, so it keeps its size as the pointer or the focus comes
// and goes. hovered() follows the pointer, for panels that move their own
// cursor with it.
Pressable {
  id: button

  property string text: ""
  property bool selected: false
  property bool active: false
  property color foreground: Commons.Color.foreground
  property color background: "transparent"
  property color accent: Commons.Color.accent
  property real fontSize: Style.font.body
  property real iconSize: Style.font.icon
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.controlPaddingY

  readonly property bool hot: _pointer.containsMouse || hasCursor

  // Each side's widest border over the states the button can be in.
  readonly property var _room: {
    var states = ["hover-cursor", "selected"]
    if (focusable) states.push("focus")
    if (bordered) states.push("normal")
    var room = { top: 0, right: 0, bottom: 0, left: 0 }
    for (var i = 0; i < states.length; i++) {
      var sides = Border.controlWidths(states[i])
      for (var side in room) room[side] = Math.max(room[side], sides[side])
    }
    return room
  }
  readonly property color _ink: selected ? Style.selectedStateColor(foreground, accent) : foreground

  tint: foreground
  tintAccent: accent
  restColor: background
  fade: 120
  fillState: _pointer.pressed ? "pressed"
    : _ringed ? "focus"
    : hot ? "hover-cursor"
    : selected || active ? "selected"
    : ""
  edgeState: _ringed ? "focus"
    : hot ? "hover-cursor"
    : selected && Border.controlHasWidth("selected") ? "selected"
    : bordered ? "normal"
    : ""

  topPadding: verticalPadding
  rightPadding: horizontalPadding
  bottomPadding: verticalPadding
  leftPadding: horizontalPadding
  implicitWidth: content.implicitWidth + 2 * horizontalPadding + _room.left + _room.right
  implicitHeight: content.implicitHeight + 2 * verticalPadding + _room.top + _room.bottom

  _buttons: Qt.LeftButton | Qt.RightButton
  _tip.cornerRadius: 0
  _tip.minimumBorderWidth: 1

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.spacing.controlGap

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: button.iconText !== ""
      textFormat: Text.PlainText
      text: button.iconText
      color: button._ink
      font.family: button.fontFamily
      font.pixelSize: button.iconSize
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: button.text !== ""
      textFormat: Text.PlainText
      text: button.text
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
