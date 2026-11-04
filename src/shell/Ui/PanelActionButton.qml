import QtQuick
import qs.Commons
import qs.Commons as Commons

// A small square icon button for the actions at the end of a panel's row:
// forget a network, confirm a passphrase, unpair a device. It is as wide as
// the icon and a little room round it, 22 pixels at least. Lit (the pointer
// over it, or <hasCursor>), it takes the hover-cursor fill, every colour of
// it from <foreground>; at rest it is clear, with no border. Disabled, it is
// never lit, its icon dims, and it does not see the pointer at all: no
// hovered(), no tooltip (Qt still sends a disabled item the pointer's
// comings and goings).
//
// The pointer over it moves no panel cursor: the row it sits in has the
// cursor. Where the button is the cursor's target itself, the panel sets
// <hasCursor> and follows the pointer through hovered().
Pressable {
  id: action

  property color foreground: Commons.Color.foreground

  readonly property real _side: Math.max(Style.space(22), Style.font.icon + Style.spacing.sm * 2)

  tint: foreground
  tintAccent: foreground
  fade: 60
  fillState: enabled && (_pointer.containsMouse || hasCursor) ? "hover-cursor" : ""

  implicitWidth: _side
  implicitHeight: _side
  _pointer.enabled: enabled

  Text {
    anchors.centerIn: parent
    text: action.iconText
    textFormat: Text.PlainText
    color: action.enabled ? action.foreground : Qt.darker(action.foreground, 2.0)
    font.family: action.fontFamily
    font.pixelSize: Style.font.icon
  }

  Connections {
    target: action._pointer
    function onContainsMouseChanged() { action.hovered(action._pointer.containsMouse) }
  }
}
