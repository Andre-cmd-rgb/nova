import QtQuick
import qs.Commons
import qs.Commons as Commons

// A slider for a panel: a track, filled up to the value, and a round knob
// that grows a little under the pointer. Dragging sends moved() as it goes
// and released() at the end; a wheel notch moves it by <step> and sends
// both. <integer> rounds the value to whole numbers. A right click anywhere
// sends rightClicked(), which audio uses to mute the slider's channel;
// only the left button drags.
Item {
  id: root

  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false
  property color trackColor: bar ? Style.selectedFillFor(bar.foreground, Commons.Color.accent) : "#333"
  property color fillColor: bar ? bar.foreground : Commons.Color.foreground
  property color knobColor: bar ? bar.foreground : Commons.Color.foreground
  property bool dragging: false
  property real trackHeight: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
  property real knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))
  // Where the knob is drawn: <value>, or where the user has put it.
  property real liveValue: value

  // With <tickCount> above 1, that many notches evenly along the track, in
  // the panel's background so they show only where they cross it. They are
  // only drawn: snapping to them is the caller's, with <integer>, <step> or
  // a value that counts notches.
  property int tickCount: 0
  property color tickColor: bar ? bar.background : Commons.Color.background

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))
  readonly property bool _hot: pointer.containsMouse || dragging

  signal moved(real value)
  signal released(real value)
  signal rightClicked()

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), knobSize + Style.spacing.md)

  // A new value from the caller moves the knob, unless the user holds it.
  onValueChanged: {
    if (dragging) return
    liveValue = value
    settle.stop()
  }

  // Some callers change <value> only once the change has taken (Settings
  // waits for its state file), so the knob stays where it was let go until
  // then. A value that has not come in three seconds was refused: the knob
  // goes back to it.
  Timer {
    id: settle
    interval: 3000
    onTriggered: {
      if (!root.dragging) root.liveValue = root.value
    }
  }

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: root.trackHeight
    radius: height / 2
    color: root.trackColor
  }

  Rectangle {
    anchors.left: track.left
    anchors.verticalCenter: track.verticalCenter
    width: track.width * root.progress
    height: track.height
    radius: track.radius
    color: root.fillColor

    Behavior on width {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
  }

  Repeater {
    model: root.tickCount > 1 ? root.tickCount : 0

    Rectangle {
      required property int index
      anchors.verticalCenter: track.verticalCenter
      x: Math.max(0, Math.min(track.width - width, track.width * (index / (root.tickCount - 1)) - width / 2))
      width: Math.max(1, Style.space(2))
      height: root.trackHeight + Style.space(4)
      radius: 1
      color: root.tickColor
    }
  }

  BorderSurface {
    anchors.verticalCenter: track.verticalCenter
    x: Math.max(0, Math.min(track.width - width, track.width * root.progress - width / 2))
    width: root.knobSize
    height: root.knobSize
    radius: root.knobSize / 2
    color: root.knobColor
    borderSpec: Border.flat(root.bar ? root.bar.background : "#101315", Math.max(1, Style.space(2)))
    scale: root._hot ? 1.15 : 1.0

    Behavior on x {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
    Behavior on scale {
      NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor

    // The value at <x> along the track, rounded when <integer>, kept in range.
    function valueAt(x) {
      var raw = root.minimum + Math.max(0, Math.min(track.width, x)) / track.width * root.range
      if (root.integer) raw = Math.round(raw)
      return Math.max(root.minimum, Math.min(root.maximum, raw))
    }

    function moveTo(next) {
      root.liveValue = next
      root.moved(next)
    }

    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = true
      moveTo(valueAt(mouse.x))
    }
    onPositionChanged: function(mouse) {
      if (root.dragging) moveTo(valueAt(mouse.x))
    }
    onReleased: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = false
      root.released(root.liveValue)
      settle.restart()
    }
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.rightClicked()
    }
    onWheel: function(wheel) {
      var next = Math.max(root.minimum, Math.min(root.maximum, root.liveValue + (wheel.angleDelta.y > 0 ? root.step : -root.step)))
      if (root.integer) next = Math.round(next)
      moveTo(next)
      root.released(next)
      settle.restart()
    }
  }
}
