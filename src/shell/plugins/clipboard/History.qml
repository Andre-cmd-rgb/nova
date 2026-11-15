import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "ClipboardHistory.js" as ClipboardHistory

// What was copied, text and images, newest first, as
// $XDG_STATE_HOME/nova/clipboard-history.json keeps it, 300 entries at
// most. Two wl-paste watchers run capture.sh at every copy, and the entry
// it prints goes on top. Images no entry names any more are deleted, by
// prune-images.sh, five seconds after the history last changed or was read.
Item {
  id: history

  readonly property string helpers: Quickshell.env("NOVA_PATH") + "/shell/plugins/clipboard/"
  readonly property int limit: 300
  property var entries: []

  // The file was read again, or a copy came in.
  signal updated()

  function save() {
    file.setText(JSON.stringify(entries.slice(0, limit), null, 2) + "\n")
    pruneSoon.restart()
  }

  function drop(index) {
    entries = ClipboardHistory.removed(entries, index)
    save()
  }

  function clear() {
    entries = []
    save()
  }

  function read(text) {
    entries = ClipboardHistory.parse(text)
    updated()
    pruneSoon.restart()
  }

  // A line capture.sh printed: the entry copied.
  function add(line) {
    var entry = ClipboardHistory.parseLine(line)
    if (!entry) return
    entries = ClipboardHistory.added(entries, entry, limit)
    save()
    updated()
  }

  FileView {
    id: file
    path: Commons.Color.stateHome + "/nova/clipboard-history.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: history.read(text())
    onLoadFailed: history.read("[]")
    onFileChanged: reload()
  }

  // ---------------------------------------------------------------- watchers

  // Watchers a shell before this one left are ended first. Ours end with
  // the shell however it ends: setpriv has the kernel signal them when it
  // goes.
  Component.onCompleted: reap.running = true

  Process {
    id: reap
    command: ["pkill", "-f", "wl-paste .*--watch .*/shell/plugins/clipboard/capture\\.sh"]
    onExited: {
      startup.running = true
      textWatch.running = true
      imageWatch.running = true
    }
  }

  // What is on the clipboard as the shell starts.
  Process {
    id: startup
    command: [history.helpers + "capture.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: history.add(text)
    }
  }

  Process {
    id: textWatch
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "text", "--watch", history.helpers + "capture.sh", "text"]
    onExited: rewatch.restart()
    stdout: SplitParser {
      onRead: function (line) { history.add(line) }
    }
  }

  Process {
    id: imageWatch
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "image/png", "--watch", history.helpers + "capture.sh", "image/png"]
    onExited: rewatch.restart()
    stdout: SplitParser {
      onRead: function (line) { history.add(line) }
    }
  }

  // A watcher that died would stop the history without a sign, as copying
  // still works and the picker still shows what it had: it is started
  // again.
  Timer {
    id: rewatch
    interval: 1000
    onTriggered: {
      if (!textWatch.running) textWatch.running = true
      if (!imageWatch.running) imageWatch.running = true
    }
  }

  Timer {
    id: pruneSoon
    interval: 5000
    onTriggered: {
      if (prune.running) {
        restart()
        return
      }
      var kept = []
      for (var i = 0; i < history.entries.length; i++)
        if (history.entries[i].type === "image") kept.push(history.entries[i].path)
      prune.command = [history.helpers + "prune-images.sh"].concat(kept)
      prune.running = true
    }
  }

  Process { id: prune }
}
