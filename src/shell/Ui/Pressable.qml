import QtQuick
import qs.Commons

// What Button and PanelActionButton have in common: a ControlFace that is
// clicked. The left button clicks it; where <_buttons> takes the right one
// too, a right press is the button's but clicks nothing. With
// <tabStop> it is a Tab stop: Return, Enter and Space click it, a click
// gives it the focus, and <_ringed> says it shows the focus state.
// <hasCursor> is the panel's cursor on it; <bordered> asks for the normal
// border at rest. <tooltipText>, when set, shows under the pointer.
ControlFace {
  id: pressable

  property string iconText: ""
  property string tooltipText: ""
  property string fontFamily: Style.font.family
  property bool tabStop: false
  property bool hasCursor: false
  property bool bordered: false

  readonly property bool _ringed: tabStop && activeFocus
  readonly property alias _pointer: pointer
  readonly property alias _tip: tip
  property int _buttons: Qt.LeftButton

  signal clicked()
  signal hovered(bool isHovered)

  radius: Style.cornerRadius
  activeFocusOnTab: tabStop

  // The keys are taken even when the control is not a Tab stop, so a key
  // meant to click it never reaches what is behind it.
  Keys.onPressed: function (event) {
    if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Space) return
    event.accepted = true
    if (tabStop) clicked()
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: pressable._buttons
    cursorShape: Qt.PointingHandCursor
    onClicked: function (mouse) {
      if (pressable.tabStop) pressable.forceActiveFocus()
      if (mouse.button !== Qt.RightButton) pressable.clicked()
    }
  }

  PanelToolTip {
    id: tip
    visible: pressable.tooltipText !== "" && pointer.containsMouse
    text: pressable.tooltipText
    fontFamily: pressable.fontFamily
  }
}
