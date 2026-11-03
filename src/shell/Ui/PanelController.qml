import QtQuick

// Whether a panel is open, kept apart from the panel's own properties. Panel
// holds one as its controller and opens and closes it.
QtObject {
  property bool open: false

  // Opening an open panel leaves <open> alone, so a binding on it stays.
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
