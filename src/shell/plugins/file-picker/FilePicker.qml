import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "FilePickerModel.js" as Model

// Nova's file picker: the window an app gets when it asks the desktop portal
// for a file to open, a name to save under or a folder to choose. The
// portal's backend (nova-sessiond) connects to
// $XDG_RUNTIME_DIR/nova/file-picker.sock, in the user's private runtime
// folder, and one connection is one pick: it sends the request as its first
// line, and the window answers with one line, the paths chosen or a cancel,
// then the connection closes (FilePickerModel.js has the lines each way).
// A connection the backend closes first is a pick that is over: the window
// goes without a word.
//
// One pick at a time: a second connection waits for the first to end, and
// is dropped from the wait if it closes. The window (Picker.qml) is made
// only while a pick is being answered and goes after it, so that nothing of
// it, nor the folder it shows, stays in memory while no app asks.
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  readonly property string folder: Quickshell.env("XDG_RUNTIME_DIR") + "/nova"

  // The connections with a request, oldest first; the window is the first's.
  property var picks: []
  // The window while there is one, for a test to look at.
  readonly property var window: windowLoader.item
  readonly property var current: picks.length > 0 ? picks[0] : null

  // The pick the window is for, and its request, kept until the next pick:
  // each has a window of its own, made after the one before is gone.
  property var shown: null
  property var shownRequest: null

  onCurrentChanged: {
    shown = null
    if (current) Qt.callLater(show)
  }

  function show() {
    if (!current || shown) return
    shownRequest = current.request
    shown = current
  }

  function heard(pick, line) {
    if (pick.request) return
    var request = Model.parse(line)
    if (!request) {
      pick.connected = false
      return
    }
    pick.request = request
    picks = picks.concat([pick])
  }

  function drop(pick) {
    if (picks.indexOf(pick) >= 0) picks = picks.filter(function (p) { return p !== pick })
  }

  // The window's answer: the line goes, and the connection ends.
  function finished(pick, line) {
    pick.write(line)
    pick.flush()
    drop(pick)
    pick.connected = false
  }

  // The runtime folder may not be there yet as the shell starts.
  Process {
    command: ["mkdir", "-p", "-m", "700", root.folder]
    running: true
    onExited: server.active = true
  }

  SocketServer {
    id: server
    active: false
    path: root.folder + "/file-picker.sock"

    handler: Socket {
      id: pick

      property var request: null

      parser: SplitParser {
        onRead: data => root.heard(pick, data)
      }
      onConnectedChanged: {
        if (!connected) root.drop(pick)
      }
    }
  }

  LazyLoader {
    id: windowLoader
    active: root.shown !== null

    Picker {
      request: root.shownRequest
      onFinished: line => root.finished(root.shown, line)
    }
  }
}
