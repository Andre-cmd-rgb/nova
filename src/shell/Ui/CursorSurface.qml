import QtQuick
import qs.Commons
import qs.Commons as Commons

// The highlight behind a panel's row that the keyboard and the pointer both
// move to. The panel keeps one cursor for both: the pointer moves it, and a
// row lights up for <hasCursor> or <current>, never for the pointer being
// over it, so there is never more than one highlight on screen.
//
// The row under the cursor takes the hover-cursor fill and border, the
// current one (the network in use, say) the selected ones, and a <bordered>
// row the normal border at rest. <outline> is no longer read: rows that
// asked for a border alone take the same fill as the rest.
BorderSurface {
  property bool hasCursor: false
  property bool current: false
  property bool outline: false
  property bool bordered: false

  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color fill: Style.hoverFillFor(foreground, accent)
  property color currentFill: Style.selectedFillFor(foreground, accent)

  radius: Style.cornerRadius
  color: hasCursor ? fill : current ? currentFill : "transparent"
  borderSpec: hasCursor ? Border.controlSpec("hover-cursor", foreground, accent)
    : current ? Border.controlSpec("selected", foreground, accent)
    : bordered ? Border.controlSpec("normal", foreground, accent)
    : Border.none()

  Behavior on color {
    ColorAnimation { duration: 60 }
  }
}
