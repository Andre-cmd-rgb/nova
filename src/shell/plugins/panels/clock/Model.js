.pragma library
// The clock's rules, kept apart from its label and its calendar: the formats
// a right click walks, the ISO week, the share of the year and of a life
// gone, the day weeks start on, and the month's grid. A date here is a year,
// a month counted from 0 as Date counts them, and a day; the names of months
// and days are the panel's, from Qt.

var DAY = 86400000

// As Date.getDay() numbers the days, and Qt's Locale.Sunday to
// Locale.Saturday do: a locale's firstDayOfWeek is one of these numbers.
var WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

// ---------------------------------------------------------------- the label

// The label's formats, which a right click walks and writes to shell.json,
// so that the label shown is the format kept. Each of the time formats is
// followed by its 12-hour twin, one click away; the ISO one has none, since
// ISO 8601 has a 24-hour clock only.
var FORMATS = [
  "dddd HH:mm",
  "dddd h:mm AP",
  "HH:mm",
  "h:mm AP",
  "ddd d MMM HH:mm",
  "ddd d MMM h:mm AP",
  "d MMMM 'W'ww yyyy",
  "yyyy-MM-dd HH:mm"
]

// On a side bar each part of the label is a line of its own, and there is
// room for a few: AM/PM, a fourth line, only on the plain time.
var VERTICAL_FORMATS = [
  "HH\n—\nmm",
  "h\n—\nmm\nAP",
  "dd\nMMM\n'W'ww\n''yy",
  "HH\nmm"
]

function formats(vertical) {
  return vertical ? VERTICAL_FORMATS : FORMATS
}

// The walk: the presets, then the configured alternate and format when they
// are others, each once. Its order does not depend on the format in use, or
// a step written back to shell.json would turn the walk into a swing
// between two.
function formatRing(configured, alternate, presets) {
  var ring = []
  ;(presets || []).concat([alternate, configured]).forEach(function(each) {
    var format = each === undefined || each === null ? "" : String(each)
    if (format !== "" && ring.indexOf(format) === -1) ring.push(format)
  })
  return ring.length > 0 ? ring : ["HH:mm"]
}

// The format after `current`; after one the walk does not have (written by
// hand), its first.
function nextFormat(ring, current) {
  if (!ring || ring.length === 0) return ""
  return ring[(ring.indexOf(current === undefined || current === null ? "" : String(current)) + 1) % ring.length]
}

// Qt has no ISO week in its formats: "ww" is filled in with the date's,
// two digits, before Qt formats the rest.
function withWeek(format, year, month, day) {
  return format.replace(/ww/g, twoDigits(isoWeek(year, month, day)))
}

// ------------------------------------------------------------------ dates

function twoDigits(value) {
  var number = Number(value)
  return (number < 10 ? "0" : "") + number
}

// A day as "yyyy-MM-dd", which a grid cell is compared by.
function dayKey(year, month, day) {
  return year + "-" + twoDigits(Number(month) + 1) + "-" + twoDigits(day)
}

function keyOf(date) {
  return dayKey(date.getFullYear(), date.getMonth(), date.getDate())
}

// The ISO 8601 week: that of the Thursday in the date's week from Monday.
function isoWeek(year, month, day) {
  var thursday = new Date(Date.UTC(year, month, day))
  thursday.setUTCDate(thursday.getUTCDate() + 4 - (thursday.getUTCDay() || 7))
  var januaryFirst = Date.UTC(thursday.getUTCFullYear(), 0, 1)
  return Math.ceil(((thursday.getTime() - januaryFirst) / DAY + 1) / 7)
}

function dayOfYear(year, month, day) {
  return Math.round((Date.UTC(year, month, day) - Date.UTC(year, 0, 1)) / DAY) + 1
}

// The share of the year gone: the days over, out of all of it, so that 1
// January is 0 and 31 December, 1 less a day.
function yearShare(year, month, day) {
  var days = dayOfYear(year, 11, 31)
  if (days <= 0) return 0
  return Math.max(0, Math.min(1, (dayOfYear(year, month, day) - 1) / days))
}

function percent(share) {
  return Math.round(share * 100)
}

// The month `delta` months on, as { year, month }. In UTC: a 1st without a
// local midnight would otherwise read back as the month before.
function stepMonth(year, month, delta) {
  var first = new Date(Date.UTC(year, Number(month) + Number(delta), 1))
  return { year: first.getUTCFullYear(), month: first.getUTCMonth() }
}

// ------------------------------------------------------------ memento mori

// Ninety: a round number to measure by, not a table's. Anyone may set
// their own.
var LIFE_SPAN = 90

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

