.import "Ical.js" as Ical

// The calendar's events and tasks: read out of its iCalendar file (Ical.js),
// laid out on the days they fall on, their reminders, and the edits the
// window makes, written back into the same file.
//
// An item is one VEVENT or VTODO: { kind: "event" | "task", uid, title,
// notes, location, allDay, start, end, due, dueTime, done, rrule, exdates,
// recurrenceId, reminder }. Times are milliseconds; an all-day event's end is
// the midnight after its last day. An occurrence is one time an item falls
// on: { item, uid, start, end, instance, recurring }, where instance is the
// start the series gave it, which an occurrence moved on its own keeps.

var MINUTE = 60000
var HOUR = 3600000
var DAY = 86400000
var DAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

// ---- days, on the local wall clock

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function dayStart(time) {
  var t = new Date(time)
  return new Date(t.getFullYear(), t.getMonth(), t.getDate()).getTime()
}

// <n> days on, at the same time on the clock across a DST change.
function addDays(time, n) {
  var t = new Date(time)
  t.setDate(t.getDate() + n)
  return t.getTime()
}

function daysBetween(a, b) {
  return Math.round((dayStart(b) - dayStart(a)) / DAY)
}

function dayKey(time) {
  var t = new Date(time)
  return t.getFullYear() + "-" + pad2(t.getMonth() + 1) + "-" + pad2(t.getDate())
}

// "2026-10-29" as its local midnight, or NaN.
function parseDayKey(key) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(key || ""))
  if (!m) return NaN
  var t = new Date(+m[1], +m[2] - 1, +m[3])
  return t.getMonth() === +m[2] - 1 ? t.getTime() : NaN
}

// Minutes since the day's midnight, as the clock shows them.
function minutesInDay(time) {
  var t = new Date(time)
  return t.getHours() * 60 + t.getMinutes()
}

function atMinutes(day, minutes) {
  var t = new Date(day)
  t.setHours(0, minutes, 0, 0)
  return t.getTime()
}

// The first day of the week <time> is in, a week starting on <weekStart>
// (0 Sunday … 6 Saturday).
function weekOf(time, weekStart) {
  var day = dayStart(time)
  return addDays(day, -((new Date(day).getDay() - weekStart + 7) % 7))
}

// The weeks a month's grid shows, six of seven days each, from the week of
// its first day.
function monthWeeks(year, month, weekStart) {
  var first = weekOf(new Date(year, month, 1).getTime(), weekStart)
  var weeks = []
  for (var w = 0; w < 6; w++) {
    var days = []
    for (var d = 0; d < 7; d++) days.push(addDays(first, w * 7 + d))
    weeks.push(days)
  }
  return weeks
}

// The day weeks start on, as the bar's clock keeps it in shell.json
// ("monday", "sun", 1), or <fallback>, the locale's.
function weekStartFrom(value, fallback) {
  var names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
  var text = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
  for (var i = 0; i < 7; i++) if (text !== "" && (names[i] === text || names[i].slice(0, 3) === text)) return i
  var n = parseInt(text, 10)
  return isFinite(n) ? ((n % 7) + 7) % 7 : ((fallback % 7) + 7) % 7
}

function snap(minutes, step) {
  return Math.round(minutes / step) * step
}

// What a time typed in reads as, in minutes after midnight, or NaN: 9, 930,
// 9:30, 09.30, 9:30 pm, 21:30.
function parseClock(text) {
  var m = /^\s*(\d{1,2})(?:[:.h]?(\d{2}))?\s*([ap]\.?m?\.?)?\s*$/i.exec(String(text || ""))
  if (!m) return NaN
  var h = +m[1], min = m[2] === undefined ? 0 : +m[2]
  if (m[3]) {
    if (h < 1 || h > 12) return NaN
    h = h % 12 + (/^p/i.test(m[3]) ? 12 : 0)
  }
  return h < 24 && min < 60 ? h * 60 + min : NaN
}

// A day typed in: 2026-10-29, or 29/10/2026 and 29.10.2026, day first, as
// the interface is English but not American. Its midnight, or NaN.
function parseDate(text) {
  var t = String(text || "").trim()
  var iso = parseDayKey(t)
  if (!isNaN(iso)) return iso
  var m = /^(\d{1,2})[\/.](\d{1,2})[\/.](\d{4})$/.exec(t)
  if (!m) return NaN
  var d = new Date(+m[3], +m[2] - 1, +m[1])
  return d.getMonth() === +m[2] - 1 && d.getDate() === +m[1] ? d.getTime() : NaN
}

function formatClock(minutes) {
  return pad2(Math.floor(minutes / 60) % 24) + ":" + pad2(minutes % 60)
}

