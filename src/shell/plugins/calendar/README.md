# Calendar

Events and tasks: on this computer, in iCloud, Google or any CalDAV account,
kept in step both ways, and from read-only subscriptions. A window with a day,
a week or a month of them, in which everything moves by dragging; the
reminders as notifications; and, under the bar's clock, the days with
anything on them and what a day has.

```
 ▤ Today ‹ ›  Oct – Nov 2026           [Search   ] │Day│Week│Month│ + New
 ON THIS COMPUTER │      MON 26   TUE 27   WED 28   THU 29 ... │ Tasks
 ■ Calendar       │all-day         Day off  Day off            │ [Add a task  ]
 ICLOUD           │                         ☐ Pay rent         │ OVERDUE
 ■ Home           │ 12:00                   ┃Call   ┃          │ ☐ 25 Oct Renew…
 ■ Work           │                         ┃12:00  ┃Lunch     │ NO DAY
 □ Birthdays      │ 13:00                           ┃12:30     │ ☐ Buy milk
 SUBSCRIPTIONS    │ 14:00                                    ┃Dentist
 ■ Holidays       │
 + Add Account    │
```

Open it from the menu (Super+Space → Calendar), from the clock, from a
reminder, or with `nova calendar [day|week|month] [day]`, where the day is
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
- **Clicked**, an item opens in the editor: its title, its calendar, its days
  and times (typed as `2026-10-29` or `29/10/2026`, `9:30`, `930` or
  `9:30 pm`; a new start takes the end with it), how it repeats, its reminder,
  where, and notes. Only what was changed is saved. A new item goes in the
  calendar the last one went in; another calendar picked for an item moves
  it there, every time of it.
- **A repeating event**, moved or changed, asks whether for this time only or
  for every time it repeats. Moved for every time, the series moves as far as
  that time did, by the clock, its weekday with it, and the times moved on
  their own go as far. One whose rule another program set (the 15th of each
  month, until June), or whose times are listed one by one, moves one time at
  a time.
- **The calendars** are listed on the left, once there is more than one (the
  button at the top left shows or hides the list). A click on one shows or
  hides it; the button its row shows under the pointer renames it or gives
  it another of the theme's colours, and ends a subscription. An account's
  button syncs now, or removes the account from this computer.
- **A read-only calendar** (a subscription, or one an account only shares to
  read) shows its items, which open but do not move.
- **Search** finds the items of the shown calendars whose title, place or
  notes have every word typed, each at its next time or its last; Return or a
  click goes to its day and opens it.
- **Keys:** ← and → (or PageUp and PageDown) step a day, a week or a month,
  T is today, D, W and M the day, the week and the month, N a new event,
  / or Ctrl+F the search, Esc clears the search or closes.

The week starts where the bar's clock starts it (a click on the clock's "W"
switches between Monday and Sunday), or else where the locale does.

## Accounts

**Add Account**, at the bottom of the list, asks for:

- **iCloud:** the Apple ID and an app-specific password, which Apple makes at
  account.apple.com (Sign-In and Security → App-Specific Passwords; the
  button beside the field opens it). Apple's CalDAV server does not take the
  Apple ID's own password.
- **Google:** a sign-in in the browser, when this copy of Nova has a Google
  client (below); else the window says it is not set up.
- **CalDAV:** the server's address, a user name and a password. The address
  can be the server's own (`https://dav.example.com`), which is looked up by
  `/.well-known/caldav`, or a calendar's or the user's.
- **Subscription:** an iCal link (`webcal://` or `https://`), read-only.

The calendars found are listed, each to show or not, and kept in the list as
the server adds, renames or removes them. Passwords, Google's tokens and the
subscriptions' links (a private link is a secret too) are kept in the login
keyring, with `secret-tool`; `~/.config/nova/calendars.json` has the rest:
the accounts, the calendars, their names, colours, and whether they are
shown.

**Tasks** sync with a calendar whose server takes them (CalDAV VTODO), and
the editor offers only such calendars for a task. iCloud's Reminders are not
among them: Apple moved them off CalDAV when they were upgraded in iOS 13, so
a task made here stays on this computer, or goes to another account's
calendar that takes tasks. Google's CalDAV has events only.

## Sync

`nova-calendar-sync` keeps each calendar's file in step with its server: at
login, every five minutes, when the network comes back, when the window
opens, and a moment after an edit. An edit made offline waits in the file and
is sent once the server can be reached; under the account's name the list
says it is offline, and how many changes wait, or that it must be signed in
again.

Changed on both sides, an item is merged property by property (a new title on
the phone, a new time here). Where both changed the same property in
different ways, the server's version stays the item, and this computer's is
kept beside it as a copy, sent to the server too: nothing is lost, and every
device shows the same. Deleted on one side and changed on the other, the
change wins. How it finds the server's changes and writes without overwriting
any is at the head of the program (`src/calendar/src/lib.rs`).

