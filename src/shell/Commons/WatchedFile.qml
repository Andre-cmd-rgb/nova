import QtQuick
import Quickshell.Io

// A file followed as it changes, with no clock: loaded() or loadFailed()
// (no file) at each change, as a FileView says them.
//
// A FileView with watchChanges hears a file made, written, replaced by a
// rename or removed, in a folder that is there as it starts to watch. What
// it does not do (Quickshell 0.3.2) is read again when asked while a read
// of the same file is under way: reload() then does nothing, and a change
// that lands during that read is not read until the next one comes. So a
// load that followed a change is followed by one more, a moment later,
// which finds the file as the last change left it; a change heard during
// that one asks for another. Measured with bursts of quick writes, renames
// and removals, 250 to 300 of each kind: a plain FileView was left on an
// old reading after about one burst in forty, this after none
// (tests/qml/watched-file-test.qml keeps a shorter run of them). A file
// removed just as it is opened is warned of, whatever printErrors says.
FileView {
  id: file

  watchChanges: true
  printErrors: false

  // The changes heard, and how many of them a load since has answered.
  property int heard: 0
  property int answered: 0

  onFileChanged: {
    heard++
    reload()
  }
  onLoaded: settle()
  onLoadFailed: settle()

  function settle() {
    if (answered === heard) return
    answered = heard
    again.restart()
  }

  property Timer again: Timer {
    interval: 200
    onTriggered: file.reload()
  }
}
