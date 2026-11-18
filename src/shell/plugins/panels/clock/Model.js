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

// The walk: the presets, then the configured alternate and format when they
// are others, each once. Its order does not depend on the format in use, or
// a step written back to shell.json would turn the walk into a swing
// between two.
function formatRing(configured, alternate, presets) {
  const all = (presets || []).concat([alternate, configured]).map(text)
  const ring = all.filter((format, at) => format !== "" && all.indexOf(format) === at)
  return ring.length > 0 ? ring : ["HH:mm"]
}

// The format after `current`; after one the walk does not have (written by
// hand), its first.
function nextFormat(ring, current) {
  const count = ring ? ring.length : 0
  return count > 0 ? ring[(ring.indexOf(text(current)) + 1) % count] : ""
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

// The ISO 8601 week: the week of its year, from 1, that the Thursday of
// the date's week from Monday is in. Counted in days since 1 January 1970,
// a Thursday.
function isoWeek(year, month, day) {
  const days = Date.UTC(year, month, day) / DAY
  const fromMonday = ((days + 3) % 7 + 7) % 7
  const thursday = days - fromMonday + 3
  const itsYear = new Date(thursday * DAY).getUTCFullYear()
  return Math.floor((thursday - Date.UTC(itsYear, 0, 1) / DAY) / 7) + 1
}

// The share of the year gone: the days over, out of all of it, so that 1
// January is 0 and 31 December, 1 less a day.
function yearShare(year, month, day) {
  const start = Date.UTC(year, 0, 1)
  const length = (Date.UTC(year + 1, 0, 1) - start) / DAY
  const gone = Math.round((Date.UTC(year, month, day) - start) / DAY)
  return length > 0 ? Math.max(0, Math.min(1, gone / length)) : 0
}

function percent(share) {
  return Math.round(share * 100)
}

// A month as one number, the months since the year 0, so that going some
// months on is adding them; and that number back as { year, month }. No
// date is made, so no clock change can move it.
function monthCount(year, month) {
  return year * 12 + month
}

function monthAt(count) {
  var year = Math.floor(count / 12)
  return { year: year, month: count - year * 12 }
}

// A day by its key, at noon: on that day wherever the clocks change, so
// what the day is named by and opened on.
function noonOf(key) {
  var part = String(key).split("-")
  return new Date(Number(part[0]), Number(part[1]) - 1, Number(part[2]), 12)
}

// ------------------------------------------------------------ memento mori

// Ninety: a round number to measure by, not a table's. Anyone may set
// their own.
var LIFE_SPAN = 90

// <value> as text, "" for none; and trimmed.
function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

function trimmed(value) {
  return text(value).trim()
}

// <value> as a whole number written in digits alone; 0 for anything else.
function wholeNumber(value) {
  const digits = trimmed(value)
  return /^\d+$/.test(digits) ? Number(digits) : 0
}

// The year of birth, which keeps the age right without being told again;
// 0 for none, and for one that is not four digits, in the future, or more
// than 120 years back.
function birthYear(value, thisYear) {
  const now = Math.round(Number(thisYear))
  const written = trimmed(value)
  if (!isFinite(now) || !/^\d{4}$/.test(written)) return 0
  const year = Number(written)
  return year <= now && year >= now - 120 ? year : 0
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
  const years = wholeNumber(value)
  return years >= 1 && years <= 150 ? years : LIFE_SPAN
}

// The share of the span lived; 0 without an age from 1 to 120.
function lifeShare(years, span) {
  const lived = wholeNumber(years)
  return lived >= 1 && lived <= 120 ? Math.min(1, lived / lifeSpan(span)) : 0
}

// --------------------------------------------------------------- the week

// <n> counted round a week: 8 is 1, -1 is 6.
function roundWeek(n) {
  return (n % 7 + 7) % 7
}

// A day of the week from a setting: its number (any whole number, taken
// modulo 7), its name or its first three letters; null for none.
function weekday(value) {
  if (typeof value === "number") return isFinite(value) ? roundWeek(Math.round(value)) : null
  const written = trimmed(value).toLowerCase()
  if (written === "") return null
  const named = WEEKDAYS.findIndex(name => name === written || name.slice(0, 3) === written)
  if (named !== -1) return named
  const number = parseInt(written, 10)
  return isFinite(number) ? roundWeek(number) : null
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
  const first = weekStart(start, 1)
  return WEEKDAYS.map((name, i) => (first + i) % 7)
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
  // The days shown of the month before.
  const lead = (new Date(Date.UTC(year, month, 1)).getUTCDay() - weekStart(start, 1) + 7) % 7
  const today = String(todayKey || "")

  // The grid's <n>th day, from 0.
  function cell(n) {
    const date = new Date(Date.UTC(year, month, 1 - lead + n))
    const y = date.getUTCFullYear()
    const m = date.getUTCMonth()
    const d = date.getUTCDate()
    const weekday = date.getUTCDay()
    const key = dayKey(y, m, d)
    return { key: key, year: y, month: m, day: d, weekday: weekday,
      inMonth: m === month && y === year, weekend: weekday === 0 || weekday === 6, today: key === today }
  }

  const SEVEN = [0, 1, 2, 3, 4, 5, 6]
  return SEVEN.slice(0, 6).map(week => {
    const days = SEVEN.map(n => cell(week * 7 + n))
    const thursday = days.find(day => day.weekday === 4)
    return { week: isoWeek(thursday.year, thursday.month, thursday.day), days: days }
  })
}
