import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.Commons

import "components"
import "NotificationLogic.js" as NotificationLogic

// Nova's notifications: the server on the session bus, and its toasts at the
// top right of every screen. A toast goes after its lifetime (none for a
// critical one) and is held while the pointer is on it; a click runs its
// action, or brings its app forward, and a right click dismisses it.
//
// Do-not-disturb keeps the toasts off the screen and puts what they would
// have said straight into the history, which keeps the last ten toasts gone
// from the screen and replays them on request. The toasts on screen are kept
// in files too, and come back when the shell restarts. All of it lives in
// $XDG_STATE_HOME/nova: notifications.json for do-not-disturb, and
// notifications/ (see files.sh).
Item {
  id: service

  // Injected by the shell.
  property var shell: null

  property string novaPath: Quickshell.env("NOVA_PATH")
  readonly property string files: novaPath + "/shell/plugins/notifications/files.sh"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/nova/"
  readonly property string settingsPath: stateDir + "notifications.json"
  readonly property string toastDir: stateDir + "notifications/"
  readonly property string historyDir: toastDir + "history/"
  readonly property string imagesDir: toastDir + "images/"
  readonly property int historyLimit: 10

  // The toasts on screen, newest first, as rows of NotificationLogic.rowOf.
  readonly property ListModel toasts: ListModel {}

  // The Notification objects of the toasts and silenced notifications still
  // held, by id. Kept here and not in the rows: the server frees an object when
  // its notification goes, and a row holding it would crash the next read.
  property var live: ({})

  // The rows restored from the shell before or replayed from the history, by
  // file name. Their ids were handed out by a server since gone, and the new
  // one counts from 1 again, so a notification arriving under one of them is
  // not theirs, nor is a live object of that id.
  property var restored: ({})

  // The toasts the pointer is on, by stem. Each screen shows every toast, and
  // none of a toast's copies counts down while the pointer is on one of them.
  property var held: ({})

  function hold(stem, on) {
    var next = ({})
    for (var key in held) if (key !== stem) next[key] = true
    if (on) next[stem] = true
    held = next
  }

  function isRestored(row) {
    return !!row && !!restored[NotificationLogic.fileName(row)]
  }

  // ---------------------------------------------------------- do-not-disturb

  // Kept across the shell's reloads, and in notifications.json across its
  // restarts: read once at the start, written 200 ms after it changes.
  PersistentProperties {
    id: persisted
    reloadableId: "nova-notifications"
    property bool doNotDisturb: false
    onDoNotDisturbChanged: if (!service.reading) service.saveSettings()
  }

  readonly property alias doNotDisturb: persisted.doNotDisturb
  property bool reading: false
  property bool settingsRead: false

  // The bar's do-not-disturb button.
  function setDoNotDisturb(value) {
    persisted.doNotDisturb = !!value
  }

  FileView {
    id: settingsFile
    path: service.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.readSettings(text())
    // No file yet: still read, or nothing would ever write one.
    onLoadFailed: service.readSettings("")
  }

  Timer {
    id: settingsSoon
    interval: 200
    onTriggered: settingsFile.setText(JSON.stringify({ version: 3, dnd: persisted.doNotDisturb }, null, 2) + "\n")
  }

  function saveSettings() {
    if (settingsRead) settingsSoon.restart()
  }

  // Once: the file can load twice as the shell starts, once as its path is
  // set and once more when it is asked to.
  function readSettings(text) {
    if (settingsRead) return
    var settings = NotificationLogic.parseSettings(text)
    if (settings.error) console.warn("notifications: settings parse failed:", settings.errorMessage || "")
    if (settings.dnd !== null) {
      reading = true
      persisted.doNotDisturb = settings.dnd
      reading = false
    }
    settingsRead = true
    if (settings.legacy) saveSettings()
  }

  // ---------------------------------------------------------- notifications

  NotificationServer {
    keepOnReload: false
    imageSupported: true
    actionsSupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    persistenceSupported: true
    onNotification: function (notification) { service.receive(notification) }
  }

  function receive(notification) {
    // Held, or the server frees it as soon as this returns.
    notification.tracked = true
    var row = NotificationLogic.rowOf(notification, Date.now())
    var id = row.originalId
    live[id] = notification
    // Closed by its sender (CloseNotification), it leaves the screen, as the
    // specification has it: what it said no longer holds, or it was one that
    // never runs out. A newer notification may have taken the id meanwhile.
    var closedBySender = false
    notification.closed.connect(function (reason) {
      if (service.live[id] === notification) delete service.live[id]
      if (reason !== NotificationCloseReason.CloseRequested) return
      closedBySender = true
      service.takeDown(id, row.timestamp)
    })

    if (doNotDisturb && !NotificationLogic.breaksThroughDnd(notification)) {
      if (NotificationLogic.passing(notification)) {
        delete live[id]
        notification.tracked = false
      } else {
        keepSilenced(notification, row)
      }
      return
    }

    show(row)
    follow(notification, row)
    // Later: changing the model while its Repeater makes a card crashes.
    Qt.callLater(function () {
      service.replace(id, NotificationLogic.fileName(row))
      // Closed before it showed: its file goes to the history as it would.
      if (closedBySender) {
        service.archive(row)
        return
      }
      service.toasts.insert(0, row)
      // An update that came before the row was there had no row to change,
      // and will not come again.
      service.update(notification, id, row.timestamp)
    })
  }

  // A silenced notification, written into the history. It is let go only
  // once its content is final: letting go tells the sender it closed (and
  // Chromium deletes its picture), and an update to it comes to this object
  // with no new notification; one that came while it was written is written
  // again, to the same file.
  function keepSilenced(notification, row) {
    record(row, function () {
      var updated = null
      try {
        updated = NotificationLogic.updatedRow(notification, row.originalId, row.timestamp)
      } catch (e) {
        // Freed by the server while the write waited.
      }
      if (updated && NotificationLogic.differs(row, updated)) {
        service.keepSilenced(notification, updated)
        return
      }
      if (service.live[row.originalId] === notification) delete service.live[row.originalId]
      try {
        notification.tracked = false
      } catch (e) {
      }
    })
  }

  // A sender replacing its notification changes the object held, and no new
  // notification comes: the toast's row is a copy, so it is copied again.
  function follow(notification, row) {
    var changes = ["summaryChanged", "bodyChanged", "appNameChanged", "appIconChanged",
      "imageChanged", "urgencyChanged", "expireTimeoutChanged", "hintsChanged"]
    var again = function () { service.update(notification, row.originalId, row.timestamp) }
    for (var i = 0; i < changes.length; i++) {
      var signal = notification[changes[i]]
      if (signal && typeof signal.connect === "function") signal.connect(again)
    }
  }

  // The toast of <id> and <timestamp> drawn again from its notification, and
  // its file written again, to the same name: a restart restores what was
  // shown last, and the history keeps it.
  function update(notification, id, timestamp) {
    // The id taken by a newer notification, or the toast gone.
    if (live[id] !== notification) return
    var updated
    try {
      updated = NotificationLogic.updatedRow(notification, id, timestamp)
    } catch (e) {
      return
    }
    var roles = NotificationLogic.shownRoles()
    for (var i = 0; i < toasts.count; i++) {
      var row = toasts.get(i)
      if (!row || row.originalId !== id || row.timestamp !== timestamp) continue
      if (!NotificationLogic.differs(row, updated)) return
      for (var r = 0; r < roles.length; r++) toasts.setProperty(i, roles[r], updated[roles[r]])
      show(updated)
      return
    }
  }

  // A notification under the id of a toast on screen replaces it: the toast
  // goes, and its file with it, not to the history, as its sender means them
  // as one. A restored toast stays, its id being another server's. <keep> is
  // the new notification's own file, which has the old one's name when both
  // came in one millisecond, and is already being written.
  function replace(id, keep) {
    for (var i = toasts.count - 1; i >= 0; i--) {
      var row = toasts.get(i)
      if (!row || row.originalId !== id || isRestored(row)) continue
      if (NotificationLogic.fileName(row) !== keep) forget(row)
      toasts.remove(i)
    }
  }

  // The toast of <id> and <timestamp> off the screen, its sender having closed
  // it, and its file into the history, as any toast gone. The sender is not
  // told: it knows.
  function takeDown(id, timestamp) {
    for (var i = toasts.count - 1; i >= 0; i--) {
      var row = toasts.get(i)
      if (!row || row.originalId !== id || row.timestamp !== timestamp || isRestored(row)) continue
      archive(row)
      toasts.remove(i)
    }
  }

  // ------------------------------------------------------------------ toasts

  function dismiss(index) {
    remove(index, "dismiss")
  }

  function expire(index) {
    remove(index, "expire")
  }

  // Toast <index> off the screen, its file into the history, and its
  // notification told why it went. A restored toast has no notification here;
  // looking its id up would find someone else's.
  function remove(index, why) {
    if (index < 0 || index >= toasts.count) return
    var row = toasts.get(index)
    var notification = row && !isRestored(row) && row.originalId >= 0 ? live[row.originalId] : null
    if (row) {
      archive(row)
      delete restored[NotificationLogic.fileName(row)]
    }
    toasts.remove(index)
    if (!notification) return
    try {
      if (notification.tracked) {
        if (why === "expire" && typeof notification.expire === "function") notification.expire()
        else notification.dismiss()
      }
    } catch (e) {
      // Freed by the server.
    }
  }

  function dismissAll() {
    while (toasts.count > 0) dismiss(0)
  }

  // A click on toast <index>: the command it carries, run apart from the shell
  // (an installer's restarts the shell), or its sender's default action, or
  // else its app brought forward, as chat apps expect; then it goes. A
  // restored toast has neither sender nor actions.
  function invoke(index) {
    if (index < 0 || index >= toasts.count) return
    var row = toasts.get(index)
    var argv = NotificationLogic.runnable(row ? row.execArgv : "")
    if (argv) {
      Util.execArgv(argv)
      dismiss(index)
      return
    }
    var notification = row && !isRestored(row) ? live[row.originalId] : null
    var invoked = false
    try {
      for (var i = 0; notification && notification.actions && i < notification.actions.length; i++) {
        var action = notification.actions[i]
        if (action && action.identifier === "default") {
          action.invoke()
          invoked = true
          break
        }
      }
    } catch (e) {
      console.warn("invoke default failed:", e)
    }
    if (!invoked && row && row.app) {
      focusApp.command = ["nova-hyprland-focus-app", String(row.app)]
      focusApp.running = true
    }
    dismiss(index)
  }

  Process { id: focusApp }

  // ------------------------------------------------------------------- files

  // The jobs on the files, run one at a time, so that a run of updates does
  // not race and a removal asked after a write comes after it. A history read
  // takes its turn too: it sees the history as it was when asked for, and
  // what is asked after it waits for it.
  property var jobs: []
  property var jobDone: null

  function queue(job) {
    jobs = jobs.concat([job])
    next()
  }

  function next() {
    if (fileJob.running || historyRead.running || jobs.length === 0) return
    var job = jobs[0]
    jobs = jobs.slice(1)
    if (job.read) {
      readQueued = false
      historyRead.command = ["bash", files, "read", historyDir]
      historyRead.running = true
      return
    }
    jobDone = job.done || null
    fileJob.command = ["bash", files].concat(job.args)
    fileJob.running = true
  }

  Process {
    id: fileJob
    onExited: {
      var done = service.jobDone
      service.jobDone = null
      try {
        if (done) done()
      } catch (e) {
        console.warn("notifications: file job callback failed:", e)
      }
      service.next()
    }
  }

  // Each with the copies of its pictures to make, made before the file that
  // names them, while the sender's are still there.
  function withCopies(args, copies) {
    for (var i = 0; i < copies.length; i++) args.push(copies[i].from, copies[i].to)
    return args
  }

  function show(row) {
    var disk = NotificationLogic.forDisk(row, imagesDir)
    queue({ args: withCopies(["show", toastDir, imagesDir, NotificationLogic.fileName(row), NotificationLogic.line(disk.entry)], disk.copies) })
  }

  function forget(row) {
    queue({ args: ["forget", toastDir, imagesDir, NotificationLogic.stem(row)] })
  }

  function archive(row) {
    queue({ args: ["archive", toastDir, historyDir, imagesDir, NotificationLogic.fileName(row), String(historyLimit)] })
  }

  // Straight into the history, as a toast gone would be. A silenced
  // notification is let go at once, so an update its sender makes comes as a
  // new notification, and is kept as one: nothing tells them apart, and
  // guessing by app and summary would merge separate messages.
  function record(row, done) {
    var disk = NotificationLogic.forDisk(row, imagesDir)
    queue({ args: withCopies(["record", historyDir, imagesDir, NotificationLogic.fileName(row), NotificationLogic.line(disk.entry),
      String(historyLimit)], disk.copies), done: done })
  }

  function clearHistory() {
    queue({ args: ["clear", historyDir, imagesDir] })
  }

  // ----------------------------------------------------------------- history

  property bool readQueued: false
  // The toasts on screen as the replay was asked for: the replay sends them
  // to the history after its read, so they are handed over as they are.
  property var carried: []

  function showHistory() {
    if (historyRead.running || readQueued) return "ok"
    var rows = []
    for (var i = 0; i < toasts.count; i++) {
      var row = toasts.get(i)
      // The history's "No recent notifications" is not a notification.
      if (!row || row.originalId < 0) continue
      // Their senders delete their pictures as they go: the copies are named.
      rows.push(NotificationLogic.forDisk({
        id: row.id, originalId: row.originalId, app: row.app, appIcon: row.appIcon, summary: row.summary, body: row.body,
        image: row.image, glyph: row.glyph || "", execArgv: row.execArgv || "", urgency: row.urgency, timestamp: row.timestamp
      }, imagesDir).entry)
    }
    carried = rows
    readQueued = true
    queue({ read: true })
    return "ok"
  }

  Process {
    id: historyRead
    // The jobs after it go on, whatever the read did.
    onExited: service.next()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.replay(text)
    }
  }

  function replay(text) {
    var rows = NotificationLogic.replayRows(text, carried, historyLimit)
    carried = []
    // An empty history says so, or the key would seem dead.
    if (rows.length === 0) {
      toasts.insert(0, {
        id: -1, originalId: -1, app: "nova-action", appIcon: "", summary: "No recent notifications", body: "", image: "",
        glyph: "\u{F009A}", execArgv: "", urgency: NotificationUrgency.Low, expireTimeout: 0, timestamp: Date.now()
      })
      return
    }
    dismissAll()
    for (var i = 0; i < rows.length; i++) {
      restored[NotificationLogic.fileName(rows[i])] = true
      toasts.append(rows[i])
    }
  }

  // --------------------------------------------------------------- restoring

  Process {
    id: restoreRead
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.restore(text)
    }
  }

  // The toasts the shell before left on screen. One that would have run out
  // by now goes to the history, as it would have; the others are shown for a
  // whole lifetime again, a restart being rare and a toast back with a second
  // left no use, and that is written down as a deadline, by which a second
  // restart judges it.
  function restore(text) {
    var now = Date.now()
    var back = []
    var rows = NotificationLogic.parseFiles(text)
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var lifetime = NotificationLogic.lifetime(row.urgency, row.expireTimeout)
      if (NotificationLogic.expired(row, lifetime, now)) {
        archive(row)
        continue
      }
      if (lifetime > 0) {
        row.deadline = now + lifetime
        show(row)
        // Not a role: the rows of the model all have the same.
        delete row.deadline
      }
      back.push(row)
    }
    if (back.length === 0) return
    Qt.callLater(function () {
      for (var j = 0; j < back.length; j++) {
        // A notification that came while the files were read has its own
        // file, and is this toast if its id and time are this one's. One
        // with this id at another time may be its replacement or another
        // server's id: both are shown, as a toast twice beats a critical
        // one lost.
        var shown = false
        for (var k = 0; k < service.toasts.count && !shown; k++) {
          var row = service.toasts.get(k)
          shown = !!row && row.originalId === back[j].originalId && row.timestamp === back[j].timestamp
        }
        if (shown) continue
        // Below what has just come, newest first.
        service.restored[NotificationLogic.fileName(back[j])] = true
        service.toasts.append(back[j])
      }
    })
  }

  Process {
    id: makeDirs
    command: ["mkdir", "-p", service.stateDir, service.toastDir, service.historyDir, service.imagesDir]
  }

  Component.onCompleted: {
    makeDirs.running = true
    Qt.callLater(function () {
      settingsFile.reload()
      restoreRead.command = ["bash", service.files, "read", service.toastDir]
      restoreRead.running = true
      // Beside the read: the toasts it restores are written again with the
      // copies they had, which the sweep keeps.
      service.queue({ args: ["sweep", service.toastDir, service.historyDir, service.imagesDir] })
    })
  }

  // --------------------------------------------------------------------- IPC

  IpcHandler {
    target: "notifications"

    function dndState(): string {
      return service.doNotDisturb ? "on" : "off"
    }

    function toggleDnd(): string {
      service.setDoNotDisturb(!service.doNotDisturb)
      return dndState()
    }

    function setDnd(value: string): string {
      service.setDoNotDisturb(["true", "1", "on", "yes"].indexOf(String(value || "").toLowerCase()) !== -1)
      return dndState()
    }

    function isDnd(): string {
      return dndState()
    }

    function showHistory(): string {
      return service.showHistory()
    }

    // The history forgotten; the toasts on screen stay.
    function clear(): string {
      service.clearHistory()
      return "ok"
    }

    function dismissAll(): string {
      service.dismissAll()
      return "ok"
    }

    // The newest toast.
    function dismissOne(): string {
      if (service.toasts.count === 0) return "none"
      service.dismiss(0)
      return "ok"
    }

    // The newest toast clicked.
    function invokeLast(): string {
      if (service.toasts.count === 0) return "none"
      service.invoke(0)
      return "ok"
    }

    // The toasts whose summary has <summary> in it: the first-run toasts go
    // once their action has been taken.
    function dismiss(summary: string): string {
      var needle = String(summary || "")
      if (!needle) return "none"
      var found = false
      for (var i = service.toasts.count - 1; i >= 0; i--) {
        var row = service.toasts.get(i)
        if (row && String(row.summary || "").indexOf(needle) !== -1) {
          service.dismiss(i)
          found = true
        }
      }
      return found ? "ok" : "none"
    }

    function ping(): string {
      return "ok"
    }
  }

  // ------------------------------------------------------------------ screens

  Variants {
    model: Quickshell.screens

    ToastWindow {
      required property var modelData
      screen: modelData
      notifications: service
    }
  }
}
