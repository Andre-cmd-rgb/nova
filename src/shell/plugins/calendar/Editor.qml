import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// An event or a task, new or as it is. Days are typed as 2026-10-29 or
// 29/10/2026, times as 9:30, 930 or 9:30 pm; a new start takes the end with
// it, so the event stays as long. Only what was changed is saved.
Sheet {
  id: editor

  required property var calendar

  // The occurrence opened, or null for a new item.
  property var occ: null
  property string kind: "event"
  property bool allDay: false
  property string repeat: "none"
  property string reminder: "none"
  property bool done: false
  property string error: ""
  // What it opened with, to save only what changed.
  property var original: ({})
  // The start the end was last kept in step with.
  property real keptStart: NaN

  readonly property bool isNew: occ === null
  readonly property bool isEvent: kind === "event"

  cardWidth: Style.space(460)
  onCanceled: opened = false

  function dateText(time) {
    return Qt.formatDate(new Date(time), "yyyy-MM-dd")
  }

  function clockText(time) {
    return editor.calendar.clock(time)
  }

  // A new item, from <start> to <end>.
  function create(kindWanted, start, end, wholeDay) {
    occ = null
    kind = kindWanted
    original = {}
    fill({ title: "", notes: "", location: "", allDay: wholeDay, start: start, end: end, repeat: "none",
      reminder: wholeDay ? null : Model.DEFAULT_REMINDER, due: start, dueTime: !wholeDay, done: false })
  }

  function edit(o) {
    occ = o
    kind = o.item.kind
    var item = o.item
    original = {
      title: item.title, notes: item.notes, location: item.location, allDay: item.allDay, start: o.start, end: o.end,
      repeat: item.kind === "event" ? Model.repeatPreset(item.rrule, item.start) : "none", reminder: item.reminder,
      due: item.due, dueTime: item.dueTime, done: item.done
    }
    fill(original)
  }

  function fill(v) {
    error = ""
    titleField.text = v.title
    notes.text = v.notes
    place.text = v.location
    allDay = v.allDay
    repeat = v.repeat
    reminder = Model.reminderValue(v.reminder)
    done = v.done
    if (kind === "event") {
      startDate.text = dateText(v.start)
      startClock.text = clockText(v.start)
      // An all-day event shows the last day it is on, not the midnight after.
      endDate.text = dateText(v.allDay ? Math.max(v.start, Model.addDays(v.end, -1)) : v.end)
      endClock.text = clockText(v.end)
      keptStart = v.start
    } else {
      dueDate.text = v.due === null ? "" : dateText(v.due)
      dueClock.text = v.due !== null && v.dueTime ? clockText(v.due) : ""
    }
    opened = true
    Qt.callLater(function () {
      titleField.forceActiveFocus()
      titleField.selectAll()
    })
  }

  function startValue() {
    var day = Model.parseDate(startDate.text)
    if (isNaN(day) || allDay) return day
    var minutes = Model.parseClock(startClock.text)
    return isNaN(minutes) ? NaN : Model.atMinutes(day, minutes)
  }

  function endValue() {
    var day = Model.parseDate(endDate.text)
    if (isNaN(day)) return NaN
    if (allDay) return Model.addDays(day, 1)
    var minutes = Model.parseClock(endClock.text)
    return isNaN(minutes) ? NaN : Model.atMinutes(day, minutes)
  }

  // The start moved: the end goes as far.
  function keepLength() {
    var start = startValue()
    var end = endValue()
    if (isNaN(start) || isNaN(keptStart) || isNaN(end)) {
      if (!isNaN(start)) keptStart = start
      return
    }
    var moved = end + (start - keptStart)
    endDate.text = dateText(allDay ? Model.addDays(moved, -1) : moved)
    if (!allDay) endClock.text = clockText(moved)
    keptStart = start
  }

  function setAllDay(on) {
    if (on === allDay) return
    var start = startValue()
    allDay = on
    // A reminder minutes before means nothing to a day, nor the day before
    // at nine to a meeting.
    if (reminder !== "none") reminder = on ? "32400000" : String(Model.DEFAULT_REMINDER)
    if (!on && !isNaN(start)) {
      var at = Model.atMinutes(Model.dayStart(start), 9 * 60)
      startClock.text = clockText(at)
      endDate.text = startDate.text
      endClock.text = clockText(at + Model.HOUR)
    }
    keptStart = startValue()
  }

  // The fields to save, only those changed for an item as it was; or null,
  // with <error> saying what is wrong.
  function values() {
    // A start typed in and saved straight away, never left, takes the end
    // with it too.
    if (isEvent && startValue() !== keptStart) keepLength()
    var v = { title: titleField.text.trim(), notes: notes.text, location: place.text }
    if (isEvent) {
      v.allDay = allDay
      v.start = startValue()
      v.end = endValue()
      v.repeat = repeat
      v.reminder = Model.reminderOffset(reminder)
      if (isNaN(v.start)) { error = allDay ? "The first day is not a date." : "The start is not a day and a time."; return null }
      if (isNaN(v.end)) { error = allDay ? "The last day is not a date." : "The end is not a day and a time."; return null }
      if (v.end < v.start || (allDay && v.end <= v.start)) { error = "It ends before it starts."; return null }
    } else {
      var day = dueDate.text.trim() === "" ? null : Model.parseDate(dueDate.text)
      if (day !== null && isNaN(day)) { error = "The day is not a date."; return null }
      var minutes = dueClock.text.trim() === "" ? null : Model.parseClock(dueClock.text)
      if (minutes !== null && isNaN(minutes)) { error = "The time is not a time."; return null }
      if (minutes !== null && day === null) { error = "A time needs a day."; return null }
      v.due = day === null ? null : (minutes === null ? day : Model.atMinutes(day, minutes))
      v.dueTime = minutes !== null
      v.done = done
      delete v.location
    }
    if (isNew) return v
    var changed = {}
    var o = original
    if (v.title !== o.title) changed.title = v.title
    if (v.notes !== o.notes) changed.notes = v.notes
    if (isEvent) {
      if (v.location !== o.location) changed.location = v.location
      if (v.allDay !== o.allDay || v.start !== o.start || v.end !== o.end) {
        changed.allDay = v.allDay
        changed.start = v.start
        changed.end = v.end
      }
      if (v.repeat !== o.repeat) changed.repeat = v.repeat
      if (v.reminder !== o.reminder) changed.reminder = v.reminder
    } else {
      if (v.due !== o.due || v.dueTime !== o.dueTime) {
        changed.due = v.due
        changed.dueTime = v.dueTime
      }
      if (v.done !== o.done) changed.done = v.done
    }
    return changed
  }

  function save() {
    var v = values()
    if (v === null) return
    opened = false
    editor.calendar.saveItem(occ, kind, v)
  }

  Keys.onReturnPressed: function (event) {
    if (notes.activeFocus) { event.accepted = false; return }
    save()
  }
  Keys.onEnterPressed: function (event) {
    if (notes.activeFocus) { event.accepted = false; return }
    save()
  }

  component FieldLabel: Text {
    width: Style.space(80)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    color: Commons.Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  component Weekday: Text {
    property string date: ""
    readonly property real day: Model.parseDate(date)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    text: isNaN(day) ? "" : editor.calendar.weekdayName(day, true)
    color: Commons.Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Item {
    width: parent.width
    height: Math.max(heading.implicitHeight, kindChoice.implicitHeight)

    Text {
      id: heading
      anchors.verticalCenter: parent.verticalCenter
      text: (editor.isNew ? "New " : "") + (editor.isEvent ? "Event" : "Task")
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }
    ButtonGroup {
      id: kindChoice
      visible: editor.isNew
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      options: [{ value: "event", label: "Event" }, { value: "task", label: "Task" }]
      value: editor.kind
      focusable: false
      onChanged: function (value) {
        if (value === editor.kind) return
        var start = editor.isEvent ? editor.startValue() : Model.parseDate(dueDate.text)
        editor.kind = value
        if (value === "task") {
          dueDate.text = isNaN(start) ? "" : editor.dateText(start)
          dueClock.text = isNaN(start) || editor.allDay ? "" : editor.clockText(start)
        } else {
          // At the task's time, or nine on its day; as the event was, if the
          // task kept its day and time.
          var minutes = Model.parseClock(dueClock.text)
          var at = isNaN(start) ? Model.atMinutes(editor.calendar.today, 9 * 60) : Model.atMinutes(start, isNaN(minutes) ? 9 * 60 : minutes)
          var was = editor.startValue()
          if (isNaN(was) || Model.dayStart(was) !== Model.dayStart(at) || (!editor.allDay && was !== at)) {
            startDate.text = endDate.text = editor.dateText(at)
            startClock.text = editor.clockText(at)
            endClock.text = editor.clockText(at + Model.HOUR)
          }
          editor.keptStart = editor.startValue()
        }
      }
    }
  }

  TextField {
    id: titleField
    width: parent.width
    placeholderText: editor.isEvent ? "Title" : "What to do"
  }

  // ---- an event

  Row {
    visible: editor.isEvent
    spacing: Style.space(10)
    height: allDaySwitch.height
    FieldLabel { text: "All day" }
    ToggleSwitch {
      id: allDaySwitch
      anchors.verticalCenter: parent.verticalCenter
      checked: editor.allDay
      onToggled: editor.setAllDay(!editor.allDay)
    }
  }

  Row {
    visible: editor.isEvent
    spacing: Style.space(8)
    FieldLabel { text: editor.allDay ? "From" : "Starts" }
    TextField {
      id: startDate
      width: Style.space(120)
      placeholderText: "YYYY-MM-DD"
      onEditingFinished: editor.keepLength()
    }
    TextField {
      id: startClock
      visible: !editor.allDay
      width: Style.space(90)
      placeholderText: "9:00"
      onEditingFinished: editor.keepLength()
    }
    Weekday { date: startDate.text }
  }

  Row {
    visible: editor.isEvent
    spacing: Style.space(8)
    FieldLabel { text: editor.allDay ? "To" : "Ends" }
    TextField {
      id: endDate
      width: Style.space(120)
      placeholderText: "YYYY-MM-DD"
    }
    TextField {
      id: endClock
      visible: !editor.allDay
      width: Style.space(90)
      placeholderText: "10:00"
    }
    Weekday { date: endDate.text }
  }

  Row {
    visible: editor.isEvent
    spacing: Style.space(8)
    FieldLabel { text: "Repeats" }
    Dropdown {
      width: Style.space(220)
      showLabel: false
      options: editor.repeat === "custom" ? Model.REPEATS.concat([{ value: "custom", label: "As Set Elsewhere" }]) : Model.REPEATS
      value: editor.repeat
      onChanged: function (value) { editor.repeat = value }
    }
  }

  Row {
    visible: editor.isEvent
    spacing: Style.space(8)
    FieldLabel { text: "Reminder" }
    Dropdown {
      width: Style.space(220)
      showLabel: false
      options: Model.reminderOptions(editor.allDay, Model.reminderOffset(editor.reminder))
      value: editor.reminder
      onChanged: function (value) { editor.reminder = value }
    }
  }

  Row {
    visible: editor.isEvent
    spacing: Style.space(8)
    FieldLabel { text: "Where" }
    TextField {
      id: place
      width: Style.space(260)
      placeholderText: "Location"
    }
  }

  // ---- a task

  Row {
    visible: !editor.isEvent
    spacing: Style.space(8)
    FieldLabel { text: "Day" }
    TextField {
      id: dueDate
      width: Style.space(120)
      placeholderText: "None"
    }
    TextField {
      id: dueClock
      width: Style.space(90)
      placeholderText: "Any time"
    }
    Weekday { date: dueDate.text }
  }

  Row {
    visible: !editor.isEvent && !editor.isNew
    spacing: Style.space(10)
    height: doneSwitch.height
    FieldLabel { text: "Done" }
    ToggleSwitch {
      id: doneSwitch
      anchors.verticalCenter: parent.verticalCenter
      checked: editor.done
      onToggled: editor.done = !editor.done
    }
  }

  NotesField {
    id: notes
    width: parent.width
    height: Math.max(Style.space(64), Math.min(Style.space(140), implicitHeight))
    placeholderText: "Notes"
  }

  Text {
    visible: editor.error !== ""
    width: parent.width
    text: editor.error
    color: Commons.Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
  }

  Item {
    width: parent.width
    height: saveButton.implicitHeight

    Button {
      visible: !editor.isNew
      anchors.left: parent.left
      text: "Delete"
      foreground: Commons.Color.urgent
      bordered: true
      onClicked: {
        editor.opened = false
        editor.calendar.deleteItem(editor.occ)
      }
    }
    Row {
      anchors.right: parent.right
      spacing: Style.space(8)
      Button {
        text: "Cancel"
        bordered: true
        onClicked: editor.opened = false
      }
      Button {
        id: saveButton
        text: "Save"
        bordered: true
        selected: true
        onClicked: editor.save()
      }
    }
  }
}
