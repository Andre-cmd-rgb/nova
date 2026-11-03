import QtQuick

// A one-pixel outline in <tone> round its parent, drawn only to line icons
// up by eye (NOVA_DEBUG_BAR_ICONS=1).
Rectangle {
  property color tone

  anchors.fill: parent
  color: "transparent"
  border.width: 1
  border.color: tone
}
