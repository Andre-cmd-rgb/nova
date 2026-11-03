import QtQuick
import qs.Commons
import qs.Commons as Commons

// A bar widget's button: a label in the bar's font and colour, the bar's
// height across (its width when the bar stands upright), with a tooltip from
// the bar and a click on any button. The bar keeps a list of its buttons so
// a click on the bar under an open panel can still reach them.
//
// <active> paints the label in <activeColor> (the bar's urgent colour) when
// <useActiveColor>; <dimmed> fades it, <concealed> hides it while keeping
// its place, and <keepSpace> keeps the place of a button with nothing to
// show. <fixedWidth> and <fixedHeight> above zero override the size.
Item {
  id: root

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
  property bool maintainIndicatorReveal: false
  property bool labelVisible: true
  property bool hasVisualContent: text !== ""
  property var revealHost: bar
  property string tooltipText: ""
  property var registeredBar: null

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property real scaledHorizontalMargin: Style.spaceReal(horizontalMargin)
  readonly property real scaledVerticalPadding: Style.spaceReal(verticalPadding)
  readonly property bool tooltipHovered: visible && interactive && !concealed && pointer.containsMouse
  // The painted label's width, for bar chrome that lines up with the text
  // rather than the slot round it; 0 on a button with no label.
  readonly property real labelWidth: label.visible ? label.implicitWidth : 0

  signal pressed(int button)
  signal wheelMoved(int delta)

  // A press, from the pointer or from a click the bar passes on: the
  // tooltip goes first.
  function triggerPress(button) {
    if (bar) bar.hideTooltip(root)
    pressed(button)
  }

  function hideOwnTooltip() {
    if (bar) bar.hideTooltip(root)
  }

  // Moves the button's place in the click list to its current bar.
  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }

  visible: hasVisualContent || keepSpace
  opacity: !hasVisualContent || concealed ? 0 : dimmed ? 0.45 : 1
  implicitWidth: fixedWidth > 0 ? fixedWidth
    : vertical ? barSize
    : Math.max(12, label.implicitWidth + scaledHorizontalMargin * 2)
  implicitHeight: fixedHeight > 0 ? fixedHeight
    : vertical ? Math.max(12, label.implicitHeight + scaledVerticalPadding * 2)
    : barSize

  onBarChanged: syncClickRegistration()
  onVisibleChanged: if (!visible) hideOwnTooltip()
  onInteractiveChanged: if (!interactive) hideOwnTooltip()
  onConcealedChanged: if (concealed) hideOwnTooltip()
  Component.onCompleted: syncClickRegistration()
  Component.onDestruction: {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
  }

  Behavior on opacity {
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }

  Text {
    id: label
    anchors.centerIn: parent
    visible: root.labelVisible
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    rotation: root.textRotation
    text: root.text
    color: root.active && root.useActiveColor ? root.activeColor : root.foreground
    font { family: root.fontFamily; pixelSize: root.fontSize }

    // The bar turns this off while it changes colour all at once.
    Behavior on color {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 160 }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    enabled: root.interactive
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: root.pressable ? Qt.PointingHandCursor : Qt.ArrowCursor
    // While the pointer is over the button, the reveal host keeps the
    // hidden indicators shown.
    readonly property bool revealing: root.maintainIndicatorReveal && !!root.revealHost && !!root.revealHost.setIndicatorItemHovered
    onEntered: {
      if (root.bar) root.bar.showTooltip(root, root.tooltipText)
      if (revealing) root.revealHost.setIndicatorItemHovered(true)
    }
    onExited: {
      if (root.bar) root.bar.hideTooltip(root)
      if (revealing) root.revealHost.setIndicatorItemHovered(false)
    }
    onClicked: function(mouse) {
      if (root.pressable) root.triggerPress(mouse.button)
    }
    onWheel: function(wheel) { root.wheelMoved(wheel.angleDelta.y) }
  }
}
