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

  // Where the pointer last moved to, or null since a reset, and whether the
  // first point after the reset is a move.
  property var _from: null
  property bool _firstMoves: false

  function _restart(firstMoves) {
    _from = null
    _firstMoves = firstMoves
  }

  function reset() { _restart(false) }

  function allowInitialSample() { _restart(true) }

  // Whether the pointer at <mouse> over <item> has moved, more than a pixel
  // across or down, from where it last moved to. The first point after a
  // reset only marks where it stands, unless allowInitialSample() made it a
  // move. A smaller step does not mark the spot, so the steps of a slow
  // move add up until they cross the pixel.
  function moved(item, mouse) {
    if (!item || !mouse) {
      reset()
      return false
    }
    const at = item.mapToItem(referenceItem || item, mouse.x, mouse.y)
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
