import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Calendar: a week or a month of the events and tasks in Nova's calendar
// (Service.qml, Store.qml), with the tasks that have no day beside it.
// Everything moves by dragging: an event to another time or day, a task to
// a day, a time, or off its day into the list. An event's bottom edge says
// when it ends, and a drag over the empty hours makes one.
//
// Summoned by the shell, from the menu, the bar's clock, a reminder or the
// CLI; `date` is the day to show, `page` "week" or "month":
//   nova-shell shell summon nova.calendar '{"date":"2026-10-29","page":"month"}'
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null
  property var service: null

  readonly property string pluginId: "nova.calendar"

  property bool closingFromHost: false
  readonly property var pages: [{ id: "week" }, { id: "month" }]
  property string page: "week"
  // A day in the week or the month on screen.
  property real anchor: Model.dayStart(Date.now())

  readonly property real now: clock.date.getTime()
  readonly property real today: Model.dayStart(now)

  // The service's calendar; on its own (in qml-smoke), one of its own.
  property bool standalone: false
  readonly property var store: service ? service.store : (ownStore.item || null)

  readonly property var labelLocale: Qt.locale("en_US")
  readonly property bool twelveHour: /a/i.test(Qt.locale().timeFormat(Locale.ShortFormat))
  // Where the bar's clock starts its weeks, or else where the locale does.
  readonly property int weekStart: Model.weekStartFrom(clockSetting("weekStartDay"), Qt.locale().firstDayOfWeek)

  readonly property var days: {
    var first = Model.weekOf(anchor, weekStart)
    var out = []
    for (var i = 0; i < 7; i++) out.push(Model.addDays(first, i))
    return out
  }
  readonly property int month: new Date(anchor).getMonth()
  readonly property var monthDays: Model.monthWeeks(new Date(anchor).getFullYear(), month, weekStart)
  readonly property real rangeFrom: page === "month" ? monthDays[0][0] : days[0]
  readonly property real rangeTo: Model.addDays(page === "month" ? monthDays[5][6] : days[6], 1)
  readonly property var occs: window.visible && store ? Model.occurrences(store.items, rangeFrom, rangeTo) : []

  readonly property string title: {
    if (page === "month") return Qt.formatDate(new Date(anchor), "MMMM yyyy")
    var a = new Date(days[0])
    var b = new Date(days[6])
    if (a.getMonth() === b.getMonth()) return Qt.formatDate(a, "MMMM yyyy")
    if (a.getFullYear() === b.getFullYear()) return Qt.formatDate(a, "MMM") + " – " + Qt.formatDate(b, "MMM yyyy")
    return Qt.formatDate(a, "MMM yyyy") + " – " + Qt.formatDate(b, "MMM yyyy")
  }

  // ---- a drag: what is carried, from where, and where the pointer is, in
  //      the window's terms (content)
  readonly property Item content: keys
  property bool dragging: false
  property var dragOcc: null
  property var dragSource: null
  property point dragPoint: Qt.point(0, 0)
  property point dragGrab: Qt.point(0, 0)
  property size dragSize: Qt.size(0, 0)
  property real dragDay: 0
  // For an event from the day before, the minutes it started before this one.
  property int dragBefore: 0
  // Where it was dropped, said by the target while the drop goes on.
  property var dropped: null

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  Loader {
    id: ownStore
    active: root.standalone
    source: "Store.qml"
  }

  // Set by the shell as the window is made; a window it never set one for
  // (qml-smoke) reads the calendar itself.
  Component.onCompleted: Qt.callLater(function () { root.standalone = root.service === null })

  // ---- lifecycle ----------------------------------------------------------

  function open(payloadJson) {
    closingFromHost = false
    var payload = {}
    try {
      payload = JSON.parse(String(payloadJson || "{}")) || {}
    } catch (e) {
      // An unparseable payload asks for nothing.
    }
    if (!service && shell && typeof shell.serviceFor === "function") service = shell.serviceFor(pluginId)
    page = pages.some(function (p) { return p.id === payload.page }) ? payload.page : pages[0].id
    var day = Model.parseDayKey(payload.date)
    anchor = isNaN(day) ? today : day
    editor.opened = false
    scope.opened = false
    if (!window.visible) measureRoom()
    window.visible = true
    Qt.callLater(focusKeys)
  }

  property size room: Qt.size(Style.space(1080), Style.space(720))

  // The room on the focused screen, as Settings takes it.
  function measureRoom() {
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) {
        room = Qt.size(screens[i].width - Style.space(48), screens[i].height - Style.space(80))
        return
      }
    }
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  function focusKeys() {
    keys.forceActiveFocus()
  }

  // ---- reading ------------------------------------------------------------

  function clockSetting(name) {
    var config = shell ? shell.shellConfig : null
    var layout = config && config.bar && config.bar.layout ? config.bar.layout : {}
    for (var section in layout) {
      var list = Array.isArray(layout[section]) ? layout[section] : []
      for (var i = 0; i < list.length; i++)
        if (list[i] && list[i].id === "nova.clock" && list[i][name] !== undefined) return list[i][name]
    }
    return null
  }

  function clock(time) {
    return Qt.formatTime(new Date(time), twelveHour ? "h:mm AP" : "HH:mm")
  }

  function hourLabel(hour) {
    return twelveHour ? (hour % 12 || 12) + (hour < 12 ? " AM" : " PM") : Model.pad2(hour) + ":00"
  }

  // "MON", or "Monday".
  function weekdayName(time, long) {
    var name = labelLocale.dayName(new Date(time).getDay(), long ? Locale.LongFormat : Locale.ShortFormat)
    return long ? name : String(name).toUpperCase()
  }

  // ---- moving about -------------------------------------------------------

  function step(delta) {
    if (page === "month") {
      var d = new Date(anchor)
      anchor = new Date(d.getFullYear(), d.getMonth() + delta, 1).getTime()
    } else {
      anchor = Model.addDays(anchor, 7 * delta)
    }
  }

  function showDay(day, pageWanted) {
    anchor = day
    page = pageWanted
  }

  // ---- dragging -----------------------------------------------------------

  function beginDrag(occ, source, grab, day, before) {
    if (dragging || !store || !store.loaded) return
    dragOcc = occ
    dragSource = source
    dragGrab = grab
    dragSize = Qt.size(source.width, source.height)
    dragDay = day || 0
    dragBefore = before || 0
    dragPoint = source.mapToItem(keys, grab.x, grab.y)
    dragging = true
    proxy.Drag.active = true
  }

  function moveDrag(point) {
    if (dragging) dragPoint = point
  }

  // The target only says where it went; the calendar changes once the drag
  // is over, so the item made again from it is not the one being dragged.
  function endDrag() {
    if (!dragging) return
    dropped = null
    proxy.Drag.drop()
    var where = dropped
    var occ = dragOcc
    var fromDay = dragDay
    finishDrag()
    if (where) applyDrop(occ, fromDay, where)
  }

  function cancelDrag() {
    if (!dragging) return
    proxy.Drag.cancel()
    finishDrag()
  }

  function finishDrag() {
    dragging = false
    dragOcc = null
    dragSource = null
    dropped = null
  }

  // <kind>: "time" at <minutes> on <day>, "allday" or "day" (a month's, which
  // keeps the time), or "undated", the tasks with no day.
  function dropAt(kind, day, minutes) {
    dropped = { kind: kind, day: day, minutes: minutes }
  }

  function applyDrop(o, fromDay, where) {
    var item = o.item
    if (item.kind === "task") {
      if (where.kind === "undated") {
        if (item.due !== null) store.moveTask(item.uid, null)
      } else if (where.kind === "time") {
        store.updateTask(item.uid, { due: Model.atMinutes(where.day, where.minutes), dueTime: true })
      } else if (where.kind === "allday") {
        store.updateTask(item.uid, { due: where.day, dueTime: false })
      } else if (item.due === null || Model.dayStart(item.due) !== where.day) {
        store.moveTask(item.uid, where.day)
      }
      return
    }
    if (where.kind === "undated") return
    var fields
    if (where.kind === "time") {
      var start = Model.atMinutes(where.day, where.minutes)
      fields = item.allDay ? { allDay: false, start: start, end: start + Model.HOUR }
        : { start: start, end: start + (o.end - o.start) }
      if (item.allDay && item.reminder !== null) fields.reminder = Model.DEFAULT_REMINDER
    } else if (where.kind === "allday" && !item.allDay) {
      fields = { allDay: true, start: where.day, end: Model.addDays(where.day, 1) }
      if (item.reminder !== null) fields.reminder = 9 * Model.HOUR
    } else {
      var moved = Model.daysBetween(fromDay || o.start, where.day)
      fields = { start: Model.addDays(o.start, moved), end: Model.addDays(o.end, moved) }
    }
    if (fields.allDay === undefined && fields.start === o.start && fields.end === o.end) return
    changeEvent(o, fields)
  }

  // ---- changing -----------------------------------------------------------

  function openItem(o) {
    editor.edit(o)
  }

  function newEvent(start, end, allDay) {
    editor.create("event", start, end, allDay)
  }

  // The next hour today, in this week or month; nine on the day on screen.
  function newEventNow() {
    var inView = today >= rangeFrom && today < rangeTo
    var start = inView ? Model.atMinutes(today, (new Date(now).getHours() + 1) * 60) : Model.atMinutes(anchor, 9 * 60)
    if (Model.dayStart(start) !== (inView ? today : anchor)) start = Model.atMinutes(inView ? today : anchor, 23 * 60)
    newEvent(start, start + Model.HOUR, false)
  }

  function toggleTask(item) {
    if (store) store.updateTask(item.uid, { done: !item.done })
  }

  function resizeEvent(o, end) {
    changeEvent(o, { end: end })
  }

  function saveItem(o, kind, fields) {
    if (!store) return
    if (o === null) {
      if (kind === "event") store.addEvent(fields)
      else store.addTask(fields)
      return
    }
    if (Object.keys(fields).length === 0) return
    if (kind === "task") store.updateTask(o.uid, fields)
    else changeEvent(o, fields)
  }

  function deleteItem(o) {
    if (!store) return
    if (o.item.kind === "task") store.deleteTask(o.uid)
    else if (o.recurring) askScope(true, function (which) { root.store.deleteEvent(o.uid, o.instance, which) })
    else store.deleteEvent(o.uid, o.instance, "all")
  }

  // One time of a repeating event, or all of them: asked, unless the change
  // is to how it repeats, which is the series'.
  function changeEvent(o, fields) {
    if (!o.recurring || fields.repeat !== undefined) applyChange(o, fields, "all")
    else askScope(false, function (which) { root.applyChange(o, fields, which) })
  }

  function applyChange(o, fields, which) {
    var f = {}
    for (var key in fields) f[key] = fields[key]
    if (which === "all" && (f.start !== undefined || f.end !== undefined)) {
      var start = f.start !== undefined ? f.start : o.start
      var end = f.end !== undefined ? f.end : start + (o.end - o.start)
      // The series moves as far as this time did, from where it put it.
      f.start = o.instance + (start - o.start)
      f.end = f.start + (end - start)
    }
    store.updateEvent(o.uid, o.instance, f, which)
  }

  property var scopeAction: null

  function askScope(deleting, action) {
    scopeAction = action
    scope.deleting = deleting
    scope.opened = true
  }

  function answerScope(which) {
    var action = scopeAction
    scopeAction = null
    scope.opened = false
    focusKeys()
    if (action && which) action(which)
  }

  // ---- window -------------------------------------------------------------

  FloatingWindow {
    id: window
    title: "Calendar"
    color: Commons.Color.background
    implicitWidth: Math.min(Style.space(1080), root.room.width)
    implicitHeight: Math.min(Style.space(720), root.room.height)
    minimumSize: Qt.size(Math.min(Style.space(760), root.room.width), Math.min(Style.space(520), root.room.height))

    onVisibleChanged: {
      if (visible) return
      root.cancelDrag()
      editor.opened = false
      scope.opened = false
      if (!root.closingFromHost && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        var text = event.text.toLowerCase()
        if (event.key === Qt.Key_Escape) {
          if (root.dragging) root.cancelDrag()
          else root.requestClose()
        } else if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
          return
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_PageUp || text === "h") {
          root.step(-1)
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_PageDown || text === "l") {
          root.step(1)
        } else if (text === "t") {
          root.anchor = root.today
        } else if (text === "w") {
          root.page = "week"
        } else if (text === "m") {
          root.page = "month"
        } else if (text === "n") {
          root.newEventNow()
        } else {
          return
        }
        event.accepted = true
      }

      // ---- header -------------------------------------------------------
      Item {
        id: header
        width: parent.width
        height: Style.space(56)

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Button {
            text: "Today"
            bordered: true
            tooltipText: "T"
            onClicked: root.anchor = root.today
          }
          Button {
            iconText: "󰅁"
            tooltipText: root.page === "month" ? "Previous month" : "Previous week"
            onClicked: root.step(-1)
          }
          Button {
            iconText: "󰅂"
            tooltipText: root.page === "month" ? "Next month" : "Next week"
            onClicked: root.step(1)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            leftPadding: Style.space(8)
            text: root.title
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
            textFormat: Text.PlainText
          }
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(10)

          ButtonGroup {
            anchors.verticalCenter: parent.verticalCenter
            options: [{ value: "week", label: "Week" }, { value: "month", label: "Month" }]
            value: root.page
            focusable: false
            onChanged: function (value) { root.page = value }
          }
          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰐕"
            text: "New"
            bordered: true
            tooltipText: "N"
            onClicked: root.newEventNow()
          }
        }
      }

      Rectangle {
        id: headerRule
        anchors.top: header.bottom
        width: parent.width
        height: 1
        color: Qt.alpha(Commons.Color.foreground, 0.08)
      }

      // ---- the week or the month, and the tasks -------------------------
      Loader {
        id: viewLoader
        anchors.top: headerRule.bottom
        anchors.left: parent.left
        anchors.right: tasks.left
        anchors.bottom: parent.bottom
        anchors.rightMargin: 1
        anchors.leftMargin: root.page === "month" ? Style.space(8) : 0
        active: window.visible
        sourceComponent: root.page === "month" ? monthView : weekView
      }

      Component {
        id: weekView
        WeekView { calendar: root }
      }

      Component {
        id: monthView
        MonthView { calendar: root }
      }

      Rectangle {
        anchors.top: headerRule.bottom
        anchors.bottom: parent.bottom
        anchors.right: tasks.left
        width: 1
        color: Qt.alpha(Commons.Color.foreground, 0.08)
      }

      TaskList {
        id: tasks
        anchors.top: headerRule.bottom
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: Style.space(250)
        calendar: root
      }

      // What is being dragged, under the pointer.
      Rectangle {
        id: proxy
        visible: root.dragging
        x: root.dragPoint.x - root.dragGrab.x
        y: root.dragPoint.y - root.dragGrab.y
        width: root.dragSize.width
        height: root.dragSize.height
        z: 30
        radius: Style.cornerRadius > 0 ? Style.space(4) : 0
        color: Qt.alpha(Commons.Color.accent, 0.4)
        border.width: 1
        border.color: Commons.Color.accent
        Drag.keys: ["nova-calendar"]
        Drag.hotSpot: root.dragGrab

        Text {
          x: Style.space(6)
          y: Style.space(3)
          width: parent.width - Style.space(10)
          text: root.dragOcc ? (root.dragOcc.item.title || (root.dragOcc.item.kind === "task" ? "Task" : "Event")) : ""
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }

      Editor {
        id: editor
        calendar: root
        onOpenedChanged: if (!opened && !scope.opened) Qt.callLater(root.focusKeys)
      }

      // This time of a repeating event, or every time?
      Sheet {
        id: scope
        property bool deleting: false
        cardWidth: Style.space(400)
        onCanceled: root.answerScope("")

        Text {
          width: parent.width
          text: scope.deleting ? "Delete a Repeating Event" : "Change a Repeating Event"
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.bold: true
        }
        Text {
          width: parent.width
          text: scope.deleting ? "Delete only this time, or every time it repeats?" : "Change only this time, or every time it repeats?"
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }
        Row {
          anchors.right: parent.right
          spacing: Style.space(8)
          Button {
            text: "Cancel"
            bordered: true
            onClicked: root.answerScope("")
          }
          Button {
            text: "All Events"
            bordered: true
            onClicked: root.answerScope("all")
          }
          Button {
            text: "This Event"
            bordered: true
            selected: true
            onClicked: root.answerScope("this")
          }
        }
      }
    }
  }
}
