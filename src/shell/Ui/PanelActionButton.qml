import QtQuick
import qs.Commons
import qs.Commons as Commons

// A small square icon button, 22 pixels by default, for the actions at the
// end of a panel's row: forget a network, confirm a passphrase, unpair a
// device. Lit (the pointer over it, or <hasCursor>) or with the focus, it
// takes that state's fill in <hoverColor>: the foreground by default, the
// bar's urgent colour for an action that destroys something; at rest it is
// clear, with the normal border when <bordered>. Disabled, it is never lit
// and its icon dims.
//
// The pointer over it moves no panel cursor: the row it sits in has the
// cursor. Where the button is the cursor's target itself, the panel sets
// <hasCursor> and follows the pointer through hovered(). <focusable> makes
// it a Tab stop, for forms walked with Tab; on a row it stays off, as the
// row's CursorSurface has the keyboard.
Pressable {
  id: action

  property color foreground: Commons.Color.foreground
  property color hoverColor: foreground
  property real fontSize: Style.font.icon
  property real size: Math.max(Style.space(22), fontSize + Style.spacing.sm * 2)

  readonly property bool _lit: enabled && (_pointer.containsMouse || hasCursor)

  // Lit or with the focus, every colour comes from <hoverColor>; at rest
  // the border is the foreground's, with the theme's accent.
  tint: _lit || _ringed ? hoverColor : foreground
  tintAccent: _lit || _ringed ? hoverColor : Commons.Color.accent
  fade: 60
  fillState: _ringed ? "focus" : _lit ? "hover-cursor" : ""
  edgeState: _ringed ? "focus"
    : !bordered ? ""
    : _lit ? "hover-cursor"
    : "normal"

  implicitWidth: size
  implicitHeight: size
  // Disabled, it does not see the pointer at all: no hovered(), no tooltip.
  // (Qt sends a disabled item the pointer's comings and goings.)
  _pointer.enabled: enabled

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: action.iconText
    color: !action.enabled ? Qt.darker(action.foreground, 2.0) : action._lit ? action.hoverColor : action.foreground
    font.family: action.fontFamily
    font.pixelSize: action.fontSize
  }

  Connections {
    target: action._pointer
    function onContainsMouseChanged() { action.hovered(action._pointer.containsMouse) }
  }
}
