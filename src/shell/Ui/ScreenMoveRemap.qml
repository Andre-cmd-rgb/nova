import QtQuick

// When a monitor moves in the layout (undocking turns the laptop's panel
// off, and the external monitor slides to x=0), Hyprland leaves a layer
// surface that is already mapped where it was: the bar and the background
// stay at the old offset, or off the screen, until they are mapped again.
// This watches the screen of <window> and, once it has stopped moving,
// sets <remapping> for a moment; the window folds it into its visible
// binding (visible: shown && !remap.remapping) and is mapped afresh where
// the monitor now is.
Item {
  id: root

  required property var window
  readonly property var screen: window ? window.screen : null
  property bool remapping: false

  visible: false

  // A change of layout can move a monitor more than once; one remap, once
  // it has been still for a fifth of a second.
  Timer {
    id: settled
    interval: 200
    onTriggered: root.remapping = true
  }

  // Unmapped long enough for the compositor to see the unmap before the
  // map, rather than folding the two into nothing.
  Timer {
    interval: 50
    running: root.remapping
    onTriggered: root.remapping = false
  }

  Connections {
    target: root.screen
    function onXChanged() { settled.restart() }
    function onYChanged() { settled.restart() }
  }
}
