import QtQuick
import qs.Commons
import qs.Commons as Commons

// A small square icon button, 22 pixels by default, for the actions at the
// end of a panel's row: forget a network, confirm a passphrase, unpair a
// device. Lit (the pointer over it, or <hasCursor>), it takes the
// hover-cursor fill in its foreground; at rest it is clear, with no border.
// Disabled, it is never lit and its icon dims.
//
// The pointer over it moves no panel cursor: the row it sits in has the
// cursor. Where the button is the cursor's target itself, the panel sets
// <hasCursor> and follows the pointer through hovered().
Pressable {
  id: action

  property color foreground: Commons.Color.foreground
  property real fontSize: Style.font.icon
  property real size: Math.max(Style.space(22), fontSize + Style.spacing.sm * 2)

  readonly property bool _lit: enabled && (_pointer.containsMouse || hasCursor)

  // Lit, its fill takes every colour from the foreground, the accent too.
  tint: foreground
  tintAccent: foreground
  fade: 60
  fillState: _lit ? "hover-cursor" : ""

  implicitWidth: size
  implicitHeight: size
  // Disabled, it does not see the pointer at all: no hovered(), no tooltip.
  // (Qt sends a disabled item the pointer's comings and goings.)
  _pointer.enabled: enabled

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: action.iconText
    color: action.enabled ? action.foreground : Qt.darker(action.foreground, 2.0)
    font.family: action.fontFamily
    font.pixelSize: action.fontSize
  }

  Connections {
    target: action._pointer
    function onContainsMouseChanged() { action.hovered(action._pointer.containsMouse) }
  }
}
