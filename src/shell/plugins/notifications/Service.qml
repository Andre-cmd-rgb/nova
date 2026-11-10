import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.Commons
import qs.Commons as Commons
import "components" as Parts
import "NotificationLogic.js" as Notes

// Nova's notifications: the server on the session bus, and its toasts at the
// top right of every screen. A toast goes after its lifetime (a critical one
// never does) and waits while the pointer is on it; a click runs its action
// or brings its app forward, a right click dismisses it.
//
// Do-not-disturb keeps the toasts off the screen, and what they would have
// said goes straight into the history: the last ten toasts gone, replayed on
// request. The toasts on screen are kept in files too, and come back when the
// shell restarts. All of it is in $XDG_STATE_HOME/nova: notifications.json
// for do-not-disturb, and notifications/ (see files.sh and ToastFiles).
Item {
  id: notifications

  // Injected by the shell.
  property var shell: null

  readonly property string stateDir: Commons.Color.stateHome + "/nova/"

  // The toasts on screen, newest first, as rows (Notes.rowOf).
  readonly property ListModel toasts: ListModel {}

  // The notifications of the toasts and of those silenced, by id, while the
  // server holds them; the rows are copies, as the server frees a
  // notification when it goes.
  property var senders: ({})

  // The rows brought back from the shell before or replayed from the
  // history, by file name. Another server handed their ids out, and this one
  // counts from 1 again: a notification under one of them is not theirs.
  property var fromBefore: ({})

  // The toasts the pointer is on, by stem. Every screen shows every toast,
  // and none of a toast's copies counts down while the pointer is on one.
  property var held: ({})

  function hold(stem, on) {
    var next = Object.assign({}, held)
    if (on) next[stem] = true
    else delete next[stem]
    held = next
  }

  function isFromBefore(row) {
    return !!fromBefore[Notes.fileName(row)]
  }

  function senderOf(row) {
    return isFromBefore(row) ? null : senders[row.originalId] || null
  }

  // The first toast that passes, by its place, or -1.
  function indexWhere(test) {
    for (var i = 0; i < toasts.count; i++) {
      if (test(toasts.get(i))) return i
    }
    return -1
  }

  // The toasts that pass off the screen, each handed to `each` as it goes.
  function pull(test, each) {
    for (var i = toasts.count - 1; i >= 0; i--) {
      var row = toasts.get(i)
      if (!test(row)) continue
      each(row)
      toasts.remove(i)
    }
  }

  Parts.ToastFiles {
    id: files
    script: Quickshell.env("NOVA_PATH") + "/shell/plugins/notifications/files.sh"
    folder: notifications.stateDir + "notifications/"
  }

  // ------------------------------------------------------ do-not-disturb

  // Kept across the shell's reloads, and in notifications.json across its
  // restarts: read once as it starts, written 200 ms after a change.
  PersistentProperties {
    id: memory
    reloadableId: "nova-notifications"
    property bool doNotDisturb: false
    onDoNotDisturbChanged: if (!dndFile.applying) dndFile.save()
  }

  readonly property bool doNotDisturb: memory.doNotDisturb

  // The bar's switch.
  function setDoNotDisturb(on) {
    memory.doNotDisturb = !!on
  }

  FileView {
    id: dndFile

    property bool read: false
    property bool applying: false

    path: notifications.stateDir + "notifications.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: readOnce(text())
    // No file yet: read all the same, or nothing would ever write one.
    onLoadFailed: readOnce("")

    // It can load twice as the shell starts: as its path is set, and when it
    // is asked to.
    function readOnce(content) {
      if (read) return
      var settings = Notes.parseSettings(content)
      if (settings.problem) console.warn("notifications: settings parse failed:", settings.problem)
      if (settings.dnd !== null) {
        applying = true
        memory.doNotDisturb = settings.dnd
        applying = false
      }
      read = true
      if (settings.legacy) save()
    }

    function save() {
      if (read) dndWrite.restart()
    }
  }

  Timer {
    id: dndWrite
    interval: 200
    onTriggered: dndFile.setText(JSON.stringify({ version: 3, dnd: memory.doNotDisturb }, null, 2) + "\n")
  }

  // --------------------------------------------------------------- arrivals

  NotificationServer {
    keepOnReload: false
    imageSupported: true
    actionsSupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    persistenceSupported: true
    onNotification: notification => notifications.arrive(notification)
  }

  function arrive(notification) {
    // Tracked, or the server frees it the moment this returns.
    notification.tracked = true
    var row = Notes.rowOf(notification, Date.now())
    var id = row.originalId
    senders[id] = notification
    // Closed by its sender (CloseNotification), it leaves the screen, as the
    // specification has it: what it said holds no longer, or it was one that
    // never runs out. A newer notification may have its id by then.
    var closedBySender = false
    notification.closed.connect(reason => {
      if (notifications.senders[id] === notification) delete notifications.senders[id]
      if (reason !== NotificationCloseReason.CloseRequested) return
      closedBySender = true
      notifications.takeDown(id, row.timestamp)
    })

    if (doNotDisturb && !Notes.breaksThroughDnd(notification)) {
      if (!Notes.passing(notification)) {
        silence(notification, row)
        return
      }
      delete senders[id]
      notification.tracked = false
      return
    }

    files.write(row)
    // Its sender may change it in place, a replacement under its id: the
    // row is a copy, so it is copied again.
    var redraw = () => notifications.redraw(notification, id, row.timestamp)
    for (var name of Notes.WATCHED) {
      var changed = notification[name + "Changed"]
      if (changed && typeof changed.connect === "function") changed.connect(redraw)
    }
    // A turn later: a model changed while its Repeater makes a card crashes.
    Qt.callLater(() => {
      notifications.replace(id, Notes.fileName(row))
      // Closed before it showed: to the history, as it would have gone.
      if (closedBySender) {
        files.retire(row)
        return
      }
      notifications.toasts.insert(0, row)
      // A change that came before the row was there found nothing to change,
      // and will not come again.
      redraw()
    })
  }

  // A notification silenced, written into the history. It is let go only once
  // what it says is final: letting go tells its sender it closed (and
  // Chromium deletes its picture), and a change to it comes to this object,
  // as no new notification. One that came while it was written is written
  // again, to the same file.
  function silence(notification, row) {
    files.record(row, () => {
      var now = null
      try {
        now = Notes.rowOf(notification, row.timestamp, row.originalId)
      } catch (e) {
        // Freed by the server while the write waited.
      }
      if (now && Notes.differs(row, now)) {
        notifications.silence(notification, now)
        return
      }
      if (notifications.senders[row.originalId] === notification) delete notifications.senders[row.originalId]
      try {
        notification.tracked = false
      } catch (e) {
      }
    })
  }

  // The toast of `id` and `timestamp` drawn again from its notification, and
  // its file written again under the same name: a restart brings back what
  // was shown last, and the history keeps it.
  function redraw(notification, id, timestamp) {
    // Its id taken by a newer notification, or the toast gone.
    if (senders[id] !== notification) return
    var now
    try {
      now = Notes.rowOf(notification, timestamp, id)
    } catch (e) {
      return
    }
    var at = indexWhere(row => row.originalId === id && row.timestamp === timestamp)
    if (at < 0 || !Notes.differs(toasts.get(at), now)) return
    for (var role of Notes.SHOWN) toasts.setProperty(at, role, now[role])
    files.write(now)
  }

  // A notification under the id of a toast on screen takes its place: the
  // toast goes, and its file, not to the history, as its sender means the two
  // as one. One from before stays, its id being another server's. `keep` is
  // the new one's file, under the old one's name if both came in one
  // millisecond, and already being written.
  function replace(id, keep) {
    pull(row => row.originalId === id && !isFromBefore(row), row => {
      if (Notes.fileName(row) !== keep) files.drop(row)
    })
  }

  // The toast of `id` and `timestamp` off the screen, its sender having closed
  // it, and its file into the history like any toast gone. The sender is not
  // told: it knows.
  function takeDown(id, timestamp) {
    pull(row => row.originalId === id && row.timestamp === timestamp && !isFromBefore(row), row => files.retire(row))
  }

  // ---------------------------------------------------------------- toasts

  function dismiss(index) {
    leave(index, false)
  }

  function expire(index) {
    leave(index, true)
  }

  // Toast `index` off the screen, its file into the history, and its sender
  // told whether it ran out or was dismissed.
  function leave(index, ranOut) {
    if (index < 0 || index >= toasts.count) return
    var row = toasts.get(index)
    var notification = row.originalId >= 0 ? senderOf(row) : null
    files.retire(row)
    delete fromBefore[Notes.fileName(row)]
    toasts.remove(index)
    try {
      if (!notification || !notification.tracked) return
      if (ranOut && typeof notification.expire === "function") notification.expire()
      else notification.dismiss()
    } catch (e) {
      // Freed by the server.
    }
  }

  function dismissAll() {
    while (toasts.count > 0) dismiss(0)
  }

  // A click on toast `index`: the command it carries, run apart from the
  // shell (an installer's restarts it); else its sender's default action;
  // else its app brought forward, as chat apps expect. Then it goes. One from
  // before has neither sender nor actions.
  function invoke(index) {
    if (index < 0 || index >= toasts.count) return
    var row = toasts.get(index)
    var argv = Notes.runnable(row.execArgv)
    if (argv) Util.execArgv(argv)
    else if (!runDefault(senderOf(row)) && row.app) bringForward.start(row.app)
    dismiss(index)
  }

  // Its "default" action, if it has one: whether it ran.
  function runDefault(notification) {
    try {
      var actions = notification && notification.actions ? notification.actions : []
      for (var i = 0; i < actions.length; i++) {
        if (!actions[i] || actions[i].identifier !== "default") continue
        actions[i].invoke()
        return true
      }
    } catch (e) {
      console.warn("notifications: the default action failed:", e)
    }
    return false
  }

  // A click while one is focusing is kept, the latest, and done after it.
  Process {
    id: bringForward
    property string next: ""

    function start(app) {
      if (running) {
        next = String(app)
        return
      }
      command = ["nova-hyprland-focus-app", String(app)]
      running = true
    }

    onExited: {
      if (next === "") return
      const app = next
      next = ""
      start(app)
    }
  }

  // --------------------------------------------------------------- history

  // A replay asked for and not yet read.
  property bool replaying: false

  // The history replayed as toasts, in place of those on screen; asked again
  // while it reads, nothing more.
  function showHistory() {
    if (replaying) return
    replaying = true
    // The toasts on screen go to the history after the read, so they come as
    // they are, naming the copies of their pictures: their senders delete
    // theirs as they go. Not the history's own "No recent notifications".
    var onScreen = []
    for (var i = 0; i < toasts.count; i++) {
      var row = toasts.get(i)
      if (row.originalId >= 0) onScreen.push(Notes.forDisk(Notes.plain(row), files.images).entry)
    }
    files.readHistory(text => {
      notifications.replaying = false
      notifications.replay(Notes.replayRows(text, onScreen, files.keep))
    })
  }

  function replay(rows) {
    if (rows.length > 0) {
      dismissAll()
      for (var row of rows) {
        fromBefore[Notes.fileName(row)] = true
        toasts.append(row)
      }
      return
    }
    // An empty history says so, or the key would seem dead; once: asked
    // again, it says it anew.
    pull(row => row.originalId < 0, () => {})
    toasts.insert(0, Notes.historyRow({
      id: -1, app: "nova-action", summary: "No recent notifications", glyph: "\u{F009A}", urgency: Notes.LOW, timestamp: Date.now()
    }))
  }

  // ------------------------------------------------------------ restarting

  // The toasts the shell before left on screen. One that would have run out
  // by now goes to the history, as it would have; the others show for a
  // whole lifetime again, a restart being rare and a toast back for a second
  // no use, written down as a deadline a second restart judges them by.
  function bringBack(text) {
    var now = Date.now()
    var back = Notes.parseFiles(text).filter(row => {
      var lifetime = Notes.lifetime(row.urgency, row.expireTimeout)
      if (Notes.expired(row, lifetime, now)) {
        files.retire(row)
        return false
      }
      if (lifetime > 0) files.write(Object.assign({}, row, { deadline: now + lifetime }))
      // Not a role: the model's rows all have the same.
      delete row.deadline
      return true
    })
    if (back.length === 0) return
    Qt.callLater(() => {
      for (var row of back) {
        // A notification that came while the files were read has a file of
        // its own, and is this toast if its id and time are this one's. One
        // with this id at another time may be its replacement or another
        // server's id: both show, as a toast twice beats a critical one lost.
        if (notifications.indexWhere(shown => shown.originalId === row.originalId && shown.timestamp === row.timestamp) >= 0) continue
        // Below what has just come, newest first.
        notifications.fromBefore[Notes.fileName(row)] = true
        notifications.toasts.append(row)
      }
    })
  }

  Component.onCompleted: {
    files.prepare(stateDir)
    Qt.callLater(() => {
      dndFile.reload()
      files.readToasts(text => notifications.bringBack(text))
      // After the read: the toasts it brings back are written again with
      // the copies they had, which the sweep keeps.
      files.sweep()
    })
  }

  // ------------------------------------------------------------------- IPC

  IpcHandler {
    target: "notifications"

    function dndState(): string {
      return notifications.doNotDisturb ? "on" : "off"
    }

    function toggleDnd(): string {
      notifications.setDoNotDisturb(!notifications.doNotDisturb)
      return dndState()
    }

    function showHistory(): string {
      notifications.showHistory()
      return "ok"
    }

    function dismissAll(): string {
      notifications.dismissAll()
      return "ok"
    }

    // The newest toast.
    function dismissOne(): string {
      if (notifications.toasts.count === 0) return "none"
      notifications.dismiss(0)
      return "ok"
    }

    // The newest toast, clicked.
    function invokeLast(): string {
      if (notifications.toasts.count === 0) return "none"
      notifications.invoke(0)
      return "ok"
    }
  }

  Variants {
    model: Quickshell.screens

    Parts.ToastWindow {
      required property var modelData
      screen: modelData
      service: notifications
    }
  }
}
