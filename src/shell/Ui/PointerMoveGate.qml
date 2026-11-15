import QtQuick

// Tells a real move of the pointer from the hover events Qt sends when rows
// slide under a pointer that stands still. A row's MouseArea asks moved()
// from onPositionChanged before it takes the cursor; a panel calls
// rowsMoved() when the keyboard or the list moves the rows, and
// rowsMoved(true) when the pointer itself moved them, so that the row under
// it is taken at once.
QtObject {
  // Whose coordinates the pointer is followed in; the row's own without one.
  property Item within: null

  // Where the pointer last moved to, or null since a reset, and whether the
  // first point after the reset is a move.
  property var _from: null
  property bool _firstMoves: false

  function rowsMoved(byPointer) {
    _from = null
    _firstMoves = !!byPointer
  }

  // Whether the pointer at <mouse> over <item> has moved, more than a pixel
  // across or down, from where it last moved to. The first point after a
  // reset only marks where it stands, unless the pointer moved the rows. A
  // smaller step does not mark the spot, so the steps of a slow move add up
  // until they cross the pixel.
  function moved(item, mouse) {
    if (!item || !mouse) {
      rowsMoved()
      return false
    }
    const at = item.mapToItem(within || item, mouse.x, mouse.y)
    let moves = _firstMoves
    if (_from === null) _from = at
    else {
      moves = Math.abs(at.x - _from.x) > 1 || Math.abs(at.y - _from.y) > 1
      if (moves) _from = at
    }
    _firstMoves = false
    return moves
  }
}
