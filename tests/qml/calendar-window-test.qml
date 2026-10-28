import QtQuick
import Quickshell
import "plugins/calendar" as Calendar
import "plugins/calendar/Model.js" as Model

// The calendar's window, dragged about: an event to another day and time,
// one time of a repeating event on its own, a task onto a day and off it
// again, an event to another day of the month; and the editor.
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function local(y, m, d, h, min) {
    return new Date(y, m - 1, d, h || 0, min || 0).getTime()
  }

  Calendar.Panel { id: cal }

  function window() {
    for (var i = 0; i < cal.data.length; i++)
      if (cal.data[i] && cal.data[i].contentItem !== undefined) return cal.data[i]
    return null
  }

  // The first item in the window that <ok> says is the one.
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

  function byUid(uid) {
    return cal.store.items.filter(function (i) { return i.uid === uid })[0]
  }

  // Carries <source> from where it is taken to <target>'s <x>, <y>.
  function drag(source, target, x, y) {
    cal.beginDrag(source.occ, source, Qt.point(4, 4), source.day, 0)
    cal.moveDrag(target.mapToItem(cal.content, x + 4, y + 4))
    cal.endDrag()
  }

  property var steps: []
  property var meet: ""
  property var gym: ""
  property var task: ""

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
      step()
      next.restart()
    }
  }

  Timer {
    id: wait
    interval: 50
    repeat: true
    running: true
    onTriggered: {
      if (!cal.store || !cal.store.loaded) return
      stop()
      next.start()
    }
  }

  Component.onCompleted: {
    cal.open(JSON.stringify({ date: "2026-10-28" }))
    steps = [
      function () {
        check(cal.page === "week" && cal.days[0] === local(2026, 10, 26) && cal.title === "Oct – Nov 2026", "opened on the week asked for")
        meet = cal.store.addEvent({ title: "Meet", start: local(2026, 10, 28, 10), end: local(2026, 10, 28, 11), repeat: "none", reminder: null })
        gym = cal.store.addEvent({ title: "Gym", start: local(2026, 10, 27, 18), end: local(2026, 10, 27, 19), repeat: "weekly", reminder: null })
        task = cal.store.addTask({ title: "Pay", due: null })
      },
      function () {
        var grid = find(function (i) { return i.contentY !== undefined && i.contentHeight > 1000 })
        grid.contentY = grid.contentHeight * 10 / 24
      },
      function () {
        var box = find(function (i) { return i.stretch !== undefined && i.occ.uid === test.meet })
        var thursday = find(function (i) { return i.pickFrom !== undefined && i.index === 3 })
        var view = find(function (i) { return i.dropColumn !== undefined })
        cal.beginDrag(box.occ, box, Qt.point(4, 4), box.day, 0)
        cal.moveDrag(thursday.mapToItem(cal.content, 4 + 4, 14 * view.hourHeight + 4))
        check(view.dropColumn === 3 && view.dropMinutes === 14 * 60, "over Thursday at two, it shows it would go there")
        cal.endDrag()
        var item = byUid(test.meet)
        check(item.start === local(2026, 10, 29, 14) && item.end === local(2026, 10, 29, 15), "an event dragged to Thursday at two, as long as it was")
        check(!cal.dragging && cal.dragOcc === null, "and the drag is over")
      },
      function () {
        var box = find(function (i) { return i.stretch !== undefined && i.occ.uid === test.meet })
        cal.resizeEvent(box.occ, local(2026, 10, 29, 16, 30))
        check(byUid(test.meet).end === local(2026, 10, 29, 16, 30), "made longer by its end")
      },
      function () {
        var box = find(function (i) { return i.stretch !== undefined && i.occ.uid === test.gym })
        var wednesday = find(function (i) { return i.pickFrom !== undefined && i.index === 2 })
        var view = find(function (i) { return i.dropColumn !== undefined })
        drag(box, wednesday, 0, 19 * view.hourHeight)
        check(cal.scopeAction !== null && !cal.dragging, "a repeating event asks which times it is for")
        cal.answerScope("this")
        var times = Model.occurrences(cal.store.items, local(2026, 10, 26), local(2026, 11, 9)).filter(function (o) { return o.uid === test.gym })
          .map(function (o) { return o.start })
        check(times.length === 2 && times[0] === local(2026, 10, 28, 19) && times[1] === local(2026, 11, 3, 18), "this time on its own went to Wednesday at seven, the next stays on Tuesday")
      },
      function () {
        var chip = find(function (i) { return i.lead !== undefined && i.occ.uid === test.task })
        var friday = find(function (i) { return i.list !== undefined && i.keys !== undefined && i.modelData === local(2026, 10, 30) })
        drag(chip, friday, 10, 10)
        var t = byUid(test.task)
        check(t.due === local(2026, 10, 30) && !t.dueTime, "a task with no day dragged onto Friday")
      },
      function () {
        var chip = find(function (i) { return i.lead !== undefined && i.occ.uid === test.task && i.day === local(2026, 10, 30) })
        var list = find(function (i) { return i.overdue !== undefined })
        drag(chip, list, 40, list.height - 40)
        check(byUid(test.task).due === null, "and dragged back off it into the tasks")
      },
      function () {
        cal.page = "month"
      },
      function () {
        var chip = find(function (i) { return i.lead !== undefined && i.occ.uid === test.meet })
        var saturday = find(function (i) { return i.shown !== undefined && i.day === local(2026, 10, 31) })
        drag(chip, saturday, 30, 60)
        var item = byUid(test.meet)
        check(item.start === local(2026, 10, 31, 14) && item.end === local(2026, 10, 31, 16, 30), "in the month, dragged to Saturday, at the time it had")
      },
      function () {
        cal.newEvent(local(2026, 11, 2, 9), local(2026, 11, 2, 10, 30), false)
        var editor = find(function (i) { return i.keptStart !== undefined })
        var title = find(function (i) { return i.placeholderText === "Title" })
        title.text = "Written"
        editor.save()
        var item = cal.store.items.filter(function (i) { return i.title === "Written" })[0]
        check(item && item.start === local(2026, 11, 2, 9) && item.end === local(2026, 11, 2, 10, 30) && item.reminder === Model.DEFAULT_REMINDER, "a new event, as the editor had it")
        cal.openItem(Model.occurrences([item], local(2026, 11, 2), local(2026, 11, 3))[0])
        var day = find(function (i) { return i.placeholderText === "YYYY-MM-DD" && i.visible })
        day.text = "4/11/2026"
        editor.keepLength()
        editor.save()
        var moved = cal.store.items.filter(function (i) { return i.title === "Written" })[0]
        check(moved.start === local(2026, 11, 4, 9) && moved.end === local(2026, 11, 4, 10, 30), "a new day typed in takes the end with it")
        cal.openItem(Model.occurrences([moved], local(2026, 11, 4), local(2026, 11, 5))[0])
        var end = find(function (i) { return i.placeholderText === "10:00" })
        end.text = "8:00"
        editor.save()
        check(editor.opened && editor.error === "It ends before it starts.", "an end before the start is not saved")
        editor.opened = false
      }
    ]
  }
}
