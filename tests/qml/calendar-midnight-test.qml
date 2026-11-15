import QtQuick
import Quickshell
import "plugins/calendar/Ical.js" as Ical
import "plugins/calendar/Model.js" as Model

// zone: America/Santiago
// The calendar's days where the clocks skip a midnight: Santiago goes from
// 23:59 on Saturday 5 September 2026 to 01:00 on Sunday the 6th. The 6th is
// a day of its own all the same, from 01:00, with its events on it.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function clock(time) {
    var t = new Date(time)
    return Model.dayKey(time) + " " + Model.pad2(t.getHours()) + ":" + Model.pad2(t.getMinutes())
  }

  function starts(lines, from, to) {
    var text = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\nBEGIN:VEVENT\r\nUID:s\r\n" + lines.join("\r\n") + "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    return Model.occurrences(Model.items(Ical.parse(text)), Model.parseDayKey(from), Model.parseDayKey(to)).map(function (o) { return clock(o.start) }).join(", ")
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    var saturday = Model.parseDayKey("2026-09-05")
    var sunday = Model.parseDayKey("2026-09-06")
    check(new Date(2026, 8, 6, 12).getTimezoneOffset() === 180 && new Date(2026, 8, 5, 12).getTimezoneOffset() === 240, "the zone changes its clocks on the night of 5 September")
    check(clock(sunday) === "2026-09-06 01:00" && Model.dayStart(sunday) === sunday, "the 6th starts at 01:00, on itself")
    check(Model.addDays(saturday, 1) === sunday && clock(Model.addDays(sunday, 1)) === "2026-09-07 00:00", "a day on from the 5th is the 6th, and from the 6th the 7th's midnight")
    check(Model.weekOf(Model.parseDayKey("2026-09-09"), 0) === sunday && Model.daysBetween(saturday, sunday) === 1, "a week starting on Sunday starts on the 6th")
    var grid = []
    Model.monthWeeks(2026, 8, 0).forEach(function (week) { week.forEach(function (day) { grid.push(Model.dayKey(day)) }) })
    check(grid.length === 42 && grid.filter(function (k, i) { return grid.indexOf(k) === i }).length === 42 && grid.indexOf("2026-09-06") === 7, "September's grid has each of its 42 days once")
    check(clock(Model.atMinutes(sunday, 0)) === "2026-09-06 01:00" && clock(Model.atMinutes(sunday, 9 * 60)) === "2026-09-06 09:00", "the 6th's times are on the 6th")
    check(Model.parseDate("06/09/2026") === sunday && Model.parseDate("2026-09-06") === sunday, "the 6th can be typed")
    check(Ical.parseTime({ value: "20260906", params: { VALUE: "DATE" } }).time === sunday, "an all-day date of the 6th is the 6th")
    check(clock(Ical.parseTime({ value: "20260906T003000", params: {} }).time) === "2026-09-06 01:30", "a time the clocks skip reads with the offset before them, as RFC 5545 has it")
    check(starts(["DTSTART:20260904T100000", "DTEND:20260904T110000", "RRULE:FREQ=DAILY;COUNT=5"], "2026-09-04", "2026-09-10") === "2026-09-04 10:00, 2026-09-05 10:00, 2026-09-06 10:00, 2026-09-07 10:00, 2026-09-08 10:00", "a daily series falls once on each day, the 6th too")
    check(starts(["DTSTART:20260802T090000", "DTEND:20260802T100000", "RRULE:FREQ=MONTHLY;BYDAY=1SU;COUNT=2"], "2026-08-01", "2026-10-01") === "2026-08-02 09:00, 2026-09-06 09:00", "the first Sunday of September is the 6th")
    check(starts(["DTSTART;VALUE=DATE:20260906", "DTEND;VALUE=DATE:20260907"], "2026-09-05", "2026-09-08") === "2026-09-06 01:00", "an all-day event on the 6th is on the 6th")
    console.log("DONE")
    Qt.quit()
  }
}
