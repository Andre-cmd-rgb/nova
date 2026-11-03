import QtQuick
import qs.Commons
import qs.Commons as Commons

// A small icon button, 22 pixels square by default, for the actions at the
// end of a panel's row: forget a network, confirm a passphrase, unpair a
// device. Under the pointer it takes the hover fill in <hoverColor>: the
// foreground by default, the bar's urgent colour for an action that
// destroys something. Disabled, it takes no clicks and its icon dims.
//
// The pointer over it moves no panel cursor: the row it sits in is what the
// cursor is on. Where the button is the cursor's target itself, the panel
// sets <hasCursor> to light it as the pointer would, and follows the
// pointer through hovered(). <focusable> makes it a Tab stop with the focus
// state, for forms walked with Tab; the actions on a row leave it off, as
// the row's CursorSurface has the keyboard.
BorderSurface {
  id: root

  property string iconText: ""
  property string tooltipText: ""
  property color foreground: Commons.Color.foreground
  property color hoverColor: foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.icon
  property real size: Math.max(Style.space(22), fontSize + Style.spacing.sm * 2)
  property bool focusable: false
  property bool hasCursor: false
  property bool bordered: false

  readonly property bool _showFocusRing: focusable && activeFocus
  readonly property bool _hot: (pointer.containsMouse || hasCursor) && enabled
  readonly property var _borderSpec: {
    if (_showFocusRing) return Border.controlSpec("focus", hoverColor, hoverColor)
    if (!bordered) return Border.none()
    return _hot ? Border.controlSpec("hover-cursor", hoverColor, hoverColor) : Border.controlSpec("normal", foreground, Commons.Color.accent)
  }

  signal clicked()
  signal hovered(bool isHovered)

  implicitWidth: size
  implicitHeight: size
  radius: Style.cornerRadius
  color: _showFocusRing ? Style.focusFillFor(hoverColor, hoverColor)
    : _hot ? Style.hoverFillFor(hoverColor, hoverColor)
    : "transparent"
  borderSpec: _borderSpec

  activeFocusOnTab: focusable
  Keys.onReturnPressed: if (focusable) root.clicked()
  Keys.onEnterPressed: if (focusable) root.clicked()
  Keys.onSpacePressed: if (focusable) root.clicked()

  Behavior on color {
    ColorAnimation { duration: 60 }
  }

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.iconText
    color: !root.enabled ? Qt.darker(root.foreground, 2.0) : root._hot ? root.hoverColor : root.foreground
    font { family: root.fontFamily; pixelSize: root.fontSize }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    enabled: root.enabled
    hoverEnabled: true
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onContainsMouseChanged: root.hovered(containsMouse)
    onClicked: {
      if (root.focusable) root.forceActiveFocus()
      root.clicked()
    }
  }

  PanelToolTip {
    visible: root.tooltipText !== "" && pointer.containsMouse
    text: root.tooltipText
    fontFamily: root.fontFamily
  }
}
