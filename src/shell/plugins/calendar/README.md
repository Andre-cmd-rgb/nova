# Calendar

Events and tasks, on this computer. A window with a week or a month of them,
in which everything moves by dragging; the reminders as notifications; and,
under the bar's clock, the days with anything on them and what a day has.

```
 Today  ‹ ›  Oct – Nov 2026                      │ Week │ Month │  + New
       MON 26   TUE 27   WED 28   THU 29   FRI 30 ...  │ Tasks
all-day         Day off  Day off                        │ [Add a task      ]
                         ☐ Pay rent                     │ OVERDUE
 12:00                   ┃Call   ┃                      │ ☐ 25 Oct Renew the passport
                         ┃12:00  ┃Lunch                 │ NO DAY
 13:00                           ┃12:30                 │ ☐ Buy milk
 14:00                                    ┃Dentist      │
```

Open it from the menu (Super+Space → Calendar), from the clock, from a
reminder, or with `nova calendar [week|month] [day]`, where the day is
`2026-10-29` or what `date` reads as one (`tomorrow`, `next friday`).

## Using it

- **An event** is dragged to another time or day; its bottom edge, dragged,
  says when it ends, a quarter of an hour at a time. A drag over the empty
  hours makes a new one as long, and a double click one of an hour; a double
  click on a day in the month, or in the all-day row, an all-day one. One
  dragged into the all-day row becomes an all-day event, and an all-day one
  dragged into the hours an event of an hour.
- **A task** has a day, or none, and a box to tick. It is dragged onto a day,
  into the hours (it is then due at that time, and reminded of), or into the
  list beside the calendar, which takes its day away. The list has the tasks
  with no day, and those left undone from days gone by.
- **Clicked**, an item opens in the editor: its title, its days and times
  (typed as `2026-10-29` or `29/10/2026`, `9:30`, `930` or `9:30 pm`; a new
  start takes the end with it), how it repeats, its reminder, where, and
  notes. Only what was changed is saved.
- **A repeating event**, moved or changed, asks whether for this time only or
  for every time it repeats. Moved for every time, the series moves as far as
  that time did, its weekday with it.
- **Keys:** ← and → (or PageUp and PageDown) step a week or a month, T is
  today, W and M the week and the month, N a new event, Esc closes.

The week starts where the bar's clock starts it (a click on the clock's "W"
switches between Monday and Sunday), or else where the locale does.

## Reminders

An event's reminder comes as a notification as long before it as it says (ten
minutes, for a new event); an all-day event's at nine on the day, or the day
before; a task's at the time it is due, if it has one and is still to do.
The notification opens the calendar on its day.

The service looks at the clock every minute at most, rather than sleeping
until the next reminder, so a suspend does not make it late. What it said
last is kept in `~/.local/state/nova/calendar.json`: after a shutdown or a
suspend, the reminders due since then are said if their event has not ended
yet, or their task is still to do today, and the rest are let go.

## The file

Everything is in `~/.local/share/nova/calendar/calendar.ics`, one iCalendar
(RFC 5545) file, written whole after each change and read again when another
program changes it. It is synced with nothing: a program that syncs a
calendar to a file (vdirsyncer, say) can be pointed at it.

What the calendar does not know is kept as it was: other programs'
properties, attendees, and an item's alarms, until its reminder is changed
here, which then is its only one. It reads repeats by the day,
week, month and year, with an interval, a count or an end, weekdays (the
second Tuesday, the last Friday), days of the month, times taken out and
times moved on their own; a rule beyond that shows only its first time, and
the editor leaves it as it is until another is picked. Times in another time
zone are read as this computer's.

## The parts

| File | What it is |
|---|---|
| `Ical.js` | The file format: lines folded and unfolded, text escaped, times, durations |
| `Model.js` | Items from the file, their repeats, a day's layout, reminders, and every edit |
| `Store.qml` | The file, read and written |
| `Service.qml` | The calendar for the window and the clock, and the reminders |
| `Panel.qml` | The window, and the drag between its parts |
| `WeekView.qml`, `EventBox.qml` | The week's days and hours, and an event in them |
| `MonthView.qml` | The month |
| `TaskList.qml` | The tasks beside the calendar |
| `Chip.qml` | A line of an item: an all-day event, a task, an event in the month |
| `Editor.qml`, `NotesField.qml`, `Sheet.qml` | The editor, and the cards over the window |

`tests/qml/calendar-test.qml` checks the file, the repeats, the layout, the
reminders and the edits; `tests/qml/calendar-window-test.qml` drags things
about in the window.
