import QtQuick
import qs.Commons
import qs.Commons as Commons

// A switch with no words: a track, filled in the selected state while on and
// the normal one while off, and a knob that slides to the end that is on.
// Toggle has one at the end of its row; a panel's header can have one alone.
//
// It keeps no state: <checked> is bound to what it shows, and the caller
// changes that on toggled(), so that a service already in the state asked
// for (Tailscale, say) throws the knob at once. While <busy> a change is
// under way and a click does nothing, but the pointer, the cursor and the
// tooltip carry on, so that a refresh in the background does not flicker.
//
// The cursor is a hover-cursor ring <ringGap> round the track, rather than
// a change of the track: the theme's normal border is stronger than its
// hover-cursor one, which suits controls bare at rest but would fade a
// bordered track under the cursor. Where the row round the switch takes the
// click (<pressable> false) the row shows the cursor, and the switch keeps
// no room for a ring. The track is a pill where the theme's corners are
// round, square where they are not.
//
// <size> is the track's height: a switch in a section's header is drawn
// smaller at its own size, so its edges stay on whole pixels. The track is
// 1.9 times as long, the knob 0.72 times as high.
Item {
  id: toggle

  property bool checked: false
  property bool busy: false
  property bool pressable: true
  property bool hasCursor: false
  property int ringGap: Style.space(6)
  property int size: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55))
  property color foreground: Commons.Color.foreground

  readonly property alias containsMouse: hand.containsMouse

  readonly property int _length: Math.round(size * 1.9)
  readonly property int _knob: Math.max(6, Math.round(size * 0.72))
  readonly property int _inset: Math.max(1, Math.round((size - _knob) / 2))
  readonly property bool _round: Style.cornerRadius > 0
  readonly property int _ring: pressable ? ringGap : 0

  signal toggled()
  signal hovered(bool isHovered)

  implicitWidth: _length + 2 * _ring
  implicitHeight: size + 2 * _ring

  // The cursor: a ring round the whole switch.
  ControlFace {
    anchors.fill: parent
    visible: toggle.pressable && (toggle.hasCursor || toggle.containsMouse)
    radius: Style.cornerRadius
    tint: toggle.foreground
    edgeState: "hover-cursor"
  }

  ControlFace {
    id: track
    anchors.centerIn: parent
    width: toggle._length
    height: toggle.size
    radius: toggle._round ? toggle.size / 2 : 0
    tint: toggle.foreground
    fillState: toggle.checked ? "selected" : "normal"
    edgeState: fillState
    fade: 120

    Rectangle {
      width: toggle._knob
      height: toggle._knob
      radius: toggle._round ? toggle._knob / 2 : 0
      y: (track.height - height) / 2
      x: toggle.checked ? track.width - toggle._knob - toggle._inset : toggle._inset
      color: toggle.checked ? Style.selectedStateColor(toggle.foreground, Commons.Color.accent) : Util.faded(toggle.foreground, 1.25)

      Behavior on x {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
      Behavior on color {
        ColorAnimation { duration: 120 }
      }
    }
  }

  MouseArea {
    id: hand
    anchors.fill: parent
    enabled: toggle.pressable
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: toggle.hovered(containsMouse)
    onClicked: if (!toggle.busy) toggle.toggled()
  }
}
