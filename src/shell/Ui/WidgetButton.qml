import QtQuick
import qs.Commons
import qs.Commons as Commons

// A button on the bar: a label in the bar's font and colour, a press from any
// mouse button, and the bar's tooltip while the pointer rests on it.
//
// Across the bar it is as thick as the bar; along it, as long as its label
// and <horizontalMargin> (<verticalPadding> on an upright bar) either side.
// <fixedWidth> and <fixedHeight>, above zero, size it instead. An <active>
// button's label is the bar's urgent colour. <concealed> hides it but keeps
// its place, as <keepSpace> keeps the place of one with nothing to show.
//
// The bar lists its buttons, so that a click on the bar under an open panel
// still finds the one beneath it: each button puts itself on the list of the
// bar it is given, and takes itself off again.
Item {
  id: button

  property var bar: null
  property string text: ""
  property string tooltipText: ""
  property bool active: false

  property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property real fontSize: Style.font.body
  property real textRotation: 0
  property bool labelVisible: true

  property bool hasVisualContent: text !== ""
  property bool keepSpace: false
  property bool concealed: false
  property bool interactive: true

  property real horizontalMargin: 8.5
  property real verticalPadding: 6
  property real fixedWidth: -1
  property real fixedHeight: -1

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  // The bar's tooltip shows only for a button the pointer is on and that
  // can be seen and pressed.
  readonly property bool tooltipHovered: visible && interactive && !concealed && pointer.containsMouse
  // The label's own width, for bar chrome lined up with the words rather
  // than the slot round them; 0 with no label.
  readonly property real labelWidth: label.visible ? label.implicitWidth : 0

  // What the label (or a glyph in its place) is drawn in.
  property color _ink: active ? (bar ? bar.urgent : Commons.Color.urgent) : foreground
  property var _listedOn: null

  signal pressed(int button)
  signal wheelMoved(int delta)
  // The pointer came onto the button, or left it, after the tooltip was
  // asked for or taken back.
  signal crossed(bool over)

  // A press, from the pointer or passed on by the bar: the tooltip goes
  // before the press is handled.
  function triggerPress(which) {
    _withdrawTip()
    pressed(which)
  }

  function _withdrawTip() {
    if (bar) bar.hideTooltip(button)
  }

  // Off the list it is on, and onto <target>'s.
  function _listOn(target) {
    if (_listedOn && _listedOn.unregisterClickTarget) _listedOn.unregisterClickTarget(button)
    _listedOn = target
    if (target && target.registerClickTarget) target.registerClickTarget(button)
  }

  // Its length along the bar for content <size> long, with <margin> at each
  // end.
  function _alongBar(size, margin) {
    return Math.max(12, size + 2 * Style.spaceReal(margin))
  }

  visible: hasVisualContent || keepSpace
  opacity: !hasVisualContent || concealed ? 0 : 1
  implicitWidth: fixedWidth > 0 ? fixedWidth : vertical ? barSize : _alongBar(label.implicitWidth, horizontalMargin)
  implicitHeight: fixedHeight > 0 ? fixedHeight : vertical ? _alongBar(label.implicitHeight, verticalPadding) : barSize

  Component.onCompleted: _listOn(bar)
  Component.onDestruction: _listOn(null)
  onBarChanged: _listOn(bar)
  // Hidden, concealed, made inert, or left: the tooltip goes with it.
  onTooltipHoveredChanged: if (!tooltipHovered) _withdrawTip()

  Behavior on opacity {
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }

  Text {
    id: label
    visible: button.labelVisible
    anchors.centerIn: parent
    rotation: button.textRotation
    text: button.text
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    color: button._ink

    // Off while the bar changes all its colours at once.
    Behavior on color {
      enabled: !button.bar || button.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 160 }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    enabled: button.interactive
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onEntered: {
      if (button.bar) button.bar.showTooltip(button, button.tooltipText)
      button.crossed(true)
    }
    onExited: button.crossed(false)
    onClicked: function (mouse) { button.triggerPress(mouse.button) }
    onWheel: function (wheel) { button.wheelMoved(wheel.angleDelta.y) }
  }
}
