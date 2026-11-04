import QtQuick
import qs.Commons
import qs.Commons as Commons

// What lights the row of a panel that the keyboard and the pointer both move
// to. The panel keeps one cursor for the two: the pointer moves it, and a row
// lights for <hasCursor> or <current>, never for the pointer being over it,
// so one row at most is lit.
//
// The row with the cursor takes <fill> and the hover-cursor border; the
// current one (the network in use, say) <currentFill> and the selected
// border; any other row is clear, with no border.
ControlFace {
  property bool hasCursor: false
  property bool current: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color fill: Style.hoverFillFor(foreground, accent)
  property color currentFill: Style.selectedFillFor(foreground, accent)

  tint: foreground
  tintAccent: accent
  fade: 60
  restColor: hasCursor ? fill : current ? currentFill : "transparent"
  edgeState: hasCursor ? "hover-cursor" : current ? "selected" : ""
  radius: Style.cornerRadius
}
