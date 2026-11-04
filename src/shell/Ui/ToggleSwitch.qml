import QtQuick
import qs.Commons
import qs.Commons as Commons

// An on/off switch with no words: a track in the selected state when on and
// the normal one when off, and a knob that slides to the end that is on.
// Toggle shows one at the end of its row; a panel's header can hold one
// alone.
//
// It holds no value of its own: <checked> is bound to the real state, and
// the caller changes that on toggled(), so a service that already has the
// state it moves to (Tailscale's, say) throws the knob at once. While <busy>
// a change is under way and clicks do nothing; the pointer, the cursor and
// the tooltip carry on, so a refresh in the background does not flicker.
//
// The cursor is a hover-cursor ring round the track, <cursorPad> out, not a
// change of the track: the theme's normal border is stronger than its
// hover-cursor one (0.4 against 0.25), which suits controls with no border at
// rest but would fade a bordered track under the cursor. Where the row round
// the switch takes the click (<interactive> false) the row has the cursor,
// and the switch has no ring nor room for one. The switch is a pill where
// the theme's corners are round, square where they are not.
//
// A smaller switch (one in a section's header) sets <trackHeight>: drawn at
// its own size rather than scaled down, its edges stay on whole pixels. The
// track is 1.9 times as long, the knob 0.72 times as high; the floors only
// keep an odd size sane.
Item {
  id: toggleSwitch

  property bool checked: false
  property bool busy: false
  property bool interactive: true
  property bool hasCursor: false
  property int cursorPad: Style.space(6)
  property int trackHeight: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55))
  property color foreground: Commons.Color.foreground

  readonly property alias containsMouse: pointer.containsMouse

  readonly property int _trackLength: Math.round(trackHeight * 1.9)
  readonly property int _knob: Math.max(6, Math.round(trackHeight * 0.72))
  readonly property int _knobGap: Math.max(1, Math.round((trackHeight - _knob) / 2))
  readonly property bool _pill: Style.cornerRadius > 0
  readonly property int _ringRoom: interactive ? cursorPad : 0

  signal toggled()
  signal hovered(bool isHovered)

  implicitWidth: _trackLength + 2 * _ringRoom
  implicitHeight: trackHeight + 2 * _ringRoom

  // The cursor's ring, the whole switch round.
  ControlFace {
    anchors.fill: parent
    visible: toggleSwitch.interactive && (toggleSwitch.hasCursor || toggleSwitch.containsMouse)
    tint: toggleSwitch.foreground
    edgeState: "hover-cursor"
    radius: Style.cornerRadius
  }

  ControlFace {
    id: track
    anchors.centerIn: parent
    width: toggleSwitch._trackLength
    height: toggleSwitch.trackHeight
    radius: toggleSwitch._pill ? height / 2 : 0
    tint: toggleSwitch.foreground
    fillState: toggleSwitch.checked ? "selected" : "normal"
    edgeState: fillState
    fade: 120

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: toggleSwitch.checked ? track.width - width - toggleSwitch._knobGap : toggleSwitch._knobGap
      width: toggleSwitch._knob
      height: width
      radius: toggleSwitch._pill ? width / 2 : 0
      color: toggleSwitch.checked ? Style.selectedStateColor(toggleSwitch.foreground, Commons.Color.accent) : Qt.darker(toggleSwitch.foreground, 1.25)

      Behavior on x {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
      Behavior on color {
        ColorAnimation { duration: 120 }
      }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    enabled: toggleSwitch.interactive
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: toggleSwitch.hovered(containsMouse)
    onClicked: if (!toggleSwitch.busy) toggleSwitch.toggled()
  }
}
