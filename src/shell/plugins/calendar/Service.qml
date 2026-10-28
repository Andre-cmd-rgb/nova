import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The calendar behind its window and the bar's clock: its file (Store.qml),
// and the reminders, said as notifications whether the window is open or not.
//
// The clock is looked at every minute at most, not slept on: a timer stops
// with the computer, so after a suspend the wall clock is what says how far
// it is. How far it has looked is kept in ~/.local/state/nova/calendar.json,
// a quarter of an hour behind at most; after a shutdown or a suspend, the
// reminders due since then are said if their event has not ended yet, or
// their task is still to do today.
Item {
  id: root

  property var shell: null

  readonly property var store: storeItem
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/nova/calendar.json"
  property real said: 0
  // What the file has: said is kept up to date as the clock is looked at, the
  // file only when a reminder is said, or a quarter of an hour on, so that
  // after a restart nothing older is gone over again.
  property real saidKept: 0
  property bool stateRead: false

  Store {
    id: storeItem
    onItemsChanged: root.schedule()
  }

  function remind() {
    if (!storeItem.loaded || !stateRead) return
    var now = Date.now()
    // Never said one: from now, not from the beginning of time.
    var from = said > 0 && said < now ? said : now
    var due = Model.alarms(storeItem.items, from, now).filter(function (a) { return Model.stillDue(a, now) })
    due.forEach(function (a) { root.notify(a, now) })
    said = now
    if (due.length > 0 || saidKept <= 0 || saidKept > now || now - saidKept >= 15 * Model.MINUTE) {
      saidKept = now
      stateFile.setText(JSON.stringify({ said: now }) + "\n")
    }
    schedule()
  }

  // Until the next reminder, and no longer than a minute.
  function schedule() {
    var now = Date.now()
    var next = Model.alarms(storeItem.items, now, now + 2 * Model.DAY)
    tick.interval = next.length ? Math.max(1000, Math.min(60000, next[0].time - now + 500)) : 60000
    tick.restart()
  }

  // ---- for the bar's clock: the days with anything on them, what a day
  //      has, a task ticked off, and the window opened on a day

  readonly property var items: storeItem.items

  // dayKey()s, between <from> and <to>.
  function busyDays(from, to) {
    return Model.busyDays(Model.occurrences(storeItem.items, from, to), from, to)
  }

  function agenda(day) {
    return Model.agenda(Model.occurrences(storeItem.items, day, Model.addDays(day, 1)), day)
  }

  function toggleTask(uid) {
    var task = storeItem.items.filter(function (i) { return i.uid === uid })[0]
    if (task) storeItem.updateTask(uid, { done: !task.done })
  }

  function show(day) {
    if (shell && typeof shell.summon === "function")
      shell.summon("nova.calendar", JSON.stringify(day ? { date: Model.dayKey(day) } : {}))
  }

  function clock(time) {
    return Qt.formatTime(new Date(time), /a/i.test(Qt.locale().timeFormat(Locale.ShortFormat)) ? "h:mm AP" : "HH:mm")
  }

  function notify(alarm, now) {
    var o = alarm.occ
    var title = o.item.title || (o.item.kind === "task" ? "Task" : "Event")
    var headline = title
    var detail = ""
    if (o.item.kind === "task") {
      detail = "Due at " + clock(o.start)
    } else if (o.item.allDay) {
      headline = title + (Model.dayStart(o.start) === Model.dayStart(now) ? ", today" : ", tomorrow")
      detail = "All day"
    } else {
      var minutes = Math.round((o.start - now) / Model.MINUTE)
      headline = minutes > 1 ? title + " in " + (minutes >= 120 ? Math.round(minutes / 60) + " hours" : minutes + " minutes")
        : minutes >= -1 ? title + ", now" : title + ", started at " + clock(o.start)
      detail = clock(o.start) + "–" + clock(o.end)
    }
    if (o.item.location) detail += " · " + o.item.location
    Quickshell.execDetached(["nova-notification-send", "-u", "normal", "-t", "30000", "-g", "󰃭", "--app-name", "Calendar", headline, detail,
      "--exec", "nova-shell", "shell", "summon", "nova.calendar", JSON.stringify({ date: Model.dayKey(o.start) })])
  }

  Process {
    running: true
    command: ["mkdir", "-p", root.statePath.replace(/\/[^\/]*$/, "")]
  }

  Timer {
    id: tick
    interval: 60000
    onTriggered: root.remind()
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var state = JSON.parse(text())
        root.said = root.saidKept = Number(state.said) || 0
      } catch (e) {
        root.said = root.saidKept = 0
      }
      root.stateRead = true
      root.remind()
    }
    onLoadFailed: {
      root.stateRead = true
      root.remind()
    }
  }

  Connections {
    target: storeItem
    function onLoadedChanged() { root.remind() }
  }
}
