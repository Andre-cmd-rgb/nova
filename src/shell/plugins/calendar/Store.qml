import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One calendar's file, read whole and written whole after each edit: the one
// on this computer, ~/.local/share/nova/calendar/calendar.ics, or one an
// account or a subscription has beside it, which nova-calendar-sync keeps in
// step with the server. Read again when another program changes it. An edit
// asked for before the file has been read is refused: written then, it would
// replace what the file has with that one edit. So is any edit of a
// read-only calendar.
Item {
  id: store

  // The calendar's entry in the list (Calendars.qml): its id, its file,
  // whether it is read-only, takes tasks, and is a subscription.
  property var calendar: ({ id: "local", kind: "local", file: "calendar.ics", readOnly: false, tasks: true })
  readonly property string folder: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/nova/calendar"
  readonly property string path: folder + "/" + calendar.file
  property var root: Model.parse("")
  property var items: []
  property bool loaded: false
  // The system's time zone, which new events are written in (Calendars.qml).
  property string zone: ""
  readonly property bool writable: loaded && !calendar.readOnly
  // What Model.items is told of the calendar. A subscription's reminders are
  // its publisher's, and not said.
  readonly property var options: ({ id: calendar.id, readOnly: !!calendar.readOnly, tasks: calendar.tasks !== false,
    reminders: calendar.kind !== "subscription" })
  onOptionsChanged: if (loaded) items = Model.items(root, options)

  // An edit made here, which the sync then sends.
  signal edited()

  function read(text) {
    root = Model.parse(text)
    items = Model.items(root, options)
    loaded = true
  }

  function commit() {
    file.setText(Model.serialize(root))
    items = Model.items(root, options)
    edited()
  }

  function addEvent(fields) {
    if (!writable) return ""
    var uid = Model.addEvent(root, fields, Date.now(), zone)
    commit()
    return uid
  }

  function updateEvent(uid, instance, fields, scope) {
    if (!writable || !Model.updateEvent(root, uid, instance, fields, scope, Date.now(), zone)) return false
    commit()
    return true
  }

  function deleteEvent(uid, instance, scope) {
    if (!writable || !Model.deleteEvent(root, uid, instance, scope, Date.now(), zone)) return false
    commit()
    return true
  }

  function addTask(fields) {
    if (!writable) return ""
    var uid = Model.addTask(root, fields, Date.now(), zone)
    commit()
    return uid
  }

  function updateTask(uid, fields) {
    if (!writable || !Model.updateTask(root, uid, fields, Date.now(), zone)) return false
    commit()
    return true
  }

  function moveTask(uid, day) {
    if (!writable || !Model.moveTask(root, uid, day, Date.now(), zone)) return false
    commit()
    return true
  }

  function deleteTask(uid) {
    if (!writable || !Model.deleteTask(root, uid)) return false
    commit()
    return true
  }

  // An item taken out, to go into another calendar: its text, with the zones
  // it names, or "".
  function take(uid) {
    if (!writable) return ""
    var text = Model.take(root, uid)
    if (text) commit()
    return text
  }

  function put(text) {
    if (!writable || !Model.put(root, text)) return false
    commit()
    return true
  }

  FileView {
    id: file
    path: store.path
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.read(text())
    // No file yet: an empty calendar, written at its first edit. A file that
    // is there and cannot be read (its permissions, another program writing
    // it) is no empty calendar: taken for one, the first edit would write
    // over everything in it. The calendar stays unread, and takes no edits,
    // until the file reads.
    onLoadFailed: function(error) {
      if (!store.loaded && error === FileViewError.FileNotFound) store.read("")
    }
    onFileChanged: reload()
  }
}
