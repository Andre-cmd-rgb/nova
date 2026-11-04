import QtQuick
import qs.Ui

// Nova's star in the bar: a click opens the menu at its top, or closes it;
// a right click opens a terminal.
BarWidget {
  id: widget

  readonly property string toggleMenu: "nova-shell shell toggle nova.menu '{\"menu\":\"root\"}'"
  readonly property string openTerminal: "xdg-terminal-exec"

  implicitWidth: star.implicitWidth
  implicitHeight: star.implicitHeight

  WidgetButton {
    id: star
    anchors.fill: parent
    bar: widget.bar
    // Material Design's star-four-points (U+F0AE2), in the bar's Nerd Font.
    text: "󰫢"
    horizontalMargin: 7.5
    onPressed: which => widget.bar?.run(which === Qt.RightButton ? widget.openTerminal : widget.toggleMenu)
  }
}
