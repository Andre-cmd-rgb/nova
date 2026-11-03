import QtQuick
import qs.Commons
import qs.Commons as Commons

// An on/off switch with no label: a track and a knob that slides along it.
// Toggle puts one at the end of its row; a panel's header can take one by
// itself.
//
// The switch does not keep its own value: <checked> is bound to the real
// state, and the caller changes that on toggled(). A service that already
// holds the state it is moving to (Tailscale's, say) throws the knob at
// once. <busy> means a change is under way: clicks do nothing, while hover,
// cursor and tooltip carry on, so a refresh in the background does not make
// the switch flicker.
//
// The cursor is a ring round the track rather than a change of the track:
// the theme's normal border is stronger than its hover-cursor one (0.4
// against 0.25), right for controls with no border at rest but one that
// would make a bordered track fade under the cursor. The ring goes with
// <interactive>: where the row round the switch takes the click, the row
// takes the cursor too. The switch is a pill when the theme's corners are
// round, square when they are not.
Item {
  id: root

  property bool checked: false
  property bool busy: false
  // False where the row round the switch takes the click, as in Toggle.
  property bool interactive: true
  // The panel cursor is on it, as Button's <hasCursor>.
  property bool hasCursor: false
  property bool cursorRing: interactive
  property int cursorPad: Style.space(6)
  property bool rounded: Style.cornerRadius > 0
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  // <trackHeight> can be set for a smaller switch (one in a section's
  // header): asked for at its size, rather than a big one scaled down, its
  // edges land on whole pixels and stay sharp. The floors below only stop
  // such a size going absurd; at the usual height every size is above them.
  property int trackHeight: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55))
  property int trackWidth: Math.round(trackHeight * 1.9)
  property int knobSize: Math.max(6, Math.round(trackHeight * 0.72))
  property int knobInset: Math.max(1, Math.round((trackHeight - knobSize) / 2))

  readonly property alias containsMouse: pointer.containsMouse
  readonly property bool hot: hasCursor || pointer.containsMouse
  readonly property int _pad: cursorRing ? cursorPad : 0

  signal toggled()
  signal hovered(bool isHovered)

  implicitWidth: trackWidth + _pad * 2
  implicitHeight: trackHeight + _pad * 2

  BorderSurface {
    anchors.fill: parent
    visible: root.cursorRing && root.hot
    color: "transparent"
    radius: Style.cornerRadius
    borderSpec: Border.controlSpec("hover-cursor", root.foreground, root.accent)
  }

  BorderSurface {
    id: track
    anchors.centerIn: parent
    width: root.trackWidth
    height: root.trackHeight
    radius: root.rounded ? height / 2 : 0
    color: root.checked ? Style.selectedFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
    borderSpec: Border.controlSpec(root.checked ? "selected" : "normal", root.foreground, root.accent)

    Behavior on color {
      ColorAnimation { duration: 120 }
    }

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: root.checked ? track.width - width - root.knobInset : root.knobInset
      width: root.knobSize
      height: root.knobSize
      radius: root.rounded ? height / 2 : 0
      color: root.checked ? Style.selectedStateColor(root.foreground, root.accent) : Qt.darker(root.foreground, 1.25)

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
    enabled: root.interactive
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: root.hovered(containsMouse)
    onClicked: {
      if (!root.busy) root.toggled()
    }
  }
}
