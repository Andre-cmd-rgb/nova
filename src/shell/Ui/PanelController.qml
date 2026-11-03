import QtQuick

// Whether a panel is open, held apart from the panel itself: Panel keeps one
// as its <controller>, and a plugin that opens its panel its own way calls
// show() and hide() on it.
QtObject {
  property bool open: false

  // Showing a panel that is open writes nothing, so a binding on <open>
  // survives it.
  function show() {
    if (!open) open = true
  }

  function hide() {
    open = false
  }

  function toggle() {
    open = !open
  }
}
