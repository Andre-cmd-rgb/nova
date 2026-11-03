import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The focused window's title, cut short past `maxWidth` (280 px), or its app
// id when it has none; nothing on a side bar. A click focuses the window, a
// middle or right click closes it.
BarWidget {
  id: root
  moduleName: "nova.active-window"

  readonly property var toplevel: ToplevelManager.activeToplevel
  readonly property string title: toplevel ? (toplevel.title || toplevel.appId || "") : ""

  visible: title !== "" && !vertical
  implicitWidth: visible ? Math.min(Number(setting("maxWidth", 280)), label.implicitWidth) + Style.spacing.controlPaddingX * 2 : 0
  implicitHeight: barSize

  Behavior on implicitWidth { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  Item {
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    clip: true

    Text {
      id: label
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      text: root.title
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.bar ? root.bar.barForeground : Commons.Color.foreground
      opacity: 0.85
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor

    onClicked: function(mouse) {
      if (!root.toplevel) return
      if (mouse.button === Qt.LeftButton) root.toplevel.activate()
      else root.toplevel.close()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.title)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}
