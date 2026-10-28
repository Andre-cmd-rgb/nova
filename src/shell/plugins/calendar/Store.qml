import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The calendar's file, ~/.local/share/nova/calendar/calendar.ics, read whole
// and written whole after each edit. Read again when another program changes
// it. An edit asked for before the file has been read is refused: written
// then, it would replace what the file has with that one edit.
Item {
  id: store

  readonly property string folder: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/nova/calendar"
  readonly property string path: folder + "/calendar.ics"
  property var root: Model.parse("")
  property var items: []
  property bool loaded: false
  // The system's time zone, which new events are written in.
  property string zone: ""

  function read(text) {
    root = Model.parse(text)
    items = Model.items(root)
    loaded = true
  }

  function commit() {
    file.setText(Model.serialize(root))
    items = Model.items(root)
  }

  function occurrences(from, to) {
    return Model.occurrences(items, from, to)
  }

  function addEvent(fields) {
    if (!loaded) return ""
    var uid = Model.addEvent(root, fields, Date.now(), zone)
    commit()
    return uid
  }

  function updateEvent(uid, instance, fields, scope) {
    if (!loaded || !Model.updateEvent(root, uid, instance, fields, scope, Date.now(), zone)) return false
    commit()
    return true
  }

  function deleteEvent(uid, instance, scope) {
    if (!loaded || !Model.deleteEvent(root, uid, instance, scope, Date.now(), zone)) return false
    commit()
    return true
  }

  function addTask(fields) {
    if (!loaded) return ""
    var uid = Model.addTask(root, fields, Date.now(), zone)
    commit()
    return uid
  }

  function updateTask(uid, fields) {
    if (!loaded || !Model.updateTask(root, uid, fields, Date.now(), zone)) return false
    commit()
    return true
  }

  function moveTask(uid, day) {
    if (!loaded || !Model.moveTask(root, uid, day, Date.now(), zone)) return false
    commit()
    return true
  }

  function deleteTask(uid) {
    if (!loaded || !Model.deleteTask(root, uid)) return false
    commit()
    return true
  }

  // FileView writes into a folder that is there.
  Process {
    running: true
    command: ["mkdir", "-p", store.folder]
  }

  Process {
    running: true
    command: ["timedatectl", "show", "-p", "Timezone", "--value"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: store.zone = /^[A-Za-z0-9_+\/-]+$/.test(String(text).trim()) ? String(text).trim() : ""
    }
  }

  FileView {
    id: file
    path: store.path
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.read(text())
    // No file yet: an empty calendar, written at its first edit.
    onLoadFailed: if (!store.loaded) store.read("")
    onFileChanged: reload()
  }
}
