import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The focused window by its title, or by its app id when it has none, cut
// short past the entry's maxWidth (280 px when it names none). A click
// brings the window forward; a middle or right click closes it.
BarWidget {
  id: widget
  widgetId: "nova.active-window"

  readonly property var window: ToplevelManager.activeToplevel
  readonly property string title: window?.title || window?.appId || ""
  // The bar shows the tooltip only while this holds.
  readonly property bool pointedAt: visible && pointer.containsMouse

  visible: title !== ""
  implicitHeight: thickness
  implicitWidth: visible ? Math.min(Number(setting("maxWidth", 280)), line.implicitWidth) + Style.spacing.controlPaddingX * 2 : 0

  Behavior on implicitWidth {
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

    onEntered: widget.bar?.tip.ask(widget, widget.title)
    onExited: widget.bar?.tip.withdraw(widget)
    // A click puts the tooltip away, as on the bar's buttons.
    onClicked: mouse => {
      widget.bar?.tip.withdraw(widget)
      if (mouse.button === Qt.LeftButton) widget.window?.activate()
      else widget.window?.close()
    }

    // The title, cut to what is left 8 px in from each end: while the
    // widget grows or shrinks to a new one, it does not spill out.
    Item {
      readonly property real inset: Style.space(8)

      x: inset
      width: pointer.width - 2 * inset
      height: pointer.height
      clip: true

      Text {
        id: line
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter
        text: widget.title
        textFormat: Text.PlainText
        elide: Text.ElideRight
        opacity: 0.85
        color: widget.bar?.textColour ?? Commons.Color.foreground
        font { family: widget.bar?.fontFamily ?? Style.font.family; pixelSize: Style.font.body }
      }
    }
  }
}
