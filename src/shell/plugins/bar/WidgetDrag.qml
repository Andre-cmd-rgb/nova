import QtQuick
import qs.Commons
import "BarModel.js" as BarModel

// A widget being dragged to another place on its bar: its slot, a picture
// of it, where the pointer holds it, and the place it would land. The
// overlay of the screen it is dragged on draws the picture and the place
// (ScreenBar). Dropped, the move is saved through the shell, and the bar
// is built again from the new layout.
QtObject {
  id: drag

  required property Item bar

  property Item slot: null
  property var window: null
  property var screen: null
  property url picture: ""
  // Where on the widget the pointer took it, and the pointer on the screen.
  property point grip: Qt.point(0, 0)
  property point pointer: Qt.point(0, 0)
  // The place it would land: before or after <target>, and the line drawn
  // there, on the screen, <lineWidth> across.
  property Item target: null
  property bool after: false
  property var line: null
  readonly property int lineWidth: Style.spacing.xs

  function clear() {
    slot = null
    window = null
    screen = null
    picture = ""
    grip = Qt.point(0, 0)
    pointer = Qt.point(0, 0)
    target = null
    after = false
    line = null
  }

  // Taken up at <x>, <y> in <taken>.
  function begin(taken, x, y) {
    window = bar.windowOf(taken)
    screen = window ? window.screen : null
    grip = Qt.point(x, y)
    picture = ""
    const widget = taken.widget
    if (widget && typeof widget.grabToImage === "function") {
      const width = Math.max(1, Math.ceil(widget.width || widget.implicitWidth || taken.width || 1))
      const height = Math.max(1, Math.ceil(widget.height || widget.implicitHeight || taken.height || 1))
      widget.grabToImage(result => {
        if (drag.slot === taken && result && result.url) drag.picture = result.url
      }, Qt.size(width, height))
    }
    slot = taken
  }

  // The pointer at <scenePoint> in the window of <taken>.
  function follow(taken, scenePoint) {
    const onScreen = bar.screenPoint(scenePoint, window)
    pointer = Qt.point(onScreen.x, onScreen.y)
    const place = placeAt(scenePoint, taken)
    target = place ? place.slot : null
    after = place ? place.after : false
    line = place ? lineAt(place.slot, place.after) : null
  }

  // Whether <other> is a widget shown on the bar <taken> is dragged on, to
  // land beside.
  function beside(other, taken) {
    const home = bar.windowOf(taken) || window
    return other !== taken && BarModel.isDrawn(other) && (!home || bar.sameBar(bar.windowOf(other), home))
  }

  // The place before or after a widget of the dragged one's bar nearest the
  // pointer; none with the pointer off that bar.
  function placeAt(scenePoint, taken) {
    const home = bar.windowOf(taken) || window
    if (home && home.contentItem) {
      const inside = home.contentItem.mapFromItem(null, scenePoint.x, scenePoint.y)
      if (inside.x < 0 || inside.y < 0 || inside.x > home.contentItem.width || inside.y > home.contentItem.height) return null
    }
    const places = bar.slots.filter(other => beside(other, taken)).map(other => {
      let corner = { x: other.x, y: other.y }
      try {
        corner = other.mapToItem(null, 0, 0)
      } catch (e) {
      }
      return { slot: other, x: corner.x, y: corner.y, width: other.width, height: other.height }
    })
    return BarModel.dropPlace(places, scenePoint, bar.vertical)
  }

  function lineAt(other, after) {
    try {
      const corner = bar.screenPoint(other.mapToItem(null, 0, 0), window)
      return BarModel.dropMarker(corner, other.width, other.height, after, bar.vertical, lineWidth)
    } catch (e) {
      return null
    }
  }

  // Saves <taken> dropped before <target>, or after it: before the next
  // widget shown on that bar, so that a hidden one in between stays where
  // it is. Whether it was saved.
  function drop(taken, target, after) {
    if (!taken || !target) return false
    const beforeId = after ? nextShown(target.section, target.widgetId, taken) : target.widgetId
    if (!taken.section || !taken.widgetId || !target.section) return false
    if (taken.section === target.section && taken.widgetId === beforeId) return false
    if (!bar.saves) return false
    let moved = false
    bar.shell.mutateShellConfig(config => {
      moved = BarModel.moveEntry(config, taken.section, taken.widgetId, target.section, beforeId)
    })
    return moved
  }

  // The first widget after <afterId> in <section> that the dragged one's
  // bar shows; "" for none.
  function nextShown(section, afterId, taken) {
    const entries = bar.layout[section] || []
    const at = BarModel.indexOfId(entries, afterId)
    const later = entries.slice(at === -1 ? entries.length : at + 1).map(entry => BarModel.entryId(entry))
    return later.find(id => bar.slots.some(other => other.section === section && other.widgetId === id && beside(other, taken))) || ""
  }
}
