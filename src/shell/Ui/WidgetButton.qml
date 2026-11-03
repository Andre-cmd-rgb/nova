import QtQuick
import qs.Commons
import qs.Commons as Commons

// A button on the bar: a label in the bar's font and colour, as tall as the
// bar is (as wide, on a bar that stands upright), with the bar's tooltip
// and a press from any mouse button. The bar keeps a list of its buttons, so
// a click on the bar under an open panel still reaches the one beneath it.
//
// <active> paints the label in <activeColor> (the bar's urgent colour) when
// <useActiveColor>. <dimmed> fades it, <concealed> hides it but keeps its
// place, and <keepSpace> keeps the place of a button with nothing to show.
// <fixedWidth> and <fixedHeight>, above zero, set the size.
Item {
  id: button

  property var bar: null
  property string text: ""
  property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property real fontSize: Style.font.body
  property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  property color activeColor: bar ? bar.urgent : Commons.Color.urgent
  property bool active: false
  property real horizontalMargin: 8.5
  property real verticalPadding: 6
  property real fixedWidth: -1
  property real fixedHeight: -1
  property real textRotation: 0
  property bool keepSpace: false
  property bool dimmed: false
  property bool concealed: false
  property bool interactive: true
  property bool pressable: true
  property bool useActiveColor: true
  // While the pointer is over a button with this set, <revealHost> keeps
  // the bar's hidden indicators shown.
  property bool maintainIndicatorReveal: false
  property bool labelVisible: true
  property bool hasVisualContent: text !== ""
  property var revealHost: bar
  property string tooltipText: ""

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property bool tooltipHovered: visible && interactive && !concealed && pointer.containsMouse
  // The drawn label's width, for bar chrome lined up with the words rather
  // than the slot round them; 0 without a label.
  readonly property real labelWidth: label.visible ? label.implicitWidth : 0

  // The colour of what the button shows.
  readonly property color _ink: active && useActiveColor ? activeColor : foreground
  // The bar this button is listed with, to take it off that list again.
  property var _listedWith: null

  signal pressed(int button)
  signal wheelMoved(int delta)

  // A press, the pointer's or one the bar passes on: the tooltip goes first.
  function triggerPress(which) {
    _hideTooltip()
    pressed(which)
  }

  function _hideTooltip() {
    if (bar) bar.hideTooltip(button)
  }

  function _unlist() {
    if (_listedWith && _listedWith.unregisterClickTarget) _listedWith.unregisterClickTarget(button)
  }

  function _relist() {
    _unlist()
    _listedWith = bar
    if (_listedWith && _listedWith.registerClickTarget) _listedWith.registerClickTarget(button)
  }

  function _pointerOver(over) {
    if (bar) {
      if (over) bar.showTooltip(button, tooltipText)
      else bar.hideTooltip(button)
    }
    if (maintainIndicatorReveal && revealHost && revealHost.setIndicatorItemHovered) revealHost.setIndicatorItemHovered(over)
  }

  visible: hasVisualContent || keepSpace
  opacity: !hasVisualContent || concealed ? 0 : dimmed ? 0.45 : 1
  implicitWidth: {
    if (fixedWidth > 0) return fixedWidth
    return vertical ? barSize : Math.max(12, label.implicitWidth + 2 * Style.spaceReal(horizontalMargin))
  }
  implicitHeight: {
    if (fixedHeight > 0) return fixedHeight
    return vertical ? Math.max(12, label.implicitHeight + 2 * Style.spaceReal(verticalPadding)) : barSize
  }

  onBarChanged: _relist()
  Component.onCompleted: _relist()
  Component.onDestruction: _unlist()

  // A button that hides, or stops taking the pointer, takes its tooltip.
  onVisibleChanged: if (!visible) _hideTooltip()
  onInteractiveChanged: if (!interactive) _hideTooltip()
  onConcealedChanged: if (concealed) _hideTooltip()

  Behavior on opacity {
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }

  Text {
    id: label
    anchors.centerIn: parent
    visible: button.labelVisible
    rotation: button.textRotation
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    text: button.text
    color: button._ink
    font.family: button.fontFamily
    font.pixelSize: button.fontSize

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
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: button.pressable ? Qt.PointingHandCursor : Qt.ArrowCursor
    onEntered: button._pointerOver(true)
    onExited: button._pointerOver(false)
    onClicked: function (mouse) {
      if (button.pressable) button.triggerPress(mouse.button)
    }
    onWheel: function (wheel) { button.wheelMoved(wheel.angleDelta.y) }
  }
}
