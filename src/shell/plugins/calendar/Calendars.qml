import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.Commons as Commons
import "Model.js" as Model

// Every calendar: the one on this computer, those of the accounts (iCloud,
// Google, any CalDAV server) and the subscriptions, each a file of its own
// (Store.qml), listed in ~/.config/nova/calendars.json with its name, its
// colour and whether it is shown. nova-calendar-sync writes that list, and
// syncs the files with the servers: at login, every five minutes, when the
// network comes back, when the window opens, and a moment after an edit.
// What the window and the clock see is the shown calendars' items.
//
// No sync runs before the boot's first unlock (Commons/BootLock.qml): a sync
// reads the accounts' passwords from the login keyring, which is locked
// until then, and the keyring would ask for its password on a card behind
// the lock that stays up after the unlock has opened the keyring. Asked for
// before it, a sync runs once it is done.
Item {
  id: calendars

  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/nova/calendars.json"
  readonly property string statusPath: Commons.Color.stateHome + "/nova/calendar-sync/status.json"
  readonly property string folder: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/nova/calendar"
  readonly property var localEntry: ({ id: "local", kind: "local", name: "Calendar", color: "accent", shown: true, file: "calendar.ics",
    events: true, tasks: true, readOnly: false })

  property var config: ({ accounts: [], calendars: [] })
  // Every calendar, the one on this computer first, each with all its fields.
  readonly property var list: {
    var out = [localEntry]
    ;(config.calendars || []).forEach(function (c) {
      if (!c || !c.id || !c.file) return
      var entry = Object.assign({}, c.id === "local" ? localEntry : { kind: "caldav", color: "accent", shown: true, events: true, tasks: false, readOnly: false }, c)
      if (c.id === "local") out[0] = entry
      else out.push(entry)
    })
    return out
  }
  readonly property var accounts: config.accounts || []
  readonly property bool synced: list.some(function (c) { return c.kind !== "local" })
  // How each account's or subscription's last sync went, by its id:
  // { state: ok, offline, signin or error, message, pending }.
  property var status: ({})
  readonly property bool syncing: syncer.running
  property bool googleReady: false

  // ---- the files

  property var stores: ({})
  property int version: 0
  // The ids, changed only when one comes or goes: the stores are made
  // again for that, not for a calendar shown or hidden.
  property var ids: ["local"]
  onListChanged: {
    var next = list.map(function (c) { return c.id })
    if (next.join("\n") !== ids.join("\n")) ids = next
  }

  readonly property var local: stores.local || null
  // The list read (or found missing), and every calendar on it read from its
  // file: what the reminders wait for, so that one of a synced calendar due
  // while the computer was off is said as the computer's own is. A calendar
  // whose file is not there yet counts as read (an empty one).
  property bool configRead: false
  readonly property bool loaded: configRead && local !== null && ids.every(function (id) { return !!stores[id] && stores[id].loaded })
  readonly property var root: local ? local.root : null
  property string zone: ""
  property bool zoneAskedAgain: false

  // The shown calendars' items, for the window, the clock and the reminders.
  readonly property var items: {
    version
    var out = []
    list.forEach(function (c) {
      var s = stores[c.id]
      if (c.shown && s) out = out.concat(s.items)
    })
    return out
  }

  function entry(id) {
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
    return null
  }

  function storeOf(id) {
    return stores[id || "local"] || null
  }

  function colorOf(id) {
    var c = entry(id)
    return Commons.Color.hue(c ? c.color : "accent")
  }

  // An account's or a subscription's state in words, or "" when all is well.
  function stateWords(id) {
    var s = status ? status[id] : null
    if (!s) return ""
    var waiting = s.pending > 0 ? (s.pending === 1 ? "1 change not sent" : s.pending + " changes not sent") : ""
    if (s.state === "offline") return waiting ? "Offline, " + waiting : "Offline"
    if (s.state === "signin") return "Sign in again"
    if (s.state === "error") return s.message || "Not synced"
    return waiting
  }

  function checkGoogle() {
    googleCheck.running = true
  }

  function writable(id) {
    var c = entry(id)
    return c !== null && !c.readOnly
  }

  // The calendars an item of <kind> can be put in, by their names.
  function choices(kind) {
    return list.filter(function (c) { return !c.readOnly && (kind === "task" ? c.tasks : c.events) })
  }

  // For a test, or the window on its own: the file on this computer, as if
  // it had read <text>.
  function read(text) {
    if (local) local.read(text)
  }

  function readZone() {
    if (zoneReader.running) zoneAskedAgain = true
    else zoneReader.running = true
  }

  function occurrences(from, to) {
    return Model.occurrences(items, from, to)
  }

  // ---- edits, each in its item's calendar (the one on this computer when
  //      none is said)

  function addEvent(fields) {
    var s = storeOf(fields.calendar)
    return s ? s.addEvent(fields) : ""
  }

  function updateEvent(uid, instance, fields, scope, calendarId) {
    var s = storeOf(calendarId)
    return s ? s.updateEvent(uid, instance, fields, scope) : false
  }

  function deleteEvent(uid, instance, scope, calendarId) {
    var s = storeOf(calendarId)
    return s ? s.deleteEvent(uid, instance, scope) : false
  }

  function addTask(fields) {
    var s = storeOf(fields.calendar)
    return s ? s.addTask(fields) : ""
  }

  function updateTask(uid, fields, calendarId) {
    var s = storeOf(calendarId)
    return s ? s.updateTask(uid, fields) : false
  }

  function moveTask(uid, day, calendarId) {
    var s = storeOf(calendarId)
    return s ? s.moveTask(uid, day) : false
  }

  function deleteTask(uid, calendarId) {
    var s = storeOf(calendarId)
    return s ? s.deleteTask(uid) : false
  }

  // An item, every time of it, into another calendar.
  function moveItem(uid, from, to) {
    var a = storeOf(from), b = storeOf(to)
    if (!a || !b || !a.writable || !b.writable || from === to) return false
    var text = a.take(uid)
    if (!text) return false
    if (b.put(text)) return true
    a.put(text)
    return false
  }

  // ---- the list: shown or hidden, colour, name; optimistic, the list file
  //      following as nova-calendar-sync writes it

  function setCalendar(id, key, value) {
    var next = JSON.parse(JSON.stringify(config))
    next.calendars = next.calendars || []
    var c = next.calendars.filter(function (x) { return x.id === id })[0]
    if (!c) {
      if (id !== "local") return
      c = Object.assign({}, localEntry)
      next.calendars.unshift(c)
    }
    c[key] = value
    config = next
    setter.ask(["nova-calendar-sync", "set", id, key + "=" + value])
  }

  // ---- syncing

  function sync() {
    if (!synced) return
    if (!Commons.BootLock.unlocked) {
      syncUnlocked = true
      return
    }
    if (syncer.running) syncAgain = true
    else syncer.running = true
  }
  property bool syncAgain: false
  // A sync asked for before the boot's first unlock, to run once it is done.
  property bool syncUnlocked: false
  Connections {
    target: Commons.BootLock
    function onUnlockedChanged() {
      if (!Commons.BootLock.unlocked || !calendars.syncUnlocked) return
      calendars.syncUnlocked = false
      calendars.sync()
    }
  }

  // ---- adding and removing

  // What adding an account or a subscription gave: its calendars, or what
  // went wrong, in words.
  signal added(var result)
  signal failed(string words)
  readonly property bool adding: adder.running

  function addAccount(request) {
    if (adder.running) return
    adder.request = JSON.stringify(request)
    adder.command = ["nova-calendar-sync", request.type === "subscription" ? "subscribe" : "add"]
    adder.running = true
  }

  function cancelAdding() {
    adder.canceled = true
    adder.running = false
  }

  function remove(id) {
    var next = JSON.parse(JSON.stringify(config))
    next.accounts = (next.accounts || []).filter(function (a) { return a.id !== id })
    next.calendars = (next.calendars || []).filter(function (c) { return c.id !== id && c.account !== id })
    config = next
    setter.ask(["nova-calendar-sync", "remove", id])
  }

  // ---- the processes and files

  Process {
    running: true
    command: ["mkdir", "-p", calendars.folder]
  }

  Instantiator {
    model: calendars.ids
    delegate: Store {
      required property string modelData
      calendar: calendars.entry(modelData) || calendars.localEntry
      zone: calendars.zone
      onItemsChanged: calendars.version++
      onEdited: if (calendar.kind === "caldav") soon.restart()
    }
    onObjectAdded: function (index, object) {
      var next = Object.assign({}, calendars.stores)
      next[object.modelData] = object
      calendars.stores = next
      calendars.version++
    }
    onObjectRemoved: function (index, object) {
      var next = Object.assign({}, calendars.stores)
      if (next[object.modelData] === object) delete next[object.modelData]
      calendars.stores = next
      calendars.version++
    }
  }

  Process {
    id: zoneReader
    running: true
    command: ["timedatectl", "show", "-p", "Timezone", "--value"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var name = String(text).trim()
        // A zone that cannot be read keeps the one read before.
        if (/^[A-Za-z0-9_+\/-]+$/.test(name)) calendars.zone = name
      }
    }
    onExited: {
      if (!calendars.zoneAskedAgain) return
      calendars.zoneAskedAgain = false
      running = true
    }
  }

  Commons.WatchedFile {
    path: calendars.configPath
    onLoaded: {
      try {
        var read = JSON.parse(text())
        if (read && Array.isArray(read.calendars)) calendars.config = read
      } catch (e) {
        // Half written, or broken by hand: what was read before stays.
      }
      calendars.configRead = true
    }
    onLoadFailed: calendars.configRead = true
  }

  Commons.WatchedFile {
    id: statusFile
    path: calendars.statusPath
    onLoaded: {
      try {
        calendars.status = JSON.parse(text()) || {}
      } catch (e) {
        // Being written: read again when it is.
      }
    }
  }

  Process {
    id: syncer
    command: ["nova-calendar-sync", "sync"]
    onExited: {
      statusFile.reload()
      if (!calendars.syncAgain) return
      calendars.syncAgain = false
      running = true
    }
  }

  // Every five minutes; the network back; a moment after an edit, so that a
  // drag and the change after it go together.
  Timer {
    interval: 5 * 60000
    repeat: true
    running: calendars.synced
    onTriggered: calendars.sync()
  }
  Timer {
    id: soon
    interval: 1500
    onTriggered: calendars.sync()
  }
  Connections {
    target: Networking
    function onConnectivityChanged() {
      if (Networking.connectivity === NetworkConnectivity.Full) calendars.sync()
    }
  }
  // At login, once the list is read.
  Timer {
    interval: 3000
    running: true
    onTriggered: calendars.sync()
  }

  // set and remove, one after another, in the order asked.
  Process {
    id: setter
    property var queue: []
    function ask(words) {
      queue = queue.concat([words])
      next()
    }
    function next() {
      if (running || queue.length === 0) return
      command = queue[0]
      queue = queue.slice(1)
      running = true
    }
    onExited: next()
  }

  Process {
    id: adder
    property string request: ""
    property bool canceled: false
    stdinEnabled: true
    onStarted: {
      canceled = false
      write(request + "\n")
      request = ""
    }
    stdout: StdioCollector { id: addedOut; waitForEnd: true }
    stderr: StdioCollector { id: addedErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (canceled) return
      var result = null
      try { result = JSON.parse(addedOut.text) } catch (e) {}
      if (exitCode === 0 && result) {
        calendars.added(result)
        calendars.sync()
      } else {
        var words = String(addedErr.text || "").trim().split("\n").pop()
        calendars.failed(words || "The account could not be added.")
      }
    }
  }

  Process {
    id: googleCheck
    command: ["nova-calendar-sync", "google"]
    onExited: function (exitCode) { calendars.googleReady = exitCode === 0 }
  }
}
