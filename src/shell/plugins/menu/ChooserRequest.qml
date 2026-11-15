import QtQuick
import Quickshell

// The nova-menu-select waiting on the chooser, if one is. It reads the pick
// from one file once the shell makes the other: one whose chooser another
// takes the place of gets no pick, as cancelled, or it would wait for as
// long as the shell runs. Each answer is written by a process of its own,
// so that two can be at once.
QtObject {
  property string pickedPath: ""
  property string closedPath: ""

  // The caller now waiting, the one before answered as cancelled.
  function begin(picked, closed) {
    release()
    pickedPath = picked
    closedPath = closed
  }

  // Gives the caller <pick>, or nothing for null, cancelled; false when no
  // caller was waiting.
  function finish(pick) {
    if (closedPath === "") return false
    const cancelled = pick === null || pick === undefined
    const write = cancelled ? ': >"$3"' : 'printf "%s\\n" "$1" >"$2"; : >"$3"'
    Quickshell.execDetached(["bash", "-c", write, "bash", cancelled ? "" : String(pick), pickedPath, closedPath])
    pickedPath = ""
    closedPath = ""
    return true
  }

  function release() {
    finish(null)
  }
}
