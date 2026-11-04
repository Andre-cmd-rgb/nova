import QtQuick
import "BarModel.js" as BarModel

// The bar being dragged to another edge, from its empty centre (Sections):
// the screen it is dragged on and the edge it would go to, which that
// screen's overlay shows as a bar there (ScreenBar). Let go on another
// edge, the bar is put there.
QtObject {
  required property Item bar

  property bool active: false
  property string edge: ""
  property var window: null
  property var screen: null

  function begin(from) {
    window = from
    screen = from ? from.screen : null
    edge = bar.position
    active = true
  }

  // The pointer at <point> on the screen.
  function follow(point) {
    if (active && screen) edge = BarModel.nearestEdge(point, screen.width, screen.height)
  }

  // Let go: put there when <drop>, else back where it was.
  function end(drop) {
    var to = active && drop ? edge : ""
    active = false
    edge = ""
    window = null
    screen = null
    if (to !== "" && to !== bar.position) bar.putOnEdge(to)
  }
}
