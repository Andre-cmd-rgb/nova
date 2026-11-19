// stub: bin/nova-calendar-sync nova-calendar-sync
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "plugins/calendar" as Calendar
import "plugins/calendar/Model.js" as Model

// The calendar with an account's calendars and a subscription beside the
// one on this computer: each in its colour, a hidden one left out, the
// subscription's read-only; a new event put in the account's calendar, one
// moved there; hiding, searching, the day; adding an account and removing
// it, through nova-calendar-sync (a stub here).
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function local(y, m, d, h, min) {
    return new Date(y, m - 1, d, h || 0, min || 0).getTime()
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property string folder: home + "/.local/share/nova/calendar"

  function ics(body) {
    return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\n" + body.join("\r\n") + "\r\nEND:VCALENDAR\r\n"
  }

  readonly property var config: ({
    version: 1,
    accounts: [{ id: "acc1", type: "caldav", name: "Work Server", user: "alice", url: "http://127.0.0.1:5232/" }],
    calendars: [
      { id: "local", kind: "local", name: "Calendar", color: "accent", shown: true, file: "calendar.ics", events: true, tasks: true, readOnly: false },
      { id: "aaaa1111", account: "acc1", kind: "caldav", name: "Work", color: "green", shown: true, readOnly: false, events: true, tasks: true, file: "aaaa1111.ics" },
      { id: "bbbb2222", kind: "subscription", name: "Holidays", color: "red", shown: true, readOnly: true, events: true, tasks: false, file: "bbbb2222.ics", host: "example.org" },
      { id: "cccc3333", account: "acc1", kind: "caldav", name: "Hidden", color: "blue", shown: false, readOnly: false, events: true, tasks: false, file: "cccc3333.ics" }
    ]
  })

  // The files, written before the window is made.
  Process {
    running: true
    command: ["sh", "-c", 'mkdir -p "$1/.config/nova" "$1/.local/state/nova/calendar-sync" "$2" && printf "%s" "$3" >"$1/.config/nova/calendars.json" && printf "%s" "$4" >"$1/.local/state/nova/calendar-sync/status.json" && printf "%s" "$5" >"$2/calendar.ics" && printf "%s" "$6" >"$2/aaaa1111.ics" && printf "%s" "$7" >"$2/bbbb2222.ics" && printf "%s" "$8" >"$2/cccc3333.ics"',
      "sh", test.home, test.folder, JSON.stringify(test.config), JSON.stringify({ acc1: { state: "offline", pending: 2, at: 1 } }),
      test.ics(["BEGIN:VEVENT", "UID:lunch@test", "DTSTAMP:20261001T000000Z", "DTSTART:20261028T130000", "DTEND:20261028T140000", "SUMMARY:Lunch", "END:VEVENT"]),
      test.ics(["BEGIN:VEVENT", "UID:standup@test", "DTSTAMP:20261001T000000Z", "DTSTART:20261028T100000", "DTEND:20261028T103000", "SUMMARY:Standup", "END:VEVENT",
        "BEGIN:VTODO", "UID:report@test", "DTSTAMP:20261001T000000Z", "SUMMARY:Report", "END:VTODO"]),
      test.ics(["BEGIN:VEVENT", "UID:holiday@test", "DTSTAMP:20261001T000000Z", "DTSTART;VALUE=DATE:20261028", "DTEND;VALUE=DATE:20261029", "SUMMARY:Holiday",
        "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15H", "END:VALARM", "END:VEVENT",
        "BEGIN:VEVENT", "UID:match@test", "DTSTAMP:20261001T000000Z", "DTSTART:20261029T190000Z", "DTEND:20261029T210000Z", "SUMMARY:Match", "END:VEVENT"]),
      test.ics(["BEGIN:VEVENT", "UID:secret@test", "DTSTAMP:20261001T000000Z", "DTSTART:20261028T110000", "DTEND:20261028T120000", "SUMMARY:Secret", "END:VEVENT"])]
    onExited: panel.active = true
  }

  Loader {
    id: panel
    active: false
    sourceComponent: Calendar.Panel {}
  }
  readonly property var cal: panel.item

  Component {
    id: reader
    FileView { blockLoading: true; printErrors: false }
  }

  // What the file at <path> has now, read by a FileView of its own: one
  // read before gives what it read then.
  function read(path) {
    var view = reader.createObject(test, { path: path })
    var text = view.text()
    view.destroy()
    return text
  }

  FileView { id: answerFile; path: test.home + "/added.json"; blockWrites: true; printErrors: false }
  FileView { id: answerConfig; path: test.home + "/added-config.json"; blockWrites: true; printErrors: false }

  function calls() {
    return read(test.home + "/stub-calls")
  }

  function window() {
    for (var i = 0; i < cal.data.length; i++)
      if (cal.data[i] && cal.data[i].contentItem !== undefined) return cal.data[i]
    return null
  }

  function find(ok) {
    function walk(item) {
      if (!item) return null
      if (ok(item)) return item
      for (var i = 0; i < item.children.length; i++) {
        var found = walk(item.children[i])
        if (found) return found
      }
      return null
    }
    return walk(window().contentItem)
  }

  function byTitle(title) {
    return cal.store.items.filter(function (i) { return i.title === title })[0]
  }

  function occOf(title) {
    return Model.occurrences(cal.store.items, local(2026, 10, 26), local(2026, 11, 2)).filter(function (o) { return o.item.title === title })[0]
  }

  function titles() {
    return cal.store.items.map(function (i) { return i.title }).sort().join(",")
  }

  property var editor: null
  property var sheet: null

  property var steps: []

  Timer {
    id: next
    interval: 60
    onTriggered: {
      if (test.steps.length === 0) {
        console.log("DONE")
        Qt.quit()
        return
      }
      var step = test.steps.shift()
      interval = 60
      step()
      next.start()
    }
  }

  // The next step after <ms>.
  function pause(ms) {
    next.interval = ms
  }

  Timer {
    id: wait
    interval: 50
    repeat: true
    running: true
    property int tries: 0
    onTriggered: {
      if (++tries > 100) {
        console.log("FAIL the calendars were never read: " + (test.cal ? test.titles() : "no window"))
        stop()
        Qt.quit()
        return
      }
      if (!test.cal || !test.cal.store || !test.cal.store.loaded || test.cal.store.items.length < 5) return
      stop()
      test.cal.open(JSON.stringify({ date: "2026-10-28" }))
      test.editor = test.find(function (i) { return i.keptStart !== undefined })
      test.sheet = test.find(function (i) { return i.found !== undefined && i.mode !== undefined })
      next.start()
    }
  }

  Component.onCompleted: {
    steps = [
      function () {
        check(cal.store.list.map(function (c) { return c.id }).join(",") === "local,aaaa1111,bbbb2222,cccc3333", "the calendars are listed, the one on this computer first")
        check(titles() === "Holiday,Lunch,Match,Report,Standup", "the shown calendars' items are there, the hidden one's not")
        check(Qt.colorEqual(cal.colorOf(byTitle("Standup")), Commons.Color.hue("green")) && Qt.colorEqual(cal.colorOf(byTitle("Holiday")), Commons.Color.hue("red")) &&
          !Qt.colorEqual(Commons.Color.hue("green"), Commons.Color.hue("red")), "each in its calendar's colour")
        var holiday = byTitle("Holiday")
        check(holiday.readOnly && holiday.reminder === null && !byTitle("Standup").readOnly, "the subscription's are read-only, and its reminders are not set")
        check(cal.sidebar, "the calendars are shown on the left, there being more than one")
        var side = find(function (i) { return i.groups !== undefined })
        check(side.groups.map(function (g) { return g.heading }).join(",") === "On This Computer,Work Server,Subscriptions", "by where they are: this computer, the account, the subscriptions")
        check(cal.store.stateWords("acc1") === "Offline, 2 changes not sent" && find(function (i) { return i.text === "Offline, 2 changes not sent" }) !== null,
          "an account offline says so, with the changes it has not sent")
      },
      function () {
        var chip = find(function (i) { return i.lead !== undefined && i.occ && i.occ.uid === "holiday@test" })
        cal.beginDrag(chip.occ, chip, Qt.point(4, 4), chip.day, 0)
        check(!cal.dragging, "a read-only event does not move")
        var box = find(function (i) { return i.stretch !== undefined && i.occ.uid === "match@test" })
        var edge = box.children.filter(function (c) { return c.cursorShape === Qt.SizeVerCursor })[0]
        check(edge && !edge.visible, "nor is it made longer by its end")
        check(!cal.store.updateEvent("holiday@test", 0, { title: "Mine" }, "all", "bbbb2222") && byTitle("Holiday") !== undefined, "and the subscription's file takes no edit")
      },
      function () {
        cal.newEvent(local(2026, 10, 29, 9), local(2026, 10, 29, 10), false)
        var choice = find(function (i) { return i.options !== undefined && i.currentLabel !== undefined && i.options.some(function (o) { return o.value === "aaaa1111" }) })
        check(editor.calendarId === "local" && choice.options.map(function (o) { return o.value }).join(",") === "local,aaaa1111,cccc3333",
          "a new event goes on this computer, or in a calendar that can be written")
        choice.changed("aaaa1111")
        find(function (i) { return i.placeholderText === "Title" }).text = "Planning"
        editor.save()
        var item = byTitle("Planning")
        check(item && item.calendar === "aaaa1111" && item.start === local(2026, 10, 29, 9), "saved in the account's calendar")
        check(read(test.folder + "/aaaa1111.ics").indexOf("SUMMARY:Planning") > 0, "and written in its file")
        pause(1700)
      },
      function () {
        check(calls().indexOf("nova-calendar-sync sync") >= 0, "a moment later, it is synced")
        cal.newEvent(local(2026, 10, 30, 9), local(2026, 10, 30, 10), false)
        check(editor.calendarId === "aaaa1111", "the next new event goes where the last one went")
        editor.opened = false
      },
      function () {
        cal.store.setCalendar("cccc3333", "name", "Calendar")
        cal.newEvent(local(2026, 10, 30, 9), local(2026, 10, 30, 10), false)
        check(editor.choices.map(function (o) { return o.label }).join(",") === "Calendar · On This Computer,Work,Calendar · Work Server",
          "two calendars of a name say where each is")
        editor.opened = false
        cal.store.setCalendar("cccc3333", "name", "Hidden")
      },
      function () {
        cal.openItem(occOf("Lunch"))
        var choice = find(function (i) { return i.options !== undefined && i.currentLabel !== undefined && i.options.some(function (o) { return o.value === "aaaa1111" }) })
        choice.changed("aaaa1111")
        editor.save()
        check(byTitle("Lunch").calendar === "aaaa1111", "an event moved to another calendar is in it")
      },
      function () {
        check(read(test.folder + "/calendar.ics").indexOf("Lunch") < 0 && read(test.folder + "/aaaa1111.ics").indexOf("SUMMARY:Lunch") > 0, "it left this computer's file for the account's")
        var report = byTitle("Report")
        cal.toggleTask(report)
        check(byTitle("Report").done && byTitle("Report").calendar === "aaaa1111", "the account's task is ticked in its own calendar")
        cal.openItem(occOf("Holiday"))
        var save = find(function (i) { return i.text === "Save" && i.bordered !== undefined })
        var close = find(function (i) { return i.text === "Close" && i.bordered !== undefined })
        check(editor.opened && editor.readOnly && !save.visible && close.visible && find(function (i) { return i.text === "Holidays" }) !== null,
          "a read-only event opens to be read, with its calendar's name")
        editor.save()
        check(!editor.opened && byTitle("Holiday").title === "Holiday", "and closes unchanged")
      },
      function () {
        cal.store.setCalendar("aaaa1111", "shown", false)
        check(titles() === "Holiday,Match", "a calendar hidden takes its items away")
        pause(300)
      },
      function () {
        check(calls().indexOf("nova-calendar-sync set aaaa1111 shown=false") >= 0, "and the list says it is hidden")
        cal.query = "holi"
        var results = find(function (i) { return i.found !== undefined && i.query !== undefined })
        check(results.visible && results.found.length === 1 && results.found[0].uid === "holiday@test", "the search finds what is shown")
        cal.anchor = local(2026, 12, 1)
        cal.showResult(results.found[0])
        check(cal.query === "" && cal.anchor === local(2026, 10, 28) && editor.opened && editor.occ.uid === "holiday@test", "a result goes to its day, and opens")
        editor.opened = false
      },
      function () {
        cal.page = "day"
        var view = find(function (i) { return i.dropColumn !== undefined })
        check(cal.days.length === 1 && cal.days[0] === local(2026, 10, 28) && cal.title === "Wednesday 28 October 2026" && view.columnWidth === view.width - view.gutter,
          "the day, on its own, across the width")
        cal.step(1)
        check(cal.days[0] === local(2026, 10, 29), "and the next is a day later")
        cal.page = "week"
      },
      function () {
        cal.addAccount()
        sheet.type = "caldav"
        sheet.server.text = "http://127.0.0.1:5232/"
        sheet.user.text = "bob"
        sheet.password.text = "secret"
        sheet.submit()
        pause(600)
      },
      function () {
        check(sheet.error === "The user name or the password is wrong." && sheet.mode === "add", "a sign-in that fails says why, and stays to be tried again")
        var asked = JSON.parse(read(test.home + "/stub-request"))
        check(asked.type === "caldav" && asked.url === "http://127.0.0.1:5232/" && asked.user === "bob" && asked.password === "secret", "what was typed went to nova-calendar-sync")
        var next = JSON.parse(JSON.stringify(test.config))
        next.accounts.push({ id: "acc2", type: "caldav", name: "Team Server", user: "bob", url: "http://127.0.0.1:5232/" })
        next.calendars.push({ id: "dddd4444", account: "acc2", kind: "caldav", name: "Team", color: "orange", shown: true, readOnly: false, events: true, tasks: false, file: "dddd4444.ics" })
        answerConfig.setText(JSON.stringify(next))
        answerFile.setText(JSON.stringify({ account: next.accounts[1], calendars: [next.calendars[4]] }))
        sheet.submit()
        pause(800)
      },
      function () {
        check(sheet.mode === "found" && sheet.account.id === "acc2" && find(function (i) { return i.text === "Team" }) !== null, "then the calendars it found are listed, to show or not")
        check(cal.store.entry("dddd4444") !== null && cal.store.entry("dddd4444").name === "Team", "and are in the calendar list")
        sheet.close()
        cal.manageAccount(cal.store.accounts[0])
        var remove = find(function (i) { return i.text === "Remove Account" })
        remove.clicked()
        remove.clicked()
        check(!sheet.opened && cal.store.entry("aaaa1111") === null && cal.store.entry("cccc3333") === null && cal.store.accounts.length === 1, "an account removed takes its calendars with it")
        pause(300)
      },
      function () {
        check(calls().indexOf("nova-calendar-sync remove acc1") >= 0, "and nova-calendar-sync removes it")
      }
    ]
  }
}