// The year of birth, which keeps the age right without being told again;
// 0 for none, and for one that is not four digits, in the future, or more
// than 120 years back.
function birthYear(value, thisYear) {
  var now = Math.round(Number(thisYear))
  if (!isFinite(now)) return 0
  var text = trimmed(value)
  if (!/^\d{4}$/.test(text)) return 0
  var year = parseInt(text, 10)
  return year > now || year < now - 120 ? 0 : year
}

// The age as people say it: the years since the year of birth, whatever
// side of the birthday today is.
function age(born, thisYear) {
  var year = birthYear(born, thisYear)
  return year > 0 ? Math.round(Number(thisYear)) - year : 0
}

// The years to measure a life by; 90 for none, or for one that is not a
// whole number from 1 to 150.
function lifeSpan(value) {
  var text = trimmed(value)
  if (!/^\d+$/.test(text)) return LIFE_SPAN
  var years = parseInt(text, 10)
  return years <= 0 || years > 150 ? LIFE_SPAN : years
}

// The share of the span lived; 0 without an age from 1 to 120.
function lifeShare(years, span) {
  var text = trimmed(years)
  var lived = /^\d+$/.test(text) ? parseInt(text, 10) : 0
  if (lived <= 0 || lived > 120) return 0
  return Math.max(0, Math.min(1, lived / lifeSpan(span)))
}

// --------------------------------------------------------------- the week

// A day of the week from a setting: its number (any whole number, taken
// modulo 7), its name or its first three letters; null for none.
function weekday(value) {
  if (value === undefined || value === null) return null
  if (typeof value === "number") return isFinite(value) ? ((Math.round(value) % 7) + 7) % 7 : null
  var text = trimmed(value).toLowerCase()
  if (text === "") return null
  for (var i = 0; i < WEEKDAYS.length; i++)
    if (WEEKDAYS[i] === text || WEEKDAYS[i].substr(0, 3) === text) return i
  var number = parseInt(text, 10)
  return isFinite(number) ? ((number % 7) + 7) % 7 : null
}

// The day weeks start on: the setting's, else `otherwise` (the locale's),
// else Monday.
function weekStart(value, otherwise) {
  var set = weekday(value)
  if (set !== null) return set
  var fallback = weekday(otherwise)
  return fallback === null ? 1 : fallback
}

// The setting's word for a start.
function weekStartName(start) {
  return WEEKDAYS[weekStart(start, 1)]
}

// The W heading switches between the two starts people switch between:
// Monday, and Sunday. Any other goes to Monday.
function otherWeekStart(start) {
  return weekStart(start, 1) === 1 ? 0 : 1
}

// The days of a week from its start, as numbers.
function weekdayOrder(start) {
  var first = weekStart(start, 1)
  var days = []
  for (var i = 0; i < 7; i++) days.push((first + i) % 7)
  return days
}

// --------------------------------------------------------------- the grid

// A month as six weeks of seven days, whatever the month, so that the panel
// is as tall in February as in August: [{ week, days: [{ key, year, month,
// day, weekday, inMonth, weekend, today }] }], each week numbered by the
// ISO week of its Thursday (which is the ISO week for a week from Monday,
// and for another start the ISO week it shares Monday to Thursday with).
//
// Counted in UTC, where every day is 24 hours. Where summer time starts at
// midnight (Chile in September, Cuba in March) that midnight does not
// exist, and the shell's engine takes it back to the day before where
// node's takes it on: a local count would show a day twice in the shell.
function monthGrid(year, month, start, todayKey) {
  var first = weekStart(start, 1)
  var before = (new Date(Date.UTC(year, month, 1)).getUTCDay() - first + 7) % 7
  var cursor = new Date(Date.UTC(year, month, 1 - before))
  var today = String(todayKey || "")
  var weeks = []
  for (var w = 0; w < 6; w++) {
    var days = []
    var thursday = null
    for (var d = 0; d < 7; d++) {
      var cell = {
        key: dayKey(cursor.getUTCFullYear(), cursor.getUTCMonth(), cursor.getUTCDate()),
        year: cursor.getUTCFullYear(),
        month: cursor.getUTCMonth(),
        day: cursor.getUTCDate(),
        weekday: cursor.getUTCDay()
      }
      cell.inMonth = cell.month === month && cell.year === year
      cell.weekend = cell.weekday === 0 || cell.weekday === 6
      cell.today = cell.key === today
      if (cell.weekday === 4) thursday = cell
      days.push(cell)
      cursor.setUTCDate(cursor.getUTCDate() + 1)
    }
    var anchor = thursday || days[0]
    weeks.push({ week: isoWeek(anchor.year, anchor.month, anchor.day), days: days })
  }
  return weeks
}
