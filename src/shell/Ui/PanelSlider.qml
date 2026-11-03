import QtQuick
import qs.Commons
import qs.Commons as Commons

// A slider for a panel: a track filled up to the value, with a round knob
// that grows a little under the pointer. The left button drags it, sending
// moved() along the way and released() at the end; a wheel notch moves it
// by <step> and sends both. <integer> keeps the value whole. A right click
// sends rightClicked(), which audio uses to mute the slider's channel.
//
// The knob is drawn at <liveValue>: <value>, or where the user has put it.
// A caller may change <value> only once the change has taken (Settings
// waits for its state file), so the knob stays where it was let go; a value
// that has not come within three seconds was refused, and the knob goes
// back to it.
Item {
  id: slider

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
  property real liveValue: value

  // With <tickCount> above 1, that many notches spread evenly along the
  // track in the panel's background, seen only where they cross it. They
  // are only drawn: a caller that wants the value on them snaps it itself.
  property int tickCount: 0
  property color tickColor: bar ? bar.background : Commons.Color.background

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))

  signal moved(real value)
  signal released(real value)
  signal rightClicked()

  // The value at <x> along the track, whole when <integer>, within range.
  function _valueAt(x) {
    var along = Math.max(0, Math.min(track.width, x))
    var raw = minimum + along / track.width * range
    if (integer) raw = Math.round(raw)
    return Math.max(minimum, Math.min(maximum, raw))
  }

  function _moveTo(next) {
    liveValue = next
    moved(next)
  }

  // The user is done with <final>; <value> has three seconds to follow.
  function _letGo(final) {
    released(final)
    waitForValue.restart()
  }

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), knobSize + Style.spacing.md)

  // A new value moves the knob, unless the user is holding it.
  onValueChanged: {
    if (dragging) return
    liveValue = value
    waitForValue.stop()
  }

  Timer {
    id: waitForValue
    interval: 3000
    onTriggered: if (!slider.dragging) slider.liveValue = slider.value
  }

  // Everything drawn along the track lies in it: the fill, the notches over
  // the fill, and the knob over both.
  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width
    height: slider.trackHeight
    radius: height / 2
    color: slider.trackColor

    Rectangle {
      width: track.width * slider.progress
      height: track.height
      radius: track.radius
      color: slider.fillColor

      Behavior on width {
        enabled: !slider.dragging
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }

    Repeater {
      model: slider.tickCount > 1 ? slider.tickCount : 0

      Rectangle {
        required property int index
        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(0, Math.min(track.width - width, track.width * (index / (slider.tickCount - 1)) - width / 2))
        width: Math.max(1, Style.space(2))
        height: slider.trackHeight + Style.space(4)
        radius: 1
        color: slider.tickColor
      }
    }

    BorderSurface {
      anchors.verticalCenter: parent.verticalCenter
      x: Math.max(0, Math.min(track.width - width, track.width * slider.progress - width / 2))
      width: slider.knobSize
      height: slider.knobSize
      radius: slider.knobSize / 2
      color: slider.knobColor
      borderSpec: Border.flat(slider.bar ? slider.bar.background : "#101315", Math.max(1, Style.space(2)))
      scale: pointer.containsMouse || slider.dragging ? 1.15 : 1.0

      Behavior on x {
        enabled: !slider.dragging
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
      Behavior on scale {
        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
      }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor

    onPressed: function (mouse) {
      if (mouse.button !== Qt.LeftButton) return
      slider.dragging = true
      slider._moveTo(slider._valueAt(mouse.x))
    }
    onPositionChanged: function (mouse) {
      if (slider.dragging) slider._moveTo(slider._valueAt(mouse.x))
    }
    onReleased: function (mouse) {
      if (mouse.button !== Qt.LeftButton) return
      slider.dragging = false
      slider._letGo(slider.liveValue)
    }
    onClicked: function (mouse) {
      if (mouse.button === Qt.RightButton) slider.rightClicked()
    }
    onWheel: function (wheel) {
      var next = Math.max(slider.minimum, Math.min(slider.maximum, slider.liveValue + (wheel.angleDelta.y > 0 ? slider.step : -slider.step)))
      if (slider.integer) next = Math.round(next)
      slider._moveTo(next)
      slider._letGo(next)
    }
  }
}
