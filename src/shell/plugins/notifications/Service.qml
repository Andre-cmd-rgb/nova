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
// or brings its app forward (not an iPhone's: the nova-iphone hint), a right
// click dismisses it. Nova's own may have
// buttons (the nova-buttons hint: AirDrop's Decline and Accept) and a bar
// (the value hint: a transfer under way).
//
// Do-not-disturb keeps the toasts off the screen, and what they would have
// said goes straight into the history, as does a notification sent with the
// nova-quiet hint: the last ten toasts gone, replayed on
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
    // The schedule's last turn made (Util.turnName), and whether
    // do-not-disturb is as it left it, with no switch by hand since.
    property string turn: ""
    property bool bySchedule: false
    onDoNotDisturbChanged: if (!dndFile.applying) dndFile.save()
  }

  readonly property bool doNotDisturb: memory.doNotDisturb

  // The switch by hand: the bar's, Settings', and the keys' and the menu's
  // (toggleDnd).
  function setDoNotDisturb(on) {
    memory.bySchedule = false
    memory.doNotDisturb = !!on
    dndFile.save()
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
      var settings = Notes.readSettings(content)
      if (settings.problem) console.warn("notifications: settings parse failed:", settings.problem)
      if (settings.dnd !== null) {
        applying = true
        memory.doNotDisturb = settings.dnd
        applying = false
      }
      memory.turn = settings.turn
      memory.bySchedule = settings.bySchedule
      read = true
      if (settings.legacy) save()
      notifications.followSchedule()
    }

    function save() {
      if (read) dndWrite.restart()
    }
  }

  Timer {
    id: dndWrite
    interval: 200
    onTriggered: dndFile.setText(JSON.stringify({ version: 3, dnd: memory.doNotDisturb, turn: memory.turn, bySchedule: memory.bySchedule }, null, 2) + "\n")
  }

  // Do-not-disturb at set hours every day: shell.json's doNotDisturb, which
  // nova notification schedule sets. Each turn is made once, and a switch by
  // hand lasts until the next, as on a Mac. The last one made is kept with
  // do-not-disturb, so that neither a restart nor a reboot makes it again,
  // and a turn missed while the computer was off is made as the shell
  // starts. A timer waits for the next turn; a sleep, a clock set or a new
  // time zone, which it does not follow, are heard of (Wake), and the
  // schedule is looked at and the timer aimed again then.
  readonly property var dndSchedule: shell && shell.shellConfig && shell.shellConfig.doNotDisturb ? shell.shellConfig.doNotDisturb : ({})
  readonly property bool dndScheduled: dndSchedule.schedule === "hours"
  readonly property int dndFrom: Util.minutesOf(dndSchedule.from, 22 * 60)
  readonly property int dndTo: Util.minutesOf(dndSchedule.to, 7 * 60)

  function followSchedule() {
    aimSchedule()
    if (!dndFile.read || !dndScheduled) return
    var turn = Util.lastTurn(Date.now(), dndFrom, dndTo)
    if (!turn || Util.turnName(turn) === memory.turn) return
    memory.turn = Util.turnName(turn)
    memory.bySchedule = true
    memory.doNotDisturb = turn.on
    dndFile.save()
  }

  // The timer, at the next turn (dndNext, ms); none without a schedule.
  property real dndNext: 0
  function aimSchedule() {
    var now = Date.now()
    var next = dndScheduled ? Util.nextTurn(now, dndFrom, dndTo) : null
    dndNext = next === null ? 0 : next
    if (next === null) {
      dndTurn.stop()
      return
    }
    dndTurn.interval = Util.intervalTo(next, now)
    dndTurn.restart()
  }

  Timer {
    id: dndTurn
    onTriggered: notifications.followSchedule()
  }

  // Switched off, the schedule ends a do-not-disturb it turned on, and
  // leaves one turned on by hand; and it forgets its last turn, so that it
  // makes it again when it is switched back on.
  function stopSchedule() {
    aimSchedule()
    if (!dndFile.read || memory.turn === "") return
    if (memory.bySchedule) memory.doNotDisturb = false
    memory.turn = ""
    memory.bySchedule = false
    dndFile.save()
  }

  // A turn later, once the schedule and its hours are all the new ones: a
  // change from off to set hours would otherwise see the hours from before.
  onDndScheduledChanged: dndScheduled ? Qt.callLater(followSchedule) : stopSchedule()
  onDndFromChanged: Qt.callLater(followSchedule)
  onDndToChanged: Qt.callLater(followSchedule)

  Connections {
    target: Wake
    function onWoke() {
      notifications.followSchedule()
    }
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

    if (doNotDisturb && !Notes.breaksThroughDnd(notification) || Notes.quiet(notification)) {
      // A question or a transfer under way would be stale in the history.
      if (!Notes.passing(notification) && !Notes.moot(row)) {
        silence(notification, row)
        return
      }
      delete senders[id]
      try {
        notification.expire()
      } catch (e) {
        // Freed by the server.
      }
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
        notifications.retire(row)
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
      // Let go as run out: nobody dismissed it, and a sender may do more on
      // a dismissal (an iPhone's notification is cleared on the iPhone).
      try {
        notification.expire()
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
    pull(row => row.originalId === id && row.timestamp === timestamp && !isFromBefore(row), row => notifications.retire(row))
  }

  // A toast's file into the history as it goes, or away with its copies if
  // what it said holds no longer (Notes.moot): an offer, a transfer under way.
  function retire(row) {
    if (Notes.moot(row)) files.drop(row)
    else files.retire(row)
  }

  // ---------------------------------------------------------------- toasts

  function dismiss(index) {
    leave(index, false)
  }

  function expire(index) {
    leave(index, true)
  }

  // A toast's time is up. Every screen counts it down, and the first to end
  // ends it, found by its stem: by the time another screen's count ends, the
  // index it had is the next toast's.
  function runOut(stem) {
    for (var i = 0; i < toasts.count; i++) {
      if (Notes.stem(toasts.get(i)) === stem) {
        expire(i)
        return
      }
    }
  }

  // Toast `index` off the screen, its file into the history, and its sender
  // told whether it ran out or was dismissed.
  function leave(index, ranOut) {
    if (index < 0 || index >= toasts.count) return
    var row = toasts.get(index)
    var notification = row.originalId >= 0 ? senderOf(row) : null
    retire(row)
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
  // else its app brought forward, as chat apps expect, but for an iPhone's,
  // whose app is not this computer's. Then it goes. One from before has
  // neither sender nor actions. One with buttons and no command is answered
  // with its buttons: a click beside them leaves it there.
  function invoke(index) {
    if (index < 0 || index >= toasts.count) return
    var row = toasts.get(index)
    var argv = Notes.runnable(row.execArgv)
    if (!argv && Notes.buttonsOf(row.buttons).length > 0) return
    if (argv) Util.execArgv(argv)
    else if (!runDefault(senderOf(row)) && row.app && !row.iphone) bringForward.start(row.app)
    dismiss(index)
  }

  // Button `which` of toast `index` pressed: its command, run apart from the
  // shell, and the toast goes.
  function press(index, which) {
    if (index < 0 || index >= toasts.count) return
    var button = Notes.buttonsOf(toasts.get(index).buttons)[which]
    if (!button) return
    Util.execArgv(button.argv)
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
      next = String(app)
      if (!running) focusNext()
    }

    function focusNext() {
      if (next === "") return
      command = ["nova-hyprland-focus-app", next]
      next = ""
      running = true
    }

    onExited: focusNext()
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
      // Off the screen into the history, not dismissed: they are in the
      // replay.
      while (toasts.count > 0) leave(0, true)
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
      // An offer or a transfer under way was the shell before's to follow:
      // its sender asks again if it still stands.
      if (Notes.moot(row)) {
        files.drop(row)
        return false
      }
      var lifetime = Notes.lifetime(row.urgency, row.expireTimeout)
      if (Notes.expired(row, lifetime, now)) {
        notifications.retire(row)
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