A file that is gone, empty, or has lost most of its events at once is taken
to be broken: nothing is deleted on the server, and the file gets them back.
A calendar the server stops listing stays while it has changes not yet sent,
and the list says so. A password goes only to its account's server (for
iCloud, also to the partition of it the calendars are on).

### Google sign-in, for whoever builds Nova

Google lets a program use CalDAV only with an OAuth client of its own, which
cannot ship empty-handed: `src/calendar/google.json` is empty until one is
made. To make one:

1. In the Google Cloud console, make a project and enable the CalDAV API.
2. In Google Auth Platform, set up the consent screen: External, with the
   scope `https://www.googleapis.com/auth/calendar`.
3. Make an OAuth client of the type Desktop app, and put its client ID and
   secret in `src/calendar/google.json` (`{"client_id": "…",
   "client_secret": "…"}`). For a desktop app Google does not count the
   secret as one.
4. Publish the app (In production). An app left in Testing signs in only its
   test users, and their sign-in ends after seven days. Until Google has
   verified it, people signing in see that it is unverified, and at most 100
   can; verification asks for a home page, a privacy policy and a video of
   the sign-in.

A person can use a client of their own instead, in
`~/.config/nova/calendar-google.json`, which is read first.

## Reminders

An event's reminder comes as a notification as long before it as it says (ten
minutes, for a new event); an all-day event's at nine on the day, or the day
before; a task's at the time it is due, if it has one and is still to do.
The notification opens the calendar on its day. A subscription's alarms are
its publisher's, and are not said.

The service looks at the clock every minute at most, rather than sleeping
until the next reminder, so a suspend does not make it late. How far it has
looked is kept in `~/.local/state/nova/calendar.json`, a quarter of an hour
behind at most: after a shutdown or a suspend, the reminders due since then
are said if their event has not ended yet, or their task is still to do
today, and the rest are let go.

## The files

Each calendar is one iCalendar (RFC 5545) file in
`~/.local/share/nova/calendar/`: the one on this computer is `calendar.ics`,
synced with nothing, and an account's or a subscription's is named by its id
in `calendars.json`. A file is written whole after each change and read again
when another program changes it. `~/.local/state/nova/calendar-sync/` has
what the servers last had, and how each account's last sync went.

What the calendar does not know is kept as it was: other programs'
properties, attendees, and an item's alarms, until its reminder is changed
here, which then is its only one. It reads repeats by the day, week, month
and year, with an interval, a count or an end, weekdays (the second Tuesday,
the last Friday), days of the month, times added (RDATE), taken out and moved
on their own, and cancelled times; a rule beyond that shows only its first
time, and the editor leaves it as it is until another is picked.

Times are read in the zone their file defines for them (VTIMEZONE), so a
weekly 10:00 in Rome stays 10:00 in Rome across both places' clock changes;
times in UTC as UTC; and floating times, and zones the file does not define,
on this computer's clock. A file the sync writes defines every zone its items
name, from the server or from this computer's zone database. New events are
written in this computer's zone.

## The parts

| File | What it is |
|---|---|
| `Ical.js` | The file format: lines folded and unfolded, text escaped, times, durations, time zones |
| `Model.js` | Items from a file, their repeats, a day's layout, reminders, search, and every edit |
| `Store.qml` | One calendar's file, read and written |
| `Calendars.qml` | Every calendar: the list, the files, and `nova-calendar-sync` run when it should |
| `Service.qml` | The calendars for the window and the clock, and the reminders |
| `Panel.qml` | The window, and the drag between its parts |
| `CalendarList.qml` | The calendars on the left |
| `WeekView.qml`, `EventBox.qml` | The day's or the week's hours, and an event in them |
| `MonthView.qml` | The month |
| `TaskList.qml` | The tasks beside the calendar |
| `SearchResults.qml` | What the search finds |
| `Chip.qml` | A line of an item: an all-day event, a task, an event in the month |
| `Editor.qml`, `NotesField.qml`, `Sheet.qml` | The editor, and the cards over the window |
| `AccountSheet.qml`, `CalendarSheet.qml` | An account added or managed; a calendar's name and colour |

`tests/qml/calendar-test.qml` checks the file, the repeats, the layout, the
reminders and the edits; `calendar-zones-test.qml` times in other zones, with
files as Google and iCloud write them; `calendar-window-test.qml` drags
things about in the window; `calendar-accounts-test.qml` the calendars side
by side, read-only ones, moving between them, search, the day, and adding and
removing an account. `cargo test -p nova-calendar` runs the sync (`src/calendar/tests/`) against a
CalDAV server of its own on 127.0.0.1 (and against Radicale, with
`NOVA_TEST_RADICALE=1` and `radicale` on the PATH).