// ---- reading

function calendarOf(root) {
  var cal = Ical.child(root, "VCALENDAR")
  if (!cal) {
    cal = { name: "VCALENDAR", props: [], components: [] }
    Ical.setProp(cal, "VERSION", "2.0")
    Ical.setProp(cal, "PRODID", "-//Nova//Calendar//EN")
    root.components.push(cal)
  }
  return cal
}

// An empty file, or one that is not a calendar, reads as no items.
function parse(text) {
  var root = Ical.parse(text)
  calendarOf(root)
  return root
}

// FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY and WKST, as far as this
// calendar repeats them. Anything more (BYSETPOS, BYMONTH, an hourly rule)
// is kept in the file but not followed: such a series shows its first time.
function parseRrule(value) {
  if (!value) return null
  var rule = { freq: "", interval: 1, count: 0, until: null, byday: [], bymonthday: [], wkst: 1, supported: true, text: String(value) }
  var parts = String(value).split(";")
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq < 0) continue
    var key = parts[i].slice(0, eq).toUpperCase()
    var val = parts[i].slice(eq + 1).toUpperCase()
    if (key === "FREQ") rule.freq = val
    else if (key === "INTERVAL") rule.interval = Math.max(1, parseInt(val, 10) || 1)
    else if (key === "COUNT") rule.count = Math.max(0, parseInt(val, 10) || 0)
    else if (key === "UNTIL") {
      var until = Ical.parseTime({ value: val, params: {} })
      if (until) rule.until = until.allDay ? addDays(until.time, 1) - 1 : until.time
    } else if (key === "BYDAY") {
      var days = val.split(",")
      for (var d = 0; d < days.length; d++) {
        var m = /^([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)$/.exec(days[d])
        if (!m) { rule.supported = false; continue }
        rule.byday.push({ n: m[1] ? parseInt(m[1], 10) : 0, day: DAYS.indexOf(m[2]) })
      }
    } else if (key === "BYMONTHDAY") {
      var mdays = val.split(",")
      for (var k = 0; k < mdays.length; k++) {
        var md = parseInt(mdays[k], 10)
        if (md && md >= -31 && md <= 31) rule.bymonthday.push(md)
        else rule.supported = false
      }
    } else if (key === "WKST") {
      var w = DAYS.indexOf(val)
      if (w >= 0) rule.wkst = w
    } else {
      rule.supported = false
    }
  }
  if (["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].indexOf(rule.freq) < 0) rule.supported = false
  var ordinals = rule.byday.some(function (b) { return b.n !== 0 })
  if (ordinals && rule.freq !== "MONTHLY") rule.supported = false
  if (rule.bymonthday.length && rule.freq !== "MONTHLY") rule.supported = false
  if (rule.freq === "YEARLY" && rule.byday.length) rule.supported = false
  return rule
}

function timesOf(propsList) {
  var out = []
  for (var i = 0; i < propsList.length; i++) {
    var values = String(propsList[i].value).split(",")
    for (var j = 0; j < values.length; j++) {
      var t = Ical.parseTime({ value: values[j], params: propsList[i].params })
      if (t) out.push(t.time)
    }
  }
  return out
}

// The first reminder relative to the start: what the window sets, and what
// most programs write. One at the end, or at a fixed time, is not shown.
function reminderOf(c) {
  for (var i = 0; i < c.components.length; i++) {
    var a = c.components[i]
    if (a.name !== "VALARM") continue
    var trigger = Ical.prop(a, "TRIGGER")
    if (!trigger || trigger.params.RELATED === "END" || trigger.params.VALUE === "DATE-TIME") continue
    var offset = Ical.parseDuration(trigger.value)
    if (offset !== null) return offset
  }
  return null
}

function itemOf(c) {
  var start = Ical.parseTime(Ical.prop(c, "DTSTART"))
  var uid = Ical.text(c, "UID")
  var recurrence = Ical.parseTime(Ical.prop(c, "RECURRENCE-ID"))
  var item = {
    kind: c.name === "VTODO" ? "task" : "event",
    uid: uid,
    title: Ical.text(c, "SUMMARY"),
    notes: Ical.text(c, "DESCRIPTION"),
    location: Ical.text(c, "LOCATION"),
    allDay: false,
    start: 0,
    end: 0,
    due: null,
    dueTime: false,
    done: false,
    rrule: null,
    exdates: [],
    recurrenceId: recurrence ? recurrence.time : null,
    reminder: reminderOf(c)
  }
  if (c.name === "VTODO") {
    var due = Ical.parseTime(Ical.prop(c, "DUE")) || start
    if (due) {
      item.due = due.time
      item.dueTime = !due.allDay
      item.allDay = due.allDay
      item.start = item.end = due.time
    }
    var status = Ical.text(c, "STATUS").toUpperCase()
    item.done = status === "COMPLETED" || (status === "" && Ical.prop(c, "COMPLETED") !== null)
    return item
  }
  if (!start) return null
  item.allDay = start.allDay
  item.start = start.time
  var end = Ical.parseTime(Ical.prop(c, "DTEND"))
  var duration = Ical.prop(c, "DURATION")
  if (end) item.end = end.time
  else if (duration && Ical.parseDuration(duration.value) !== null) item.end = start.time + Ical.parseDuration(duration.value)
  else item.end = start.allDay ? addDays(start.time, 1) : start.time
  if (item.allDay && item.end <= item.start) item.end = addDays(item.start, 1)
  if (item.end < item.start) item.end = item.start
  var rrule = Ical.prop(c, "RRULE")
  if (rrule && item.recurrenceId === null) item.rrule = parseRrule(rrule.value)
  item.exdates = timesOf(Ical.props(c, "EXDATE"))
  return item
}

function items(root) {
  var cal = calendarOf(root)
  var out = []
  for (var i = 0; i < cal.components.length; i++) {
    var c = cal.components[i]
    if (c.name !== "VEVENT" && c.name !== "VTODO") continue
    var item = itemOf(c)
    if (item && item.uid) out.push(item)
  }
  return out
}

// ---- repeating

// The days a period of the rule offers, in order, at the series' time of day.
function periodStarts(item, rule, k) {
  var first = new Date(item.start)
  var minutes = first.getHours() * 60 + first.getMinutes()
  var seconds = first.getSeconds()
  function at(y, m, d) {
    var t = new Date(y, m, d, 0, minutes, seconds)
    return t.getTime()
  }
  var out = []
  if (rule.freq === "DAILY") {
    var day = new Date(first.getFullYear(), first.getMonth(), first.getDate() + k * rule.interval)
    var weekdays = rule.byday.map(function (b) { return b.day })
    if (!weekdays.length || weekdays.indexOf(day.getDay()) >= 0) out.push(at(day.getFullYear(), day.getMonth(), day.getDate()))
  } else if (rule.freq === "WEEKLY") {
    var weekStart = new Date(weekOf(item.start, rule.wkst))
    var days = rule.byday.length ? rule.byday.map(function (b) { return b.day }) : [first.getDay()]
    var offsets = days.map(function (d) { return (d - rule.wkst + 7) % 7 }).sort(function (a, b) { return a - b })
    for (var i = 0; i < offsets.length; i++) {
      if (i > 0 && offsets[i] === offsets[i - 1]) continue
      out.push(at(weekStart.getFullYear(), weekStart.getMonth(), weekStart.getDate() + k * 7 * rule.interval + offsets[i]))
    }
  } else if (rule.freq === "MONTHLY") {
    var month = new Date(first.getFullYear(), first.getMonth() + k * rule.interval, 1)
    var y = month.getFullYear(), m = month.getMonth()
    var length = new Date(y, m + 1, 0).getDate()
    var dates = []
    if (rule.bymonthday.length) {
      rule.bymonthday.forEach(function (d) {
        var date = d > 0 ? d : length + d + 1
        if (date >= 1 && date <= length) dates.push(date)
      })
    } else if (rule.byday.length) {
      rule.byday.forEach(function (b) {
        var matches = []
        for (var d = 1; d <= length; d++) if (new Date(y, m, d).getDay() === b.day) matches.push(d)
        if (b.n === 0) dates = dates.concat(matches)
        else {
          var pick = b.n > 0 ? matches[b.n - 1] : matches[matches.length + b.n]
          if (pick) dates.push(pick)
        }
      })
    } else if (first.getDate() <= length) {
      dates.push(first.getDate())
    }
    dates.sort(function (a, b) { return a - b })
    for (var j = 0; j < dates.length; j++) if (j === 0 || dates[j] !== dates[j - 1]) out.push(at(y, m, dates[j]))
  } else if (rule.freq === "YEARLY") {
    var year = first.getFullYear() + k * rule.interval
    var candidate = new Date(year, first.getMonth(), first.getDate())
    if (candidate.getMonth() === first.getMonth()) out.push(at(year, first.getMonth(), first.getDate()))
  }
  return out
}

// The starts of a series that are on screen between <from> and <to>: those
// that begin before <to> and end after <from>. The first is the series' own
// start; COUNT counts the times the rule makes, EXDATE takes some away.
function expand(item, from, to) {
  var length = item.end - item.start
  var visible = function (s) { return s < to && Math.max(s + length, s + 1) > from }
  var excluded = function (s) { return item.exdates.indexOf(s) >= 0 }
  var rule = item.rrule
  if (!rule || !rule.supported) return visible(item.start) && !excluded(item.start) ? [item.start] : []
  var out = []
  var n = 0
  // Without a count, the periods long before the window need not be walked.
  var k = 0
  if (!rule.count && (rule.freq === "DAILY" || rule.freq === "WEEKLY")) {
    var span = (rule.freq === "DAILY" ? 1 : 7) * rule.interval * DAY
    k = Math.max(0, Math.floor((from - length - item.start) / span) - 1)
  }
  if (k === 0 || rule.count) {
    n = 1
    if (visible(item.start) && !excluded(item.start)) out.push(item.start)
  }
  for (var guard = 0; guard < 5000; guard++, k++) {
    var starts = periodStarts(item, rule, k)
    for (var i = 0; i < starts.length; i++) {
      var s = starts[i]
      if (s <= item.start) continue
      if (rule.until !== null && s > rule.until) return out
      if (s >= to) return out
      if (rule.count && ++n > rule.count) return out
      if (visible(s) && !excluded(s)) out.push(s)
    }
    if (rule.count && n >= rule.count) return out
  }
  return out
}

function byStart(a, b) {
  if (a.start !== b.start) return a.start - b.start
  if (a.item.allDay !== b.item.allDay) return a.item.allDay ? -1 : 1
  return String(a.item.title).localeCompare(String(b.item.title))
}

// Every occurrence between <from> and <to>: events, the times a series
// falls on (one moved on its own in its place), and dated tasks on their day.
function occurrences(list, from, to) {
  var moved = {}
  list.forEach(function (item) {
    if (item.kind === "event" && item.recurrenceId !== null) moved[item.uid + "@" + item.recurrenceId] = true
  })
  var out = []
  list.forEach(function (item) {
    if (item.kind === "task") {
      if (item.due === null) return
      var day = dayStart(item.due)
      if (day < to && addDays(day, 1) > from) out.push({ item: item, uid: item.uid, start: item.due, end: item.due, instance: item.due, recurring: false })
      return
    }
    if (item.recurrenceId !== null) {
      if (item.start < to && Math.max(item.end, item.start + 1) > from)
        out.push({ item: item, uid: item.uid, start: item.start, end: item.end, instance: item.recurrenceId, recurring: true })
      return
    }
    var starts = expand(item, from, to)
    for (var i = 0; i < starts.length; i++) {
      if (moved[item.uid + "@" + starts[i]]) continue
      out.push({ item: item, uid: item.uid, start: starts[i], end: starts[i] + (item.end - item.start), instance: starts[i], recurring: item.rrule !== null })
    }
  })
  return out.sort(byStart)
}

// ---- laying out

// A day's timed events as boxes in minutes from its midnight, side by side
// where they overlap: { occ, top, bottom, column, columns }. One that starts
// the day before, or ends the day after, is cut at midnight; none is shorter
// than a quarter of an hour.
function dayLayout(occs, day) {
  var next = addDays(day, 1)
  var boxes = []
  occs.forEach(function (o) {
    if (o.item.kind !== "event" || o.item.allDay) return
    if (o.start >= next || Math.max(o.end, o.start + 1) <= day) return
    var top = o.start <= day ? 0 : minutesInDay(o.start)
    var bottom = o.end >= next ? 1440 : minutesInDay(o.end)
    if (o.end > day && bottom === 0) bottom = 1440
    bottom = Math.min(1440, Math.max(bottom, top + 15))
    boxes.push({ occ: o, top: top, bottom: bottom, column: 0, columns: 1 })
  })
  boxes.sort(function (a, b) { return a.top - b.top || b.bottom - a.bottom })
  var cluster = []
  var clusterEnd = -1
  function place() {
    var ends = []
    cluster.forEach(function (box) {
      var col = 0
      while (col < ends.length && ends[col] > box.top) col++
      ends[col] = box.bottom
      box.column = col
    })
    cluster.forEach(function (box) { box.columns = ends.length })
  }
  boxes.forEach(function (box) {
    if (cluster.length && box.top >= clusterEnd) {
      place()
      cluster = []
      clusterEnd = -1
    }
    cluster.push(box)
    clusterEnd = Math.max(clusterEnd, box.bottom)
  })
  if (cluster.length) place()
  return boxes
}

// What a day has besides its timed events: the all-day events on it, then
// its tasks, those still to do first.
function dayItems(occs, day) {
  var next = addDays(day, 1)
  var events = occs.filter(function (o) {
    return o.item.kind === "event" && o.item.allDay && o.start < next && o.end > day
  })
  var tasks = occs.filter(function (o) {
    return o.item.kind === "task" && o.start >= day && o.start < next
  }).sort(function (a, b) { return (a.item.done - b.item.done) || byStart(a, b) })
  return events.concat(tasks)
}

// Everything on a day, in the order the bar's agenda reads it: all-day
// events, the timed ones by their start, then the tasks.
function agenda(occs, day) {
  var next = addDays(day, 1)
  var timed = occs.filter(function (o) {
    return o.item.kind === "event" && !o.item.allDay && o.start < next && Math.max(o.end, o.start + 1) > day
  })
  var rest = dayItems(occs, day)
  var allDay = rest.filter(function (o) { return o.item.kind === "event" })
  var tasks = rest.filter(function (o) { return o.item.kind === "task" })
  return allDay.concat(timed, tasks)
}

// The days between <from> and <to> with anything on them, as dayKey()s.
function busyDays(occs, from, to) {
  var out = {}
  occs.forEach(function (o) {
    var last = o.item.kind === "task" ? o.start : (o.item.allDay ? o.end - 1 : Math.max(o.start, o.end - 1))
    for (var d = dayStart(o.start); d <= last && d < to; d = addDays(d, 1))
      if (d >= dayStart(from)) out[dayKey(d)] = true
  })
  return out
}

// Tasks still to do from before <today>, the oldest first.
function overdueTasks(list, today) {
  return list.filter(function (i) { return i.kind === "task" && !i.done && i.due !== null && i.due < today })
    .sort(function (a, b) { return a.due - b.due })
}

// Tasks with no day, those still to do first, then by title.
function undatedTasks(list) {
  return list.filter(function (i) { return i.kind === "task" && i.due === null })
    .sort(function (a, b) { return (a.done - b.done) || String(a.title).localeCompare(String(b.title)) })
}

// ---- reminders

// The reminders due after <from>, up to and including <to>: { time, occ }.
// An event's comes its reminder before its start (or after, for an all-day
// event's "on the day"); a task with a time, at that time, while not done.
function alarms(list, from, to) {
  var out = []
  occurrences(list, from - 2 * DAY, to + 2 * DAY).forEach(function (o) {
    var time = null
    if (o.item.kind === "event" && o.item.reminder !== null) time = o.start + o.item.reminder
    else if (o.item.kind === "task" && o.item.dueTime && !o.item.done) time = o.start
    if (time !== null && time > from && time <= to) out.push({ time: time, occ: o })
  })
  return out.sort(function (a, b) { return a.time - b.time })
}

// What a reminder is for, once its time has passed: an event still to end,
// or a task still to do, today. A shutdown over the time of one an hour
// before a meeting that is over says nothing of it.
function stillDue(alarm, now) {
  var o = alarm.occ
  if (o.item.kind === "task") return !o.item.done && dayStart(o.start) === dayStart(now)
  return Math.max(o.end, o.start + 1) > now
}

// ---- repeat and reminder choices, as the window offers them

var REPEATS = [
  { value: "none", label: "Never" },
  { value: "daily", label: "Every Day" },
  { value: "weekdays", label: "Every Weekday" },
  { value: "weekly", label: "Every Week" },
  { value: "biweekly", label: "Every 2 Weeks" },
  { value: "monthly", label: "Every Month" },
  { value: "yearly", label: "Every Year" }
]

function repeatRule(preset, start) {
  var day = DAYS[new Date(start).getDay()]
  switch (preset) {
    case "daily": return "FREQ=DAILY"
    case "weekdays": return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
    case "weekly": return "FREQ=WEEKLY;BYDAY=" + day
    case "biweekly": return "FREQ=WEEKLY;INTERVAL=2;BYDAY=" + day
    case "monthly": return "FREQ=MONTHLY"
    case "yearly": return "FREQ=YEARLY"
  }
  return ""
}

// The choice a rule is, or "custom" for one the window did not make (an end
// date, a count, other days), which it keeps until another is picked.
function repeatPreset(rule, start) {
  if (!rule) return "none"
  if (rule.count || rule.until !== null || !rule.supported) return "custom"
  var presets = ["daily", "weekdays", "weekly", "biweekly", "monthly", "yearly"]
  for (var i = 0; i < presets.length; i++) {
    var made = parseRrule(repeatRule(presets[i], start))
    if (sameRule(made, rule)) return presets[i]
  }
  return "custom"
}

function sameRule(a, b) {
  var days = function (r) { return r.byday.map(function (x) { return x.n + ":" + x.day }).sort().join(",") }
  return a.freq === b.freq && a.interval === b.interval && days(a) === days(b) &&
    a.bymonthday.join(",") === b.bymonthday.join(",")
}

var TIMED_REMINDERS = [
  { value: "none", label: "None" },
  { value: "0", label: "At the Start" },
  { value: "-300000", label: "5 Minutes Before" },
  { value: "-600000", label: "10 Minutes Before" },
  { value: "-900000", label: "15 Minutes Before" },
  { value: "-1800000", label: "30 Minutes Before" },
  { value: "-3600000", label: "1 Hour Before" },
  { value: "-86400000", label: "1 Day Before" }
]

var ALL_DAY_REMINDERS = [
  { value: "none", label: "None" },
  { value: "32400000", label: "On the Day, 9:00" },
  { value: "-54000000", label: "The Day Before, 9:00" }
]

// A new timed event's; a new all-day one has none.
var DEFAULT_REMINDER = -10 * MINUTE

function reminderValue(offset) {
  return offset === null || offset === undefined ? "none" : String(offset)
}

function reminderOffset(value) {
  return value === "none" || value === "" || value === undefined ? null : parseInt(value, 10)
}

// The reminder's choice, with one the window did not make added as itself.
function reminderOptions(allDay, offset) {
  var options = (allDay ? ALL_DAY_REMINDERS : TIMED_REMINDERS).slice()
  var value = reminderValue(offset)
  if (!options.some(function (o) { return o.value === value })) {
    var minutes = Math.round(Math.abs(offset) / MINUTE)
    options.push({ value: value, label: minutes + (minutes === 1 ? " Minute " : " Minutes ") + (offset < 0 ? "Before" : "After") })
  }
  return options
}

// ---- editing

function newUid(now) {
  return Math.floor(now).toString(36) + "-" + Math.floor(Math.random() * 2147483647).toString(36) + "@nova"
}

function componentsOf(root, uid) {
  return calendarOf(root).components.filter(function (c) {
    return (c.name === "VEVENT" || c.name === "VTODO") && Ical.text(c, "UID") === uid
  })
}

function masterOf(root, uid) {
  var list = componentsOf(root, uid).filter(function (c) { return !Ical.prop(c, "RECURRENCE-ID") })
  return list.length ? list[0] : null
}

function overrideOf(root, uid, instance) {
  var list = componentsOf(root, uid).filter(function (c) {
    var r = Ical.parseTime(Ical.prop(c, "RECURRENCE-ID"))
    return r && r.time === instance
  })
  return list.length ? list[0] : null
}

// A change is stamped as one, for whatever later reads or syncs the file.
function touch(c, now) {
  Ical.setProp(c, "DTSTAMP", Ical.formatUtc(now))
  Ical.setProp(c, "LAST-MODIFIED", Ical.formatUtc(now))
  var seq = Ical.prop(c, "SEQUENCE")
  if (seq) Ical.setProp(c, "SEQUENCE", (parseInt(seq.value, 10) || 0) + 1)
}

function setText(c, name, value) {
  if (value) Ical.setProp(c, name, Ical.escapeText(value))
  else Ical.removeProp(c, name)
}

function setReminder(c, offset) {
  c.components = c.components.filter(function (a) { return a.name !== "VALARM" })
  if (offset === null || offset === undefined) return
  var alarm = { name: "VALARM", props: [], components: [] }
  Ical.setProp(alarm, "ACTION", "DISPLAY")
  Ical.setProp(alarm, "DESCRIPTION", "Reminder")
  Ical.setProp(alarm, "TRIGGER", Ical.formatDuration(offset))
  c.components.push(alarm)
}

function setTimes(c, start, end, allDay, zone) {
  Ical.setTime(c, "DTSTART", start, allDay, zone)
  Ical.removeProp(c, "DURATION")
  Ical.setTime(c, "DTEND", allDay ? Math.max(end, addDays(dayStart(start), 1)) : Math.max(end, start), allDay, zone)
}

// <fields>: { title, notes, location, start, end, allDay, repeat, reminder }.
// Returns the new event's uid.
function addEvent(root, fields, now, zone) {
  var c = { name: "VEVENT", props: [], components: [] }
  var uid = newUid(now)
  Ical.setProp(c, "UID", uid)
  Ical.setProp(c, "DTSTAMP", Ical.formatUtc(now))
  Ical.setProp(c, "CREATED", Ical.formatUtc(now))
  Ical.setProp(c, "LAST-MODIFIED", Ical.formatUtc(now))
  Ical.setProp(c, "SEQUENCE", "0")
  setTimes(c, fields.start, fields.end, !!fields.allDay, zone)
  setText(c, "SUMMARY", fields.title || "New Event")
  setText(c, "DESCRIPTION", fields.notes)
  setText(c, "LOCATION", fields.location)
  var rule = repeatRule(fields.repeat, fields.start)
  if (rule) Ical.setProp(c, "RRULE", rule)
  setReminder(c, fields.reminder === undefined ? null : fields.reminder)
  calendarOf(root).components.push(c)
  return uid
}

// A time the series was given (an EXDATE, a RECURRENCE-ID) moved with it.
function shiftTimes(c, name, delta, allDay, zone) {
  var shifted = timesOf(Ical.props(c, name)).map(function (t) { return t + delta })
  Ical.removeProp(c, name)
  shifted.forEach(function (t) {
    c.props.push({ name: name, params: allDay ? { VALUE: "DATE" } : (zone ? { TZID: zone } : {}),
      value: allDay ? Ical.formatDate(t) : Ical.formatLocal(t) })
  })
}

// The days of a weekly rule, moved <days> on with the series.
function shiftRuleDays(c, days) {
  var p = Ical.prop(c, "RRULE")
  if (!p || days % 7 === 0) return
  var value = p.value.replace(/BYDAY=([^;]*)/i, function (m, list) {
    return "BYDAY=" + list.split(",").map(function (d) {
      var x = /^([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)$/i.exec(d)
      if (!x) return d
      return (x[1] || "") + DAYS[(DAYS.indexOf(x[2].toUpperCase()) + days % 7 + 7) % 7]
    }).join(",")
  })
  Ical.setProp(c, "RRULE", value, p.params)
}

// Edits the occurrence of <uid> that the series put at <instance>: on its
// own (scope "this", for one time of a series) or the whole event. Only the
// fields given change. For the whole series, a new start moves it by as much
// as it moves this time from where the series put it, its other times and
// its weekdays with it.
function updateEvent(root, uid, instance, fields, scope, now, zone) {
  var done = editEvent(root, uid, instance, fields, scope, now, zone)
  if (done) dropOrphans(root, uid)
  return done
}

function editEvent(root, uid, instance, fields, scope, now, zone) {
  var master = masterOf(root, uid)
  var own = overrideOf(root, uid, instance)
  if (!master && !own) return false
  var item = itemOf(master || own)
  var series = master && item.rrule !== null
  if (series && scope === "this") {
    if (!own) {
      own = JSON.parse(JSON.stringify(master))
      own.props = own.props.filter(function (p) {
        return ["RRULE", "EXDATE", "RDATE", "DTSTART", "DTEND", "DURATION"].indexOf(p.name) < 0
      })
      var length = item.end - item.start
      Ical.setTime(own, "RECURRENCE-ID", instance, item.allDay, zone)
      setTimes(own, instance, instance + length, item.allDay, zone)
      calendarOf(root).components.push(own)
    }
    return applyFields(own, fields, now, zone, false)
  }
  if (!master) return applyFields(own, fields, now, zone, false)
  if (series && fields.start !== undefined) {
    var current = { start: instance, end: instance + (item.end - item.start) }
    var delta = fields.start - current.start
    var newLength = (fields.end !== undefined ? fields.end : fields.start + (current.end - current.start)) - fields.start
    var allDay = fields.allDay !== undefined ? !!fields.allDay : item.allDay
    var masterFields = {}
    for (var key in fields) masterFields[key] = fields[key]
    masterFields.start = item.start + delta
    masterFields.end = item.start + delta + newLength
    if (delta !== 0) {
      shiftTimes(master, "EXDATE", delta, allDay, zone)
      // The times moved on their own stay as far from the series' as they were.
      componentsOf(root, uid).forEach(function (c) {
        if (c === master || c === own || !Ical.prop(c, "RECURRENCE-ID")) return
        var moved = itemOf(c)
        shiftTimes(c, "RECURRENCE-ID", delta, allDay, zone)
        setTimes(c, moved.start + delta, moved.end + delta, moved.allDay, zone)
      })
      shiftRuleDays(master, daysBetween(current.start, fields.start))
    }
    // The time moved for all of them: one that had its own goes with them.
    if (own) removeComponent(root, own)
    return applyFields(master, masterFields, now, zone, true)
  }
  return applyFields(master, fields, now, zone, true)
}

function applyFields(c, fields, now, zone, isMaster) {
  var item = itemOf(c)
  if (fields.title !== undefined) setText(c, "SUMMARY", fields.title || "New Event")
  if (fields.notes !== undefined) setText(c, "DESCRIPTION", fields.notes)
  if (fields.location !== undefined) setText(c, "LOCATION", fields.location)
  if (fields.start !== undefined || fields.end !== undefined || fields.allDay !== undefined) {
    var allDay = fields.allDay !== undefined ? !!fields.allDay : item.allDay
    var start = fields.start !== undefined ? fields.start : item.start
    var end = fields.end !== undefined ? fields.end : start + (item.end - item.start)
    setTimes(c, start, end, allDay, zone)
  }
  if (fields.reminder !== undefined) setReminder(c, fields.reminder)
  if (isMaster && fields.repeat !== undefined && fields.repeat !== "custom") {
    var startNow = itemOf(c).start
    var rule = repeatRule(fields.repeat, startNow)
    if (rule) Ical.setProp(c, "RRULE", rule)
    else Ical.removeProp(c, "RRULE")
  }
  touch(c, now)
  return true
}

function removeComponent(root, c) {
  var cal = calendarOf(root)
  cal.components = cal.components.filter(function (x) { return x !== c })
}

// A series that no longer repeats has no times of its own left.
function dropOrphans(root, uid) {
  var master = masterOf(root, uid)
  // A time of a series whose event is not in this file is all there is of it.
  if (!master || Ical.prop(master, "RRULE")) return
  componentsOf(root, uid).forEach(function (c) {
    if (Ical.prop(c, "RECURRENCE-ID")) removeComponent(root, c)
  })
  Ical.removeProp(master, "EXDATE")
}

// One time of a series (scope "this"), or the event and every time of it.
function deleteEvent(root, uid, instance, scope, now, zone) {
  var master = masterOf(root, uid)
  var own = overrideOf(root, uid, instance)
  if (scope === "this" && master && Ical.prop(master, "RRULE")) {
    if (own) removeComponent(root, own)
    var item = itemOf(master)
    master.props.push({ name: "EXDATE", params: item.allDay ? { VALUE: "DATE" } : (zone ? { TZID: zone } : {}),
      value: item.allDay ? Ical.formatDate(instance) : Ical.formatLocal(instance) })
    touch(master, now)
    return true
  }
  componentsOf(root, uid).forEach(function (c) { removeComponent(root, c) })
  return true
}

// <fields>: { title, notes, due (or null), dueTime }. Returns its uid.
function addTask(root, fields, now, zone) {
  var c = { name: "VTODO", props: [], components: [] }
  var uid = newUid(now)
  Ical.setProp(c, "UID", uid)
  Ical.setProp(c, "DTSTAMP", Ical.formatUtc(now))
  Ical.setProp(c, "CREATED", Ical.formatUtc(now))
  Ical.setProp(c, "LAST-MODIFIED", Ical.formatUtc(now))
  Ical.setProp(c, "SEQUENCE", "0")
  Ical.setProp(c, "STATUS", "NEEDS-ACTION")
  setText(c, "SUMMARY", fields.title || "New Task")
  setText(c, "DESCRIPTION", fields.notes)
  if (fields.due !== null && fields.due !== undefined) Ical.setTime(c, "DUE", fields.due, !fields.dueTime, zone)
  calendarOf(root).components.push(c)
  return uid
}

function updateTask(root, uid, fields, now, zone) {
  var c = masterOf(root, uid)
  if (!c) return false
  if (fields.title !== undefined) setText(c, "SUMMARY", fields.title || "New Task")
  if (fields.notes !== undefined) setText(c, "DESCRIPTION", fields.notes)
  if (fields.due !== undefined) {
    if (fields.due === null) {
      Ical.removeProp(c, "DUE")
      Ical.removeProp(c, "DTSTART")
    } else {
      Ical.removeProp(c, "DTSTART")
      Ical.setTime(c, "DUE", fields.due, !fields.dueTime, zone)
    }
  }
  if (fields.done !== undefined) {
    if (fields.done) {
      Ical.setProp(c, "STATUS", "COMPLETED")
      Ical.setProp(c, "COMPLETED", Ical.formatUtc(now))
      Ical.setProp(c, "PERCENT-COMPLETE", "100")
    } else {
      Ical.setProp(c, "STATUS", "NEEDS-ACTION")
      Ical.removeProp(c, "COMPLETED")
      Ical.removeProp(c, "PERCENT-COMPLETE")
    }
  }
  touch(c, now)
  return true
}

// A task dragged to another day keeps its time on the clock, if it has one;
// dragged off the calendar, it has no day.
function moveTask(root, uid, day, now, zone) {
  var c = masterOf(root, uid)
  if (!c) return false
  var item = itemOf(c)
  if (day === null) return updateTask(root, uid, { due: null }, now, zone)
  var due = item.dueTime ? atMinutes(day, minutesInDay(item.due)) : dayStart(day)
  return updateTask(root, uid, { due: due, dueTime: item.dueTime }, now, zone)
}

function deleteTask(root, uid) {
  componentsOf(root, uid).forEach(function (c) { removeComponent(root, c) })
  return true
}

function serialize(root) {
  return Ical.serialize(root)
}
