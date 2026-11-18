// zone: America/Los_Angeles
import QtQuick
import Quickshell
import "plugins/calendar/Ical.js" as Ical
import "plugins/calendar/Model.js" as Model

// Calendars as Google's and iCloud's CalDAV servers write them, read on a
// computer in Los Angeles, whose clocks change on other days than theirs:
// times in a TZID with its VTIMEZONE, in UTC and floating; a weekly series
// with a time taken out, one added, one moved and one cancelled; all-day
// events over several days; reminders, and Apple's alarm that does nothing.
// Then edits to them: a title changed keeps its zone, a time moved or taken
// out is the right one. The fixtures are invented, in the servers' shapes.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function utc(y, m, d, h, min) {
    return Date.UTC(y, m - 1, d, h, min || 0)
  }

  function local(y, m, d, h, min) {
    return new Date(y, m - 1, d, h || 0, min || 0).getTime()
  }

  function lines(list) {
    return list.join("\r\n") + "\r\n"
  }

  function iso(list) {
    return list.map(function (t) { return new Date(t).toISOString().slice(0, 16) }).join(" ")
  }

  readonly property string rome: lines([
    "BEGIN:VTIMEZONE", "TZID:Europe/Rome", "X-LIC-LOCATION:Europe/Rome",
    "BEGIN:DAYLIGHT", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200", "TZNAME:CEST", "DTSTART:19700329T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU", "END:DAYLIGHT",
    "BEGIN:STANDARD", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "TZNAME:CET", "DTSTART:19701025T030000", "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU", "END:STANDARD",
    "END:VTIMEZONE"
  ])

  // As iCloud writes it: the rule since 2007.
  readonly property string newYork: lines([
    "BEGIN:VTIMEZONE", "TZID:America/New_York",
    "BEGIN:DAYLIGHT", "DTSTART:20070311T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", "TZNAME:EDT", "TZOFFSETFROM:-0500", "TZOFFSETTO:-0400", "END:DAYLIGHT",
    "BEGIN:STANDARD", "DTSTART:20071104T020000", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU", "TZNAME:EST", "TZOFFSETFROM:-0400", "TZOFFSETTO:-0500", "END:STANDARD",
    "END:VTIMEZONE"
  ])

  // Google's CalDAV: its header, the zone, a weekly series in Rome until a
  // day in UTC, a time out (EXDATE), one added (RDATE), one moved, one
  // cancelled; a reminder half an hour before, written as Google writes it.
  readonly property string google: "BEGIN:VCALENDAR\r\nPRODID:-//Google Inc//Google Calendar 70.9054//EN\r\nVERSION:2.0\r\nCALSCALE:GREGORIAN\r\n" +
    "X-WR-CALNAME:Team\r\nX-WR-TIMEZONE:Europe/Rome\r\n" + rome + lines([
    "BEGIN:VEVENT", "DTSTART;TZID=Europe/Rome:20261012T100000", "DTEND;TZID=Europe/Rome:20261012T110000",
    "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261130T225959Z", "EXDATE;TZID=Europe/Rome:20261019T100000", "RDATE;TZID=Europe/Rome:20261022T100000",
    "DTSTAMP:20261101T120000Z", "UID:4c1v5mpl8n3k2@google.com", "CREATED:20261001T090000Z", "LAST-MODIFIED:20261001T090000Z",
    "LOCATION:Room 4", "SEQUENCE:0", "STATUS:CONFIRMED", "SUMMARY:Planning", "TRANSP:OPAQUE",
    "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:This is an event reminder", "TRIGGER:-P0DT0H30M0S", "END:VALARM", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTART;TZID=Europe/Rome:20261109T140000", "DTEND;TZID=Europe/Rome:20261109T150000", "DTSTAMP:20261101T120000Z",
    "UID:4c1v5mpl8n3k2@google.com", "RECURRENCE-ID;TZID=Europe/Rome:20261109T100000", "SEQUENCE:1", "STATUS:CONFIRMED", "SUMMARY:Planning (later)", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTART;TZID=Europe/Rome:20261102T100000", "DTEND;TZID=Europe/Rome:20261102T110000", "DTSTAMP:20261101T120000Z",
    "UID:4c1v5mpl8n3k2@google.com", "RECURRENCE-ID;TZID=Europe/Rome:20261102T100000", "STATUS:CANCELLED", "SUMMARY:Planning", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTART;VALUE=DATE:20261030", "DTEND;VALUE=DATE:20261102", "DTSTAMP:20261101T120000Z", "UID:offsite@google.com", "SUMMARY:Offsite", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTART:20261028T170000Z", "DTEND:20261028T173000Z", "RRULE:FREQ=WEEKLY;COUNT=3", "DTSTAMP:20261101T120000Z", "UID:sync@google.com", "SUMMARY:Sync", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTART:20261030T100000Z", "DTSTAMP:20261101T120000Z", "UID:gone@google.com", "STATUS:CANCELLED", "SUMMARY:Called off", "END:VEVENT"
  ]) + "END:VCALENDAR\r\n"

  // iCloud's: a daily series in New York with a reminder and Apple's alarm
  // that does nothing, a floating time, and a time in a zone the file does not
  // define.
  readonly property string icloud: "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Apple Inc.//iOS 18.1//EN\r\nCALSCALE:GREGORIAN\r\n" + newYork + lines([
    "BEGIN:VEVENT", "CREATED:20261020T101010Z", "DTEND;TZID=America/New_York:20261030T100000", "DTSTAMP:20261020T101010Z",
    "DTSTART;TZID=America/New_York:20261030T090000", "LAST-MODIFIED:20261020T101010Z", "RRULE:FREQ=DAILY;COUNT=4", "SEQUENCE:0",
    "SUMMARY:Standup", "UID:6B29FC40-CA47-1067-B31D-00DD010662DA", "X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC",
    "BEGIN:VALARM", "ACTION:NONE", "TRIGGER;VALUE=DATE-TIME:19760401T005545Z", "END:VALARM",
    "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT15M", "UID:9D3A", "X-WR-ALARMUID:9D3A", "END:VALARM", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTART:20261029T090000", "DTEND:20261029T093000", "DTSTAMP:20261020T101010Z", "UID:floating@icloud", "SUMMARY:Floating", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTART;TZID=Asia/Tokyo:20261029T120000", "DTEND;TZID=Asia/Tokyo:20261029T130000", "DTSTAMP:20261020T101010Z", "UID:tokyo@icloud", "SUMMARY:Tokyo", "END:VEVENT",
    "BEGIN:VEVENT", "DTSTART;VALUE=DATE:20261231", "DTSTAMP:20261020T101010Z", "UID:nye@icloud", "SUMMARY:New Year's Eve",
    "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15H", "END:VALARM", "END:VEVENT"
  ]) + "END:VCALENDAR\r\n"

  function starts(occs) {
    return occs.map(function (o) { return o.start }).sort(function (a, b) { return a - b })
  }

  function same(list, want) {
    return list.length === want.length && list.every(function (t, i) { return t === want[i] })
  }

  function titled(occs, title) {
    return occs.filter(function (o) { return o.item.title === title })
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    // ---- zones
    var cal = Ical.parse("BEGIN:VCALENDAR\r\n" + rome + newYork + "END:VCALENDAR\r\n").components[0]
    var zones = Ical.zonesOf(cal)
    var r = zones["Europe/Rome"], ny = zones["America/New_York"]
    check(r && ny, "a VTIMEZONE is a zone, by its TZID")
    check(r.offsetAt(utc(2026, 7, 1, 12)) === 7200000 && r.offsetAt(utc(2026, 12, 1, 12)) === 3600000 && r.offsetAt(utc(2026, 1, 1, 0)) === 3600000, "Rome is two hours ahead in summer, one in winter")
    check(r.offsetAt(utc(2026, 3, 29, 0, 59)) === 3600000 && r.offsetAt(utc(2026, 3, 29, 1, 0)) === 7200000, "its clocks go forward at 01:00 UTC on the last Sunday of March")
    check(r.offsetAt(utc(2026, 10, 25, 0, 59)) === 7200000 && r.offsetAt(utc(2026, 10, 25, 1, 0)) === 3600000, "and back at 01:00 UTC on the last Sunday of October")
    check(ny.offsetAt(utc(2026, 11, 1, 5, 59)) === -14400000 && ny.offsetAt(utc(2026, 11, 1, 6, 0)) === -18000000, "New York's go back on the first Sunday of November")
    check(ny.offsetAt(utc(2026, 3, 8, 6, 59)) === -18000000 && ny.offsetAt(utc(2026, 3, 8, 7, 0)) === -14400000, "and forward on the second Sunday of March")
    check(r.wallToUtc(Date.UTC(2026, 6, 1, 10)) === utc(2026, 7, 1, 8) && r.wallToUtc(Date.UTC(2026, 11, 1, 10)) === utc(2026, 12, 1, 9), "a time on Rome's clock, in UTC")
    check(r.wallToUtc(Date.UTC(2026, 9, 25, 2, 30)) === utc(2026, 10, 25, 0, 30), "a time that is on the clock twice is the first")
    check(r.wallToUtc(Date.UTC(2026, 2, 29, 2, 30)) === utc(2026, 3, 29, 1, 30), "a time the clock skips is read by the offset before the skip")

    var older = Ical.zonesOf(Ical.parse("BEGIN:VCALENDAR\r\n" + lines(["BEGIN:VTIMEZONE", "TZID:Eastern",
      "BEGIN:DAYLIGHT", "DTSTART:19700308T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=8,9,10,11,12,13,14;BYDAY=SU", "TZOFFSETFROM:-0500", "TZOFFSETTO:-0400", "END:DAYLIGHT",
      "BEGIN:STANDARD", "DTSTART:19701101T020000", "RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1,2,3,4,5,6,7;BYDAY=SU", "TZOFFSETFROM:-0400", "TZOFFSETTO:-0500", "END:STANDARD",
      "END:VTIMEZONE"]) + "END:VCALENDAR\r\n").components[0]).Eastern
    check(older.offsetAt(utc(2026, 3, 8, 6, 59)) === -18000000 && older.offsetAt(utc(2026, 3, 8, 7, 0)) === -14400000 && older.offsetAt(utc(2026, 11, 1, 6)) === -18000000,
      "a rule written as a Sunday among the days of the month, as older programs write it")
    var listed = Ical.zonesOf(Ical.parse("BEGIN:VCALENDAR\r\n" + lines(["BEGIN:VTIMEZONE", "TZID:Listed",
      "BEGIN:STANDARD", "TZOFFSETFROM:-0300", "TZOFFSETTO:-0300", "DTSTART:19700101T000000", "END:STANDARD",
      "BEGIN:DAYLIGHT", "TZOFFSETFROM:-0300", "TZOFFSETTO:-0200", "DTSTART:20260328T230000", "RDATE:20270327T230000", "END:DAYLIGHT",
      "BEGIN:STANDARD", "TZOFFSETFROM:-0200", "TZOFFSETTO:-0300", "DTSTART:20261025T000000", "RDATE:20271031T000000", "END:STANDARD",
      "END:VTIMEZONE"]) + "END:VCALENDAR\r\n").components[0]).Listed
    check(listed.offsetAt(utc(2026, 1, 1, 0)) === -10800000 && listed.offsetAt(utc(2026, 7, 1, 0)) === -7200000 && listed.offsetAt(utc(2027, 7, 1, 0)) === -7200000 &&
      listed.offsetAt(utc(2026, 12, 1, 0)) === -10800000 && listed.offsetAt(utc(2040, 7, 1, 0)) === -10800000, "a zone given as the days its clocks change (RDATE)")

    var p = Ical.parseTime({ value: "20261029T090000", params: { TZID: "Europe/Rome" } }, zones)
    var plain = Ical.parseTime({ value: "20261029T090000", params: { TZID: "Europe/Rome" } })
    var unknown = Ical.parseTime({ value: "20261029T090000", params: { TZID: "Nowhere/Known" } }, zones)
    check(p.time === utc(2026, 10, 29, 8) && plain.time === local(2026, 10, 29, 9) && unknown.time === local(2026, 10, 29, 9),
      "a TZID is read on its zone's clock; one the file does not define is this computer's")

    // ---- Google's
    var items = Model.items(Model.parse(google), { id: "g", readOnly: false })
    var from = local(2026, 10, 1), to = local(2026, 12, 1)
    var occs = Model.occurrences(items, from, to)
    var planning = occs.filter(function (o) { return o.item.title.indexOf("Planning") === 0 })
    check(same(starts(planning), [utc(2026, 10, 12, 8), utc(2026, 10, 22, 8), utc(2026, 10, 26, 9), utc(2026, 11, 9, 13), utc(2026, 11, 16, 9), utc(2026, 11, 23, 9), utc(2026, 11, 30, 9)]),
      "a weekly series in Rome stays at 10:00 there across both zones' clock changes, with its time out, its time added, its time moved and its time cancelled (" + iso(starts(planning)) + ")")
    check(planning.every(function (o) { return o.recurring && o.item.calendar === "g" }), "each is a time of a series, in its calendar")
    var later = titled(planning, "Planning (later)")
    check(later.length === 1 && later[0].end === utc(2026, 11, 9, 14) && later[0].instance === utc(2026, 11, 9, 9), "the time moved is at its new time, and knows where the series put it")
    check(planning[0].end - planning[0].start === Model.HOUR && planning[0].item.location === "Room 4", "as long as the series, where it is")
    check(planning[0].item.reminder === -30 * Model.MINUTE, "Google's reminder, -P0DT0H30M0S, is half an hour before")
    var alarms = Model.alarms(items, utc(2026, 10, 12, 7), utc(2026, 10, 12, 8))
    check(alarms.length === 1 && alarms[0].time === utc(2026, 10, 12, 7, 30), "and comes then")
    var syncs = titled(occs, "Sync")
    check(same(starts(syncs), [utc(2026, 10, 28, 17), utc(2026, 11, 4, 17), utc(2026, 11, 11, 17)]), "a series in UTC stays at its UTC time when this computer's clocks change (1 November)")
    check(new Date(syncs[0].start).getHours() === 10 && new Date(syncs[1].start).getHours() === 9, "an hour earlier here after it")
    var offsite = titled(occs, "Offsite")
    var perDay = [local(2026, 10, 29), local(2026, 10, 30), local(2026, 10, 31), local(2026, 11, 1), local(2026, 11, 2)].map(function (d) { return Model.dayItems(offsite, d).length })
    check(offsite.length === 1 && offsite[0].item.allDay && perDay.join() === "0,1,1,1,0", "an all-day event over three days is on those three days, whatever the zones")
    check(titled(occs, "Called off").length === 0, "a cancelled event is not shown")

    // ---- iCloud's
    var apple = Model.items(Model.parse(icloud), { id: "i", readOnly: false })
    var aocc = Model.occurrences(apple, from, to)
    var standup = titled(aocc, "Standup")
    check(same(starts(standup), [utc(2026, 10, 30, 13), utc(2026, 10, 31, 13), utc(2026, 11, 1, 14), utc(2026, 11, 2, 14)]), "a daily series in New York follows New York's clock change (1 November)")
    check(standup[0].item.reminder === -15 * Model.MINUTE, "its reminder is the one that reminds, not Apple's that does nothing")
    var floating = titled(aocc, "Floating")
    check(floating.length === 1 && floating[0].start === local(2026, 10, 29, 9), "a floating time is on this computer's clock")
    var tokyo = titled(aocc, "Tokyo")
    check(tokyo.length === 1 && tokyo[0].start === local(2026, 10, 29, 12), "a zone the file does not define is read as this computer's")
    var nye = titled(Model.occurrences(apple, local(2026, 12, 1), local(2027, 1, 2)), "New Year's Eve")
    check(nye.length === 1 && nye[0].end === local(2027, 1, 1) && nye[0].item.reminder === -15 * Model.HOUR, "an all-day event with no end is one day long, its reminder the day before at nine")

    // ---- edits, in the zones the file has
    var root = Model.parse(google)
    var mine = function () { return Model.items(root, { id: "g" }) }
    var at = function (title, t) { return Model.occurrences(mine(), t, t + Model.DAY).filter(function (o) { return o.item.title === title })[0] }
    var uid = "4c1v5mpl8n3k2@google.com"
    Model.updateEvent(root, uid, utc(2026, 10, 12, 8), { title: "Team planning" }, "all", utc(2026, 11, 1, 0), "America/Los_Angeles")
    var master = Model.masterOf(root, uid)
    check(Ical.prop(master, "DTSTART").params.TZID === "Europe/Rome" && Ical.prop(master, "DTSTART").value === "20261012T100000", "a title changed leaves the time as Google wrote it, in Rome")
    check(same(starts(Model.occurrences(mine(), from, to).filter(function (o) { return o.uid === uid })), starts(planning)), "and every time where it was")
    var nov16 = at("Team planning", utc(2026, 11, 16, 0))
    Model.updateEvent(root, uid, nov16.instance, { start: utc(2026, 11, 16, 12), end: utc(2026, 11, 16, 13) }, "this", utc(2026, 11, 1, 0), "America/Los_Angeles")
    var moved = Model.occurrences(mine(), local(2026, 11, 16), local(2026, 11, 17)).filter(function (o) { return o.uid === uid })
    check(moved.length === 1 && moved[0].start === utc(2026, 11, 16, 12) && moved[0].instance === utc(2026, 11, 16, 9), "one time moved on its own goes where it was dropped, and no copy stays")
    var override = Model.overrideOf(root, uid, utc(2026, 11, 16, 9))
    check(override !== null && Ical.prop(override, "DTSTART").params.TZID === "America/Los_Angeles", "its new time is written in this computer's zone")
    Model.deleteEvent(root, uid, utc(2026, 11, 23, 9), "this", utc(2026, 11, 1, 0), "America/Los_Angeles")
    check(Model.occurrences(mine(), local(2026, 11, 23), local(2026, 11, 24)).filter(function (o) { return o.uid === uid }).length === 0 &&
      Model.occurrences(mine(), local(2026, 11, 30), local(2026, 12, 1)).filter(function (o) { return o.uid === uid }).length === 1, "one time deleted is gone, the next is there")
    var sync = at("Sync", utc(2026, 11, 4, 0))
    Model.updateEvent(root, "sync@google.com", sync.instance, { start: sync.start + Model.HOUR, end: sync.end + Model.HOUR }, "all", utc(2026, 11, 1, 0), "America/Los_Angeles")
    var syncsNow = starts(Model.occurrences(mine(), from, to).filter(function (o) { return o.uid === "sync@google.com" }))
    check(syncsNow.length === 3 && syncsNow.every(function (t) { return new Date(t).getHours() === 10 }),
      "a UTC series, one of its times moved from 9:00 to 10:00 for every time, is at 10:00 here every time: " + iso(syncsNow))
    console.log("DONE")
    Qt.quit()
  }
}
