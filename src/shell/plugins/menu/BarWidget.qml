import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "nova.menu"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A four-point star, the nova: Material Design's star-four-points (U+F0AE2)
    // in the bar's own Nerd Font, so it needs no font of its own.
    text: "\udb82\udee2"
    horizontalMargin: 7.5
    onPressed: function(button) {
      if (!root.bar) return
      if (button === Qt.RightButton) root.bar.run("xdg-terminal-exec")
      else root.bar.run("nova-shell shell toggle nova.menu '{\"menu\":\"root\"}'")
    }
  }
}
