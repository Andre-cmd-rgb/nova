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
  // there, on the screen.
  property Item target: null
  property bool after: false
  property var line: null

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
    var widget = taken.activeItem
    if (widget && typeof widget.grabToImage === "function") {
      var width = Math.max(1, Math.ceil(widget.width || widget.implicitWidth || taken.width || 1))
      var height = Math.max(1, Math.ceil(widget.height || widget.implicitHeight || taken.height || 1))
      widget.grabToImage(function(result) {
        if (drag.slot === taken && result && result.url) drag.picture = result.url
      }, Qt.size(width, height))
    }
    slot = taken
  }

  // The pointer at <scenePoint> in the window of <taken>.
  function follow(taken, scenePoint) {
    var onScreen = bar.screenPoint(scenePoint, window)
    pointer = Qt.point(onScreen.x, onScreen.y)
    var place = placeAt(scenePoint, taken)
    target = place ? place.slot : null
    after = place ? place.after : false
    line = place ? lineAt(place.slot, place.after) : null
  }

  // The place before or after a widget of the dragged one's bar nearest the
  // pointer; none with the pointer off that bar.
  function placeAt(scenePoint, taken) {
    var home = bar.windowOf(taken) || window
    if (home && home.contentItem) {
      var inside = home.contentItem.mapFromItem(null, scenePoint.x, scenePoint.y)
      if (inside.x < 0 || inside.y < 0 || inside.x > home.contentItem.width || inside.y > home.contentItem.height) return null
    }
    var places = []
    bar.moduleSlots.forEach(function(other) {
      if (!other || other === taken || !other.visible || other.width <= 0 || other.height <= 0) return
      if (home && !bar.sameBar(bar.windowOf(other), home)) return
      var corner = { x: other.x, y: other.y }
      try {
        corner = other.mapToItem(null, 0, 0)
      } catch (e) {
      }
      places.push({ slot: other, x: corner.x, y: corner.y, width: other.width, height: other.height })
    })
    return BarModel.dropPlace(places, scenePoint, bar.vertical)
  }

  function lineAt(other, after) {
    try {
      var corner = bar.screenPoint(other.mapToItem(null, 0, 0), window)
      return BarModel.dropMarker(corner, other.width, other.height, after, bar.vertical, Style.spacing.xs)
    } catch (e) {
      return null
    }
  }

  // Saves <taken> dropped before <target>, or after it: before the next
  // widget shown on that bar, so that a hidden one in between stays where
  // it is. Whether it was saved.
  function drop(taken, target, after) {
    if (!taken || !target) return false
    var beforeId = after ? nextShown(target.section, target.moduleName, taken) : target.moduleName
    if (!taken.section || !taken.moduleName || !target.section) return false
    if (taken.section === target.section && taken.moduleName === beforeId) return false
    if (!bar.canSave()) return false
    var moved = false
    bar.shell.mutateShellConfig(function(config) {
      moved = BarModel.moveEntry(config, taken.section, taken.moduleName, target.section, beforeId)
    })
    return moved
  }

  // The first widget after <afterId> in <section> that the dragged one's
  // bar shows; "" for none.
  function nextShown(section, afterId, taken) {
    var home = bar.windowOf(taken) || window
    var entries = bar.builtLayout[section] || []
    var at = BarModel.indexOfId(entries, afterId)
    for (var i = at === -1 ? entries.length : at + 1; i < entries.length; i++) {
      var id = BarModel.entryId(entries[i])
      var shown = bar.moduleSlots.some(function(other) {
        return !!other && other !== taken && other.section === section && other.moduleName === id
          && other.visible && other.width > 0 && other.height > 0 && (!home || bar.sameBar(bar.windowOf(other), home))
      })
      if (shown) return id
    }
    return ""
  }
}
