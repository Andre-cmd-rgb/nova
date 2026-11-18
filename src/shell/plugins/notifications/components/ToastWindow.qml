import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons

// One screen's toasts, newest at the top, in its top right corner below the
// bar. The window covers the screen and keeps its size, so the
// compositor never stretches an old frame as toasts come and go; it takes no
// keys, and the pointer only over the toasts.
PanelWindow {
  id: window

  required property var service

  readonly property var shell: service.shell
  // The bar's room at the top, and the gap: its size as shown, or as set
  // while it is hidden or not there.
  readonly property int barRoom: (shell && shell.bar && !shell.bar.tucked ? Math.max(0, shell.bar.thickness)
    : Style.bar.sizeHorizontal) + Style.gapsOut

  visible: service.toasts.count > 0
  WlrLayershell.namespace: "nova-notifications"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  color: "transparent"
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region { item: stack }

  ColumnLayout {
    id: stack
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: window.barRoom
    anchors.rightMargin: Style.gapsOut
    spacing: Style.space(8)

    Repeater {
      model: window.service.toasts

      ToastCard {
        service: window.service
        Layout.alignment: Qt.AlignRight
      }
    }
  }
}
