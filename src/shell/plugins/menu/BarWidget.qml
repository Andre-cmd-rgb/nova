import QtQuick
import qs.Ui

// The menu's button in the bar: a click opens the menu at its top, or
// closes it, and a right click opens a terminal.
BarWidget {
  id: root
  moduleName: "nova.menu"

  implicitWidth: star.implicitWidth
  implicitHeight: star.implicitHeight

  WidgetButton {
    id: star
    anchors.fill: parent
    bar: root.bar
    // The nova, a four-pointed star: Material Design's star-four-points
    // (U+F0AE2), in the bar's own Nerd Font.
    text: "󰫢"
    horizontalMargin: 7.5
    onPressed: function(button) {
      if (root.bar) root.bar.run(button === Qt.RightButton ? "xdg-terminal-exec" : "nova-shell shell toggle nova.menu '{\"menu\":\"root\"}'")
    }
  }
}
