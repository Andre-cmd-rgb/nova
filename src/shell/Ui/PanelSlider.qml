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
//
// With <tickCount> above 1, that many notches lie evenly along the track in
// the panel's background, seen only where they cross it. They are only
// drawn: a caller that wants the value on them snaps it itself.
Item {
  id: slider

  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false
  property int tickCount: 0
  property real liveValue: value
  property bool dragging: false

  signal moved(real value)
  signal released(real value)
  signal rightClicked()

  // Its colours are the bar's: the fill and the knob its foreground, the
  // notches and the knob's rim its background.
  readonly property color _ink: bar ? bar.foreground : Commons.Color.foreground
  readonly property real _trackThickness: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
  readonly property real _knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))
  readonly property real _span: Math.max(0.0001, maximum - minimum)
  // How far along the track the knob is, from 0 to 1.
  readonly property real _fraction: Math.max(0, Math.min(1, (liveValue - minimum) / _span))

  function _within(n) {
    return Math.max(minimum, Math.min(maximum, n))
  }

  function _whole(n) {
    return integer ? Math.round(n) : n
  }

  // The value at <x> along the track.
  function _valueAt(x) {
    const along = Math.max(0, Math.min(track.width, x))
    return _within(_whole(minimum + along / track.width * _span))
  }

  // The knob put at <next> by the user.
  function _put(next) {
    liveValue = next
    moved(next)
  }

  // The user is done at <final>; <value> has three seconds to follow.
  function _done(final) {
    released(final)
    refused.restart()
  }

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), _knobSize + Style.spacing.md)

  // A new value moves the knob, unless the user is holding it.
  onValueChanged: {
    if (dragging) return
    liveValue = value
    refused.stop()
  }

  Timer {
    id: refused
    interval: 3000
    onTriggered: if (!slider.dragging) slider.liveValue = slider.value
  }

  // The track holds all that is drawn along it: the fill, the notches over
  // the fill, and the knob over both.
  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width
    height: slider._trackThickness
    radius: height / 2
    color: slider.bar ? Style.selectedFillFor(slider.bar.foreground, Commons.Color.accent) : "#333"

    Rectangle {
      width: track.width * slider._fraction
      height: track.height
      radius: track.radius
      color: slider._ink

      Behavior on width {
        enabled: !slider.dragging
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }

    Repeater {
      model: slider.tickCount > 1 ? slider.tickCount : 0

      Rectangle {
        required property int index
        readonly property real centre: track.width * (index / (slider.tickCount - 1))

        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(0, Math.min(track.width - width, centre - width / 2))
        width: Math.max(1, Style.space(2))
        height: slider._trackThickness + Style.space(4)
        radius: 1
        color: slider.bar ? slider.bar.background : Commons.Color.background
      }
    }

    BorderSurface {
      readonly property bool raised: pointer.containsMouse || slider.dragging

      anchors.verticalCenter: parent.verticalCenter
      x: Math.max(0, Math.min(track.width - width, track.width * slider._fraction - width / 2))
      width: slider._knobSize
      height: width
      radius: width / 2
      color: slider._ink
      borderSpec: Border.flat(slider.bar ? slider.bar.background : "#101315", Math.max(1, Style.space(2)))
      scale: raised ? 1.15 : 1.0

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
    // A drag that drifts up or down stays the slider's: in Settings the page's
    // Flickable took it, the release never came, and the knob stopped
    // following anything until the next press.
    preventStealing: true

    onPressed: function (mouse) {
      if (mouse.button !== Qt.LeftButton) return
      slider.dragging = true
      slider._put(slider._valueAt(mouse.x))
    }
    onPositionChanged: function (mouse) {
      if (slider.dragging) slider._put(slider._valueAt(mouse.x))
    }
    onReleased: function (mouse) {
      if (mouse.button !== Qt.LeftButton) return
      slider.dragging = false
      slider._done(slider.liveValue)
    }
    // Whatever else takes the press (a popup closing under it, say) ends the
    // drag where it was, as a release would.
    onCanceled: {
      if (!slider.dragging) return
      slider.dragging = false
      slider._done(slider.liveValue)
    }
    onClicked: function (mouse) {
      if (mouse.button === Qt.RightButton) slider.rightClicked()
    }
    onWheel: function (wheel) {
      const next = slider._whole(slider._within(slider.liveValue + (wheel.angleDelta.y > 0 ? slider.step : -slider.step)))
      slider._put(next)
      slider._done(next)
    }
  }
}
