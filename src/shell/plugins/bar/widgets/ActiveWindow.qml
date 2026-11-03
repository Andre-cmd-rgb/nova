import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The focused window by its title, or by its app id when it has none, cut
// short past the entry's maxWidth (280 px when it names none). A side bar
// has no room for it. A click brings the window forward; a middle or right
// click closes it.
BarWidget {
  id: widget
  moduleName: "nova.active-window"

  readonly property var focused: ToplevelManager.activeToplevel
  readonly property string title: focused ? (focused.title || focused.appId || "") : ""
  readonly property real widest: Number(setting("maxWidth", 280))
  // The bar shows a tooltip only while its widget says the pointer is on it.
  readonly property bool tooltipHovered: visible && hover.containsMouse

  visible: !vertical && title !== ""
  implicitHeight: barSize
  implicitWidth: visible ? Math.min(widest, label.implicitWidth) + Style.spacing.controlPaddingX * 2 : 0

  Behavior on implicitWidth {
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  // The title, in what is left 8 px in from each end.
  Item {
    anchors { fill: parent; leftMargin: Style.space(8); rightMargin: Style.space(8) }
    clip: true

    Text {
      id: label
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      width: parent.width
      text: widget.title
      textFormat: Text.PlainText
      elide: Text.ElideRight
      opacity: 0.85
      color: widget.bar ? widget.bar.barForeground : Commons.Color.foreground
      font.family: widget.bar ? widget.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

    onEntered: if (widget.bar) widget.bar.showTooltip(widget, widget.title)
    onExited: if (widget.bar) widget.bar.hideTooltip(widget)
    // A click puts the tooltip away, as on the bar's buttons.
    onClicked: function(mouse) {
      if (widget.bar) widget.bar.hideTooltip(widget)
      if (!widget.focused) return
      if (mouse.button === Qt.LeftButton) widget.focused.activate()
      else widget.focused.close()
    }
  }
}
