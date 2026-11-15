import QtQuick
import qs.Commons
import qs.Commons as Commons

// What lights a row of a panel that the keyboard and the pointer both move
// to. The panel keeps one cursor for the two: the pointer moves it, and a
// row lights for <hasCursor> or <current>, never for the pointer being over
// it, so one row at most is lit.
//
// The row with the cursor is lit in <fill> with the hover-cursor border;
// the current one (the network in use, say) in <currentFill> with the
// selected border; any other row is clear and unbordered.
ControlFace {
  property bool hasCursor: false
  property bool current: false
  property color foreground: Commons.Color.foreground
  property color fill: Style.hoverFillFor(foreground, Commons.Color.accent)
  property color currentFill: Style.selectedFillFor(foreground, Commons.Color.accent)

  // How the row is lit, if at all, as a control state.
  readonly property string _lit: hasCursor ? "hover-cursor" : current ? "selected" : ""

  tint: foreground
  radius: Style.cornerRadius
  edgeState: _lit
  restColor: _lit === "hover-cursor" ? fill : _lit === "selected" ? currentFill : "transparent"
  fade: 60
}
