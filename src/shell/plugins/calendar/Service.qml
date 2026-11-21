import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "Model.js" as Model

// The calendar behind its window and the bar's clock: its calendars
// (Calendars.qml), and the reminders, said as notifications whether the window
// is open or not.
//
// A timer waits for the next reminder, two days ahead at most, and looks
// again a day on when there is none. It runs on the monotonic clock, which
// stands still while the computer sleeps and does not follow a clock set or
// a new time zone: those are heard of (Wake), and the reminders due since
// are said and the timer aimed again then. A reminder already past when its
// event or task comes in (a sync, an event added for earlier today) is not
// said: the phone that made it has said it, or it was never to come. How far
// it has looked is kept in ~/.local/state/nova/calendar.json, written when a
// restart would otherwise go over a reminder's time again, and two days on at
// the latest (keep()); after a shutdown, the reminders due since then are said if their event has
// not ended yet, or their task is still to do today.
Item {
  id: root

  property var shell: null

  readonly property var store: storeItem
  readonly property string statePath: Commons.Color.stateHome + "/nova/calendar.json"
  property real said: 0
  // What the file has: said is kept up to date as the clock is looked at,
  // the file only when that changes what a restart would go over, which is
  // when a reminder's time lies between the two (keep()); when there is none
  // yet, or the clock went back past it; and two days on at the latest.
  property real saidKept: 0
  property bool stateRead: false
  // Whether the reminders have been looked at once since the calendar and
  // the file were read: what a restart missed is said then.
  property bool looked: false
  // Until when the reminders as last looked at had none due: the next one's
  // time, or how far that look reached. Past it, one may be due that the
  // timer or a wake has not come to yet.
  property real quietUntil: 0

  Calendars {
    id: storeItem
    onItemsChanged: root.changed()
  }

  // The events or tasks changed. A reminder of those before that has come
  // due is said, from the list as it is now; otherwise none has, and a
  // reminder the change brings that is already past is not said: said moves
  // to now, over it.
  function changed() {
    var now = Date.now()
    if (!looked || now >= quietUntil) {
      remind()
      return
    }
    said = now
    keep(now)
    schedule(now)
  }

  // The file moved on to <now> when a restart would go over a reminder again
  // from what it has, or it has nothing yet, or the clock went back past it.
  function keep(now) {
    // Two days on, written whatever: a look over a longer time costs more
    // than the write.
    if (saidKept > 0 && saidKept <= now && now - saidKept < 2 * Model.DAY
      && Model.alarms(storeItem.items, saidKept, now).length === 0) return
    saidKept = now
    stateFile.setText(JSON.stringify({ said: now }) + "\n")
  }

  function remind() {
    if (!storeItem.loaded || !stateRead) return
    var now = Date.now()
    // Never said one: from now, not from the beginning of time.
    var from = said > 0 && said < now ? said : now
    var due = Model.alarms(storeItem.items, from, now).filter(function (a) { return Model.stillDue(a, now) })
    due.forEach(function (a) { root.notify(a, now) })
    said = now
    looked = true
    keep(now)
    schedule(now)
  }

  // Until the next reminder (nextAlarm, ms; 0 with none in two days), and
  // no longer than a day.
  property real nextAlarm: 0
  // From <now>, the time the look before it went to: a reminder between the
  // two is neither said nor waited for otherwise.
  function schedule(now) {
    var next = Model.alarms(storeItem.items, now, now + 2 * Model.DAY)
    nextAlarm = next.length ? next[0].time : 0
    quietUntil = next.length ? next[0].time : now + 2 * Model.DAY
    tick.interval = Commons.Util.intervalTo(next.length ? next[0].time : now + Model.DAY, now)
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

  // The first moment of a day by its key (2026-09-06), or of the day <after>
  // days on, as the calendar counts days: what the clock asks about.
  function dayStart(key, after) {
    return Model.addDays(Model.parseDayKey(key), after || 0)
  }

  function toggleTask(uid, calendarId) {
    var task = storeItem.items.filter(function (i) { return i.uid === uid && (!calendarId || i.calendar === calendarId) })[0]
    if (task) storeItem.updateTask(uid, { done: !task.done }, task.calendar)
  }

  function colorOf(calendarId) {
    return storeItem.colorOf(calendarId)
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

  Connections {
    target: Commons.Wake
    function onWoke() { root.remind() }
  }
}
