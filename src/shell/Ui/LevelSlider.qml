import QtQuick
import qs.Commons
import qs.Commons as Commons

// A level set by hand, from <from> to <to>: a volume, a brightness, a text
// size. A line across the item, filled from its start to a round knob; the
// knob swells under the pointer. Pressing on the line puts the knob there and
// dragging takes it along, each place sent by dragged(); letting go sends
// letGo(). A wheel notch moves it <wheelStep> and sends both at once. <whole>
// rounds every place to a whole number.
//
// <value> is the level in effect, and the knob shows <knobAt>: <value>, or
// the place the hand left it. A caller may hold <value> back until its change
// has taken (Settings waits for the state file it writes), and the knob stays
// put meanwhile; three seconds without the new value means it was refused,
// and the knob goes back.
//
// <notches> above 1 marks that many places evenly along the line, cut out of
// it in the panel's colour. They are marks only: a caller that wants the
// level on one rounds it there itself.
Item {
  id: level

  property QtObject bar: null
  property real value: 0
  property real from: 0
  property real to: 1
  property real wheelStep: 0.05
  property bool whole: false
  property int notches: 0

  readonly property bool held: hand.pressed
  readonly property real knobAt: _placed ?? value

  signal dragged(real at)
  signal letGo(real at)

  // Where the hand put the knob; null while the knob follows <value>.
  property var _placed: null

  readonly property color _ink: bar ? bar.foreground : Commons.Color.foreground
  readonly property color _paper: bar ? bar.background : Commons.Color.background
  readonly property real _lineWidth: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
  readonly property real _knobWidth: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))
  // How far along the line the knob is, 0 at <from> and 1 at <to>.
  readonly property real _share: {
    const span = to - from
    return span > 0 ? Math.min(1, Math.max(0, (knobAt - from) / span)) : 0
  }

  function _level(at) {
    const clamped = Math.min(to, Math.max(from, at))
    return whole ? Math.round(clamped) : clamped
  }

  function _drag(at) {
    _placed = _level(at)
    dragged(_placed)
  }

  function _release() {
    letGo(knobAt)
    waiting.restart()
  }

  function _placeUnder(x) {
    return from + Math.min(1, Math.max(0, x / line.width)) * (to - from)
  }

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), _knobWidth + Style.spacing.md)

  // The level took: the knob follows it again, unless it is in hand.
  onValueChanged: {
    if (held) return
    waiting.stop()
    _placed = null
  }

  Timer {
    id: waiting
    interval: 3000
    onTriggered: if (!level.held) level._placed = null
  }

  Rectangle {
    id: line
    width: parent.width
    height: level._lineWidth
    y: (parent.height - height) / 2
    radius: height / 2
    color: level.bar ? Style.selectedFillFor(level.bar.foreground, Commons.Color.accent) : "#333"

    Rectangle {
      width: line.width * level._share
      height: parent.height
      radius: parent.radius
      color: level._ink

      Behavior on width {
        enabled: !level.held
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }

    Repeater {
      model: level.notches > 1 ? level.notches : 0

      Rectangle {
        required property int index

        width: Math.max(1, Style.space(2))
        height: line.height + Style.space(4)
        y: (line.height - height) / 2
        x: Math.min(line.width - width, Math.max(0, line.width * index / (level.notches - 1) - width / 2))
        radius: 1
        color: level._paper
      }
    }

    BorderSurface {
      id: knob
      width: level._knobWidth
      height: level._knobWidth
      y: (line.height - height) / 2
      x: Math.min(line.width - width, Math.max(0, line.width * level._share - width / 2))
      radius: level._knobWidth / 2
      color: level._ink
      frame: Border.flat(level.bar ? level.bar.background : "#101315", Math.max(1, Style.space(2)))
      scale: hand.containsMouse || level.held ? 1.15 : 1

      Behavior on x {
        enabled: !level.held
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
      Behavior on scale {
        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
      }
    }
  }

  // Only the left button: a caller may give the other buttons a meaning of
  // its own (audio mutes on a right click). A drag drifting up or down stays
  // here rather than going to a Flickable round it, which would leave the
  // knob stuck without its release.
  MouseArea {
    id: hand
    anchors.fill: parent
    hoverEnabled: true
    preventStealing: true
    cursorShape: Qt.PointingHandCursor

    onPressed: mouse => level._drag(level._placeUnder(mouse.x))
    onPositionChanged: mouse => { if (pressed) level._drag(level._placeUnder(mouse.x)) }
    onReleased: level._release()
    // Taken away mid-drag (a popup closing under it): let go where it is.
    onCanceled: level._release()
    onWheel: wheel => {
      level._drag(level.knobAt + (wheel.angleDelta.y > 0 ? level.wheelStep : -level.wheelStep))
      level._release()
    }
  }
}
