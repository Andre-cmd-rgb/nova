import QtQuick
import Quickshell

// The request of a nova-menu-select waiting on the chooser: the file its pick
// goes to, and the one it waits for. A request another takes the place of is
// answered as cancelled, or its caller would wait for as long as the shell
// runs. Each answer is a process of its own, so that one and the new
// request's own can be written at once.
QtObject {
  id: request

  property string selectionFile: ""
  property string doneFile: ""
  readonly property bool active: doneFile !== ""

  function begin(selectionPath, donePath) {
    release()
    selectionFile = selectionPath
    doneFile = donePath
  }

  // Answered with the pick, or with none as cancelled. False when there was
  // no request to answer.
  function finish(selection) {
    if (!active) return false
    var selectionPath = selectionFile
    var donePath = doneFile
    selectionFile = ""
    doneFile = ""
    if (selection === null || selection === undefined) {
      Quickshell.execDetached(["bash", "-c", ': >"$1"', "bash", donePath])
    } else {
      Quickshell.execDetached(["bash", "-c", 'printf "%s\\n" "$1" >"$2"; : >"$3"', "bash",
        String(selection), selectionPath, donePath])
    }
    return true
  }

  function release() {
    finish(null)
  }
}
