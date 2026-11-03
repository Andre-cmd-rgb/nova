import QtQuick

// Tells a real move of the pointer from the hover events Qt sends when rows
// slide under a pointer that stands still. A row's MouseArea asks moved()
// from onPositionChanged before it takes the cursor; a panel calls reset()
// when the keyboard or the list moves the rows, and allowInitialSample()
// when the pointer itself caused the change, so the row under it is taken
// at once.
QtObject {
  // Whose coordinates the pointer is followed in; the row's own without one.
  property Item referenceItem: null
  // How far the pointer must go, across or down, to have moved.
  property real threshold: 1

  // The last point taken as a move, or null since a reset.
  property var _last: null
  // Whether the first point after a reset counts as a move.
  property bool _firstCounts: false

  function reset() {
    _last = null
    _firstCounts = false
  }

  function allowInitialSample() {
    _last = null
    _firstCounts = true
  }

  // Whether the pointer at <mouse> over <item> has moved since the last
  // move taken. The first point after a reset only sets where it stands,
  // unless allowInitialSample() let it count.
  function moved(item, mouse) {
    if (!item || !mouse) {
      reset()
      return false
    }
    const at = item.mapToItem(referenceItem || item, mouse.x, mouse.y)
    const first = _last === null
    const far = !first && (Math.abs(at.x - _last.x) > threshold || Math.abs(at.y - _last.y) > threshold)
    // A step within the threshold is not taken, so the steps of a slow move
    // add up until they cross it.
    if (first || far) _last = at
    const counts = first ? _firstCounts : far
    _firstCounts = false
    return counts
  }
}
