import QtQuick

// Tells a real move of the pointer from the hover events Qt sends when rows
// slide under a pointer that stands still. A row's MouseArea asks moved()
// from onPositionChanged before it takes the cursor; a panel calls reset()
// when the keyboard or the list moves the rows, and allowInitialSample()
// when the pointer itself caused the change, so the row under it is taken
// at once.
QtObject {
  property Item referenceItem: null
  property real threshold: 1
  property bool primed: false
  property bool initialSampleAllowed: false
  property real lastX: 0
  property real lastY: 0

  function reset() {
    primed = false
    initialSampleAllowed = false
    lastX = 0
    lastY = 0
  }

  function allowInitialSample() {
    reset()
    initialSampleAllowed = true
  }

  // Whether the pointer at <mouse> over <item> has moved more than
  // <threshold> since the last move taken, in <referenceItem>'s coordinates
  // (the item's own when there is none). The first sample after a reset only
  // counts when allowInitialSample() allowed it.
  function moved(item, mouse) {
    if (!item || !mouse) {
      reset()
      return false
    }
    var point = item.mapToItem(referenceItem || item, mouse.x, mouse.y)
    var moving = primed
      ? Math.abs(point.x - lastX) > threshold || Math.abs(point.y - lastY) > threshold
      : initialSampleAllowed
    // A step within the threshold is not taken, so the steps of a slow move
    // add up until they cross it.
    if (moving || !primed) {
      lastX = point.x
      lastY = point.y
    }
    primed = true
    initialSampleAllowed = false
    return moving
  }
}
