import QtQuick
import Quickshell
import "plugins/calendar/Ical.js" as Ical
import "plugins/calendar/Model.js" as Model

// The calendar's file, its repeats, its layout, its reminders and its edits.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function local(y, m, d, h, min) {
    return new Date(y, m - 1, d, h || 0, min || 0).getTime()
  }

  function starts(occs) {
    return occs.map(function (o) { return Model.dayKey(o.start) + (o.item.allDay ? "" : " " + Model.pad2(new Date(o.start).getHours()) + ":" + Model.pad2(new Date(o.start).getMinutes())) }).join(", ")
  }

  function file(body) {
    return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\n" + body + "END:VCALENDAR\r\n"
  }

  function event(uid, lines) {
    return "BEGIN:VEVENT\r\nUID:" + uid + "\r\n" + lines.join("\r\n") + "\r\nEND:VEVENT\r\n"
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    // ---- the file
    var long = "SUMMARY:" + "Réunion très importante, ".repeat(6)
    var text = file(event("a@x", ["DTSTART:20261029T090000", "X-ODD;X-P=\"a:b\":kept", "ATTENDEE;CN=Ann;ROLE=CHAIR:mailto:ann@example.org", long]))
    var root = Ical.parse(text)
    var again = Ical.serialize(root)
    check(Ical.serialize(Ical.parse(again)) === again, "written, read and written again, the file is the same")
    check(again.indexOf("X-ODD;X-P=\"a:b\":kept") >= 0 && again.indexOf("ATTENDEE;CN=Ann;ROLE=CHAIR:mailto:ann@example.org") >= 0, "what the calendar does not know is kept as it was")
    check(again.split("\r\n").every(function (l) { return encodeURIComponent(l).replace(/%[0-9A-F]{2}/g, "x").length <= 75 }), "lines are folded at 75 bytes")
    check(Model.items(Ical.parse(again))[0].title === long.slice(8), "a folded line reads back whole, accents and all")
    check(Ical.unescapeText(Ical.escapeText("a, b; c\\d\nnext")) === "a, b; c\\d\nnext" && Ical.escapeText("a,b") === "a\\,b", "text is escaped and unescaped")
    var utc = Ical.parseTime({ value: "20261029T080000Z", params: {} })
    var day = Ical.parseTime({ value: "20261029", params: { VALUE: "DATE" } })
    var zoned = Ical.parseTime({ value: "20261029T090000", params: { TZID: "Europe/Rome" } })
    check(utc.time === Date.UTC(2026, 9, 29, 8) && day.allDay && day.time === local(2026, 10, 29) && zoned.time === local(2026, 10, 29, 9), "UTC, a day and a zoned time")
    check(Ical.parseDuration("-PT10M") === -600000 && Ical.parseDuration("P1DT2H") === 93600000 && Ical.parseDuration("P1W") === 604800000 && Ical.parseDuration("PT") === null, "durations")
    check(Ical.formatDuration(-600000) === "-PT10M" && Ical.formatDuration(32400000) === "PT9H" && Ical.formatDuration(0) === "PT0S", "durations written")
    check(Model.items(Model.parse("")).length === 0 && Model.items(Model.parse("not a calendar")).length === 0, "an empty or broken file has no items")

    // ---- items
    var list = Model.items(Ical.parse(file(
      event("t", ["DTSTART;TZID=Europe/Rome:20261029T090000", "DTEND;TZID=Europe/Rome:20261029T103000", "SUMMARY:Standup", "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM"]) +
      event("d", ["DTSTART;VALUE=DATE:20261030", "SUMMARY:Holiday"]) +
      event("p", ["DTSTART:20261029T120000", "DURATION:PT45M"]) +
      "BEGIN:VTODO\r\nUID:k\r\nSUMMARY:Pay rent\r\nDUE;VALUE=DATE:20261031\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\n" +
      "BEGIN:VTODO\r\nUID:u\r\nSUMMARY:Someday\r\nCOMPLETED:20261001T000000Z\r\nEND:VTODO\r\n")))
    var byUid = {}
    list.forEach(function (i) { byUid[i.uid] = i })
    check(byUid.t.start === local(2026, 10, 29, 9) && byUid.t.end === local(2026, 10, 29, 10, 30) && byUid.t.reminder === -900000, "a timed event, its end and its reminder")
    check(byUid.d.allDay && byUid.d.end === local(2026, 10, 31), "an all-day event with no end lasts its day")
    check(byUid.p.end - byUid.p.start === 45 * 60000, "an end given as a duration")
    check(byUid.k.kind === "task" && byUid.k.due === local(2026, 10, 31) && !byUid.k.dueTime && !byUid.k.done, "a task with a day")
    check(byUid.u.due === null && byUid.u.done, "a task with no day, done")

    // ---- repeating
    function series(lines, from, to) {
      return starts(Model.occurrences(Model.items(Ical.parse(file(event("s", lines)))), from, to))
    }
    check(series(["DTSTART:20261026T090000", "DTEND:20261026T100000", "RRULE:FREQ=WEEKLY;BYDAY=MO,WE"], local(2026, 10, 26), local(2026, 11, 9)) ===
      "2026-10-26 09:00, 2026-10-28 09:00, 2026-11-02 09:00, 2026-11-04 09:00", "every Monday and Wednesday, at the same time on the clock")
    check(series(["DTSTART:20261026T090000", "RRULE:FREQ=DAILY;COUNT=3"], local(2026, 10, 1), local(2026, 12, 1)) === "2026-10-26 09:00, 2026-10-27 09:00, 2026-10-28 09:00", "a count")
    check(series(["DTSTART:20261026T090000", "RRULE:FREQ=DAILY;UNTIL=20261028T090000"], local(2026, 10, 1), local(2026, 12, 1)) === "2026-10-26 09:00, 2026-10-27 09:00, 2026-10-28 09:00", "an end date, the last time included")
    check(series(["DTSTART:20261026T090000", "RRULE:FREQ=DAILY;COUNT=3", "EXDATE:20261027T090000"], local(2026, 10, 1), local(2026, 12, 1)) === "2026-10-26 09:00, 2026-10-28 09:00", "a time taken out still counts")
    check(series(["DTSTART;VALUE=DATE:20260131", "RRULE:FREQ=MONTHLY"], local(2026, 1, 1), local(2026, 6, 1)) === "2026-01-31, 2026-03-31, 2026-05-31", "the 31st, in the months that have one")
    check(series(["DTSTART;VALUE=DATE:20280229", "RRULE:FREQ=YEARLY"], local(2028, 1, 1), local(2033, 1, 1)) === "2028-02-29, 2032-02-29", "the 29th of February, in leap years")
    check(series(["DTSTART:20261013T180000", "RRULE:FREQ=MONTHLY;BYDAY=2TU"], local(2026, 10, 1), local(2027, 1, 1)) === "2026-10-13 18:00, 2026-11-10 18:00, 2026-12-08 18:00", "the second Tuesday")
    check(series(["DTSTART:20261030T180000", "RRULE:FREQ=MONTHLY;BYDAY=-1FR"], local(2026, 10, 1), local(2027, 1, 1)) === "2026-10-30 18:00, 2026-11-27 18:00, 2026-12-25 18:00", "the last Friday")
    check(series(["DTSTART:20160104T080000", "RRULE:FREQ=DAILY;INTERVAL=2"], local(2026, 10, 26), local(2026, 10, 30)) !== "" &&
      series(["DTSTART:20160104T080000", "RRULE:FREQ=DAILY;INTERVAL=2"], local(2026, 10, 26), local(2026, 10, 30)).split(", ").length === 2, "a series from ten years ago, every other day")
    check(series(["DTSTART:20261026T090000", "RRULE:FREQ=WEEKLY;BYSETPOS=1;BYDAY=MO"], local(2026, 10, 1), local(2026, 12, 1)) === "2026-10-26 09:00", "a rule it does not follow shows its first time")
    check(series(["DTSTART:20261025T230000", "DTEND:20261026T010000"], local(2026, 10, 26), local(2026, 10, 27)) === "2026-10-25 23:00", "an event over midnight is on the next day too")

    var moved = Model.occurrences(Model.items(Ical.parse(file(
      event("m", ["DTSTART:20261026T090000", "DTEND:20261026T100000", "RRULE:FREQ=DAILY;COUNT=3", "SUMMARY:Daily"]) +
      event("m", ["RECURRENCE-ID:20261027T090000", "DTSTART:20261027T150000", "DTEND:20261027T160000", "SUMMARY:Moved"])))), local(2026, 10, 1), local(2026, 12, 1))
    check(starts(moved) === "2026-10-26 09:00, 2026-10-27 15:00, 2026-10-28 09:00" && moved[1].item.title === "Moved" && moved[1].instance === local(2026, 10, 27, 9),
      "a time moved on its own takes its place in the series")

    // ---- laying out
    var day = local(2026, 10, 29)
    var boxes = Model.dayLayout(Model.occurrences(Model.items(Ical.parse(file(
      event("1", ["DTSTART:20261029T090000", "DTEND:20261029T110000"]) +
      event("2", ["DTSTART:20261029T100000", "DTEND:20261029T103000"]) +
      event("3", ["DTSTART:20261029T120000", "DTEND:20261029T120500"]) +
      event("4", ["DTSTART:20261028T220000", "DTEND:20261029T020000"])))), day, Model.addDays(day, 1)), day)
    var box = {}
    boxes.forEach(function (b) { box[b.occ.uid] = b })
    check(box["1"].columns === 2 && box["2"].columns === 2 && box["1"].column !== box["2"].column, "two events at once, side by side")
    check(box["3"].columns === 1 && box["3"].bottom - box["3"].top === 15, "alone, full width, and at least a quarter of an hour")
    check(box["4"].top === 0 && box["4"].bottom === 120, "one from the day before, cut at midnight")
    check(Model.monthWeeks(2026, 9, 1)[0][0] === local(2026, 9, 28) && Model.monthWeeks(2026, 9, 0)[0][0] === local(2026, 9, 27), "a month's grid starts on the week's first day")
    check(Model.weekOf(local(2026, 11, 1, 15), 1) === local(2026, 10, 26), "the week a day is in")

    // ---- reminders
    var reminded = Model.items(Ical.parse(file(
      event("r", ["DTSTART:20261029T090000", "DTEND:20261029T100000", "SUMMARY:Call", "BEGIN:VALARM", "TRIGGER:-PT10M", "END:VALARM"]) +
      event("a", ["DTSTART;VALUE=DATE:20261030", "SUMMARY:Trip", "BEGIN:VALARM", "TRIGGER:-PT15H", "END:VALARM"]) +
      "BEGIN:VTODO\r\nUID:k\r\nSUMMARY:Pick up\r\nDUE:20261029T170000\r\nEND:VTODO\r\n" +
      "BEGIN:VTODO\r\nUID:x\r\nSUMMARY:Done\r\nDUE:20261029T170000\r\nSTATUS:COMPLETED\r\nEND:VTODO\r\n")))
    var due = Model.alarms(reminded, local(2026, 10, 29), local(2026, 10, 30))
    check(due.map(function (a) { return a.occ.uid + "@" + Model.minutesInDay(a.time) }).join(" ") === "r@530 a@540 k@1020", "an event's ten minutes before, a task's at its time, an all-day one's the day before at 9:00")
    check(Model.alarms(reminded, local(2026, 10, 29, 8, 50), local(2026, 10, 29, 8, 59)).length === 0, "a reminder at the very start of the window was said before it")
    check(Model.stillDue(due[0], local(2026, 10, 29, 9, 30)) && !Model.stillDue(due[0], local(2026, 10, 29, 11)), "after a shutdown, said only while the event is on")

    // ---- choices
    check(Model.repeatPreset(Model.parseRrule("FREQ=WEEKLY;BYDAY=TH"), local(2026, 10, 29)) === "weekly" && Model.repeatPreset(Model.parseRrule("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"), local(2026, 10, 29)) === "weekdays", "a rule as the choice it is")
    check(Model.repeatPreset(Model.parseRrule("FREQ=DAILY;COUNT=5"), 0) === "custom" && Model.repeatPreset(null, 0) === "none", "a rule the window did not make is custom")
    check(Model.reminderOptions(false, -7200000).some(function (o) { return o.label === "120 Minutes Before" }), "a reminder the window did not make is offered as itself")

    check(Model.parseClock("9") === 540 && Model.parseClock("930") === 570 && Model.parseClock("09.30") === 570 && Model.parseClock("21:30") === 1290, "times typed in")
    check(Model.parseClock("9:30 pm") === 1290 && Model.parseClock("12am") === 0 && isNaN(Model.parseClock("25:00")) && isNaN(Model.parseClock("13pm")), "with am and pm, and not past the day")
    check(Model.parseDate("2026-10-29") === local(2026, 10, 29) && Model.parseDate("29/10/2026") === local(2026, 10, 29) && isNaN(Model.parseDate("31/02/2026")), "days typed in, the day first")
    check(Model.formatClock(570) === "09:30", "a time written")

    // ---- editing
    var now = local(2026, 10, 28, 12)
    var edit = Model.parse("")
    var uid = Model.addEvent(edit, { title: "Lunch, then a walk", start: local(2026, 10, 29, 12), end: local(2026, 10, 29, 13), reminder: -600000, repeat: "none" }, now, "Europe/Rome")
    var written = Model.serialize(edit)
    check(written.indexOf("DTSTART;TZID=Europe/Rome:20261029T120000") >= 0 && written.indexOf("SUMMARY:Lunch\\, then a walk") >= 0 && written.indexOf("TRIGGER:-PT10M") >= 0, "a new event, in the system's zone, escaped, with its reminder")
    check(written.indexOf("PRODID:-//Nova//Calendar//EN") >= 0 && /UID:[0-9a-z]+-[0-9a-z]+@nova/.test(written), "a new file is Nova's, a new event has a uid of its own")
    Model.updateEvent(edit, uid, local(2026, 10, 29, 12), { start: local(2026, 10, 30, 14), end: local(2026, 10, 30, 15, 30) }, "all", now, "Europe/Rome")
    var after = Model.items(Model.parse(Model.serialize(edit)))[0]
    check(after.start === local(2026, 10, 30, 14) && after.end === local(2026, 10, 30, 15, 30) && after.title === "Lunch, then a walk", "an event dragged to another day and made longer")

    var weekly = Model.parse("")
    var w = Model.addEvent(weekly, { title: "Gym", start: local(2026, 10, 26, 18), end: local(2026, 10, 26, 19), repeat: "weekly" }, now, "")
    Model.updateEvent(weekly, w, local(2026, 11, 2, 18), { start: local(2026, 11, 2, 20), end: local(2026, 11, 2, 21) }, "this", now, "")
    var occ = Model.occurrences(Model.items(weekly), local(2026, 10, 26), local(2026, 11, 17))
    check(starts(occ) === "2026-10-26 18:00, 2026-11-02 20:00, 2026-11-09 18:00, 2026-11-16 18:00", "one time of a series moved on its own")
    Model.updateEvent(weekly, w, local(2026, 11, 9, 18), { start: local(2026, 11, 10, 19), end: local(2026, 11, 10, 20) }, "all", now, "")
    occ = Model.occurrences(Model.items(weekly), local(2026, 10, 26), local(2026, 11, 18))
    check(starts(occ) === "2026-10-27 19:00, 2026-11-03 21:00, 2026-11-10 19:00, 2026-11-17 19:00", "the whole series moved a day and an hour on, its weekday with it, and the time moved on its own as far")
    Model.deleteEvent(weekly, w, local(2026, 11, 3, 19), "this", now, "")
    occ = Model.occurrences(Model.items(weekly), local(2026, 10, 26), local(2026, 11, 18))
    check(starts(occ) === "2026-10-27 19:00, 2026-11-10 19:00, 2026-11-17 19:00", "one time of a series deleted")
    Model.updateEvent(weekly, w, local(2026, 10, 27, 19), { title: "Run" }, "this", now, "")
    Model.updateEvent(weekly, w, local(2026, 10, 27, 19), { repeat: "none" }, "all", now, "")
    check(Model.items(weekly).length === 1 && Model.serialize(weekly).indexOf("EXDATE") < 0, "a series made to happen once keeps no times of its own")
    Model.deleteEvent(weekly, w, local(2026, 10, 27, 19), "this", now, "")
    check(Model.items(weekly).length === 0, "an event that does not repeat is deleted whole")

    var tasks = Model.parse("")
    var t = Model.addTask(tasks, { title: "Call the bank", due: local(2026, 10, 29, 15), dueTime: true }, now, "")
    Model.moveTask(tasks, t, local(2026, 10, 31), now, "")
    var task = Model.items(tasks)[0]
    check(task.due === local(2026, 10, 31, 15) && task.dueTime, "a task dragged to another day keeps its time")
    Model.updateTask(tasks, t, { done: true }, now, "")
    check(Model.items(tasks)[0].done && Model.serialize(tasks).indexOf("STATUS:COMPLETED") >= 0, "a task ticked off")
    Model.updateTask(tasks, t, { done: false }, now, "")
    Model.moveTask(tasks, t, null, now, "")
    check(!Model.items(tasks)[0].done && Model.items(tasks)[0].due === null && Model.undatedTasks(Model.items(tasks)).length === 1, "untick it, and take its day away")
    Model.deleteTask(tasks, t)
    check(Model.items(tasks).length === 0, "a task deleted")

    console.log("DONE")
    Qt.quit()
  }
}
