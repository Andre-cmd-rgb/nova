// The notifications' rules, apart from their QML: what a toast may show, who
// gets past do-not-disturb, what a click runs, how long a toast stays, and
// the rows the service keeps and the files it keeps them in.

// Quickshell's NotificationUrgency.
var LOW = 0
var NORMAL = 1
var CRITICAL = 2

// ------------------------------------------------------- what a toast shows

// Whether a tag, from its `<` to the next `>`, is an image. Qt names a tag by
// the first run of letters and digits after the `<`, past what it counts as
// space, and that is not JavaScript's \s: U+0085 is space to Qt and not to
// \s, U+FEFF the other way round (Qt 6.11). So all that comes before the run
// is passed over; a tag taken for an image by mistake is only dropped.
function namesImage(tag) {
  return /^<[^A-Za-z0-9]*img(?![A-Za-z0-9])/i.test(tag)
}

// The text without its image tags. The body is drawn as StyledText, which
// fetches an <img src> from anywhere the moment it shows, unasked.
//
// A tag runs from a `<` to the next `>`, whatever is in between. Qt lets a
// `>` in quotes pass, so a tag of Qt's can be longer than one taken here; that
// only ever splits it, which can bring an image tag inside it to light but
// never hide one. Going by the quotes instead would let
// `<b title="a>b"><img src="http://host/x.png">` through.
//
// A tag goes whole or stays whole: taking `<img src="http://a/d.png">` out of
// `<im<img src="http://a/d.png">g src="http://a/b.png">`, one tag named `im`
// to Qt, would leave a new image tag behind. The text between tags has no `<`
// in it, so dropping a tag joins nothing into one, and one pass does. A tag
// open at the end goes to Qt all the same, which closes it.
function withoutImages(text) {
  return text.replace(/<[^>]*>?/g, tag => namesImage(tag) ? "" : tag)
}

// Chromium and the browsers made from it start a web page's notification with
// the site's address, which the toast leaves out.
function fromBrowser(app, appIcon) {
  return /chrom|brave|vivaldi|microsoft-edge|opera/.test((String(app || "") + "\n" + String(appIcon || "")).toLowerCase())
}

var LINKED_ADDRESS = /^\s*<a\b[^>]*>\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^<\s]*)?\s*<\/a>\s*/i
var ADDRESS = /^\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?\s+/i

// The body as the toast has it: no images, and from a browser no address
// first. A toast whose body comes to nothing is one line.
function shownBody(body, app, appIcon) {
  var text = withoutImages(String(body || ""))
  return fromBrowser(app, appIcon) ? text.replace(LINKED_ADDRESS, "").replace(ADDRESS, "") : text
}

// The body as the toast draws it, its lines broken by <br/>, the last thing
// done to it before Qt reads it. The images go again after: a tag kept with a
// line break and an image tag in it, `<x`, a newline, `<img src="http://...">`,
// is one tag named `x` until the break makes it `<x<br/>`, which leaves the
// image tag whole (Qt 6.11 fetches it).
function bodyMarkup(body, app, appIcon) {
  return withoutImages(shownBody(body, app, appIcon).replace(/\r\n|\r|\n/g, "<br/>"))
}

// Whether a summary starts with an icon of its own: one character (a
// surrogate pair is one) and two spaces, as in "󰂚  Silenced". Its toast
// shows no other.
function startsWithGlyph(summary) {
  var text = String(summary || "")
  var first = /^\s*(?:[\uD800-\uDBFF][\s\S]|[\s\S])/.exec(text)
  return !!first && text.substr(first[0].length, 2) === "  "
}

// ---------------------------------------------------------------- senders

// A hint of the notification's as text, "" when it has none.
function hint(hints, name) {
  try {
    var value = hints ? hints[name] : null
    return value === undefined || value === null ? "" : String(value)
  } catch (e) {
    return ""
  }
}

// What do-not-disturb lets through: Nova's own toasts (nova-action), which
// answer something just done, and notify-send's critical ones, which scripts
// send. Chat apps mark messages critical too, under their own names.
function breaksThroughDnd(notification) {
  var app = String(notification && notification.appName || "")
  return app === "nova-action" || app === "notify-send" && notification.urgency === CRITICAL
}

// One no one looks back at, which do-not-disturb does not keep: marked
// transient, from notify-send with no app named, or Nova's own.
function passing(notification) {
  return markedTransient(notification) || ["notify-send", "nova-action"].includes(String(notification.appName || ""))
}

// Its "transient" hint, as a notification's hints say; asking one gone may
// throw, and it is no longer there to keep.
function markedTransient(notification) {
  try {
    return !!notification.hints?.transient
  } catch (gone) {
    return false
  }
}

// The command a click on the toast runs, from its nova-exec-argv hint, which
// nova-notification-send sets and the toast's file keeps, so that a toast
// back after a restart still runs it: a JSON array of strings, the program
// first. Anything else runs nothing, and nor does a program starting with
// "-", which would pass for an option. Only the form is checked: any program
// on the session bus may send the hint, and could run anything anyway.
function runnable(value) {
  try {
    return command(JSON.parse(String(value || "")))
  } catch (e) {
    return null
  }
}

// A command as a list of words, the program first, or null.
function command(argv) {
  var sound = Array.isArray(argv) && argv.length > 0 && argv.every(word => typeof word === "string")
    && argv[0] !== "" && !argv[0].startsWith("-")
  return sound ? argv : null
}

// The buttons of a toast, from its nova-buttons hint, which Nova's own set
// (AirDrop's offer has Decline and Accept): a JSON array of at most three,
// each what it `says`, the command a press runs (`argv`, as runnable takes
// it), and whether it is the `main` one. Anything else is no buttons, and a
// button with no words or no sound command is left out.
function buttonsOf(value) {
  var list
  try {
    list = JSON.parse(String(value || ""))
  } catch (e) {
    return []
  }
  if (!Array.isArray(list)) return []
  return list.filter(button => button && typeof button.says === "string" && button.says.trim() !== "" && command(button.argv))
    .slice(0, 3).map(button => ({ says: button.says.trim().slice(0, 40), argv: button.argv, main: button.main === true }))
}

// How far along a toast says it is, from 0 to 100, as the "value" hint says
// it; -1 for a toast with no bar.
function progressOf(value) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  var number = Math.round(Number(text))
  return text !== "" && isFinite(number) ? Math.max(0, Math.min(100, number)) : -1
}

// A toast that asked something or showed a transfer under way: once it is
// gone, what it said holds no longer, and the history does not keep it.
function moot(row) {
  return buttonsOf((row || {}).buttons).length > 0 || Number((row || {}).progress) >= 0
}

// How long a toast stays, in ms: a critical one until it is closed (0), the
// others as long as their sender asked, at least 5 s (low) or 8 s, at most
// 30 s.
function lifetime(urgency, expireTimeout) {
  if (urgency === CRITICAL) return 0
  return Math.min(30000, Math.max(urgency === LOW ? 5000 : 8000, Math.round(amount(expireTimeout))))
}

// ------------------------------------------------------------------- rows

// A row's roles, in the order its file has them. The card draws those from
// app to progress, so they are what an update changes.
var ROLES = ["id", "originalId", "app", "appIcon", "summary", "body", "image", "glyph", "execArgv", "buttons", "urgency", "expireTimeout", "progress", "timestamp"]
var SHOWN = ROLES.slice(2, 13)
var TEXTS = ROLES.slice(2, 10)

// A timeout or a time as a number: 0 for none, below nothing, or not a
// number at all.
function amount(value) {
  const number = Number(value || 0)
  return number > 0 && number < Infinity ? number : 0
}

// A row as the history keeps it, from a file or a toast: each text "" at
// worst, normal urgency for none, and no lifetime or bar of its own.
function historyRow(value) {
  var kept = value || {}
  var row = { id: kept.id || 0, originalId: kept.originalId || kept.id || 0 }
  TEXTS.forEach(role => row[role] = kept[role] || "")
  row.urgency = typeof kept.urgency === "number" ? kept.urgency : NORMAL
  row.expireTimeout = 0
  row.progress = -1
  row.timestamp = kept.timestamp || 0
  return row
}

// A row as a toast's file has it: its sender's timeout and bar, and the
// deadline a toast brought back after a restart was given, left out for none
// so that the row has the same keys as a new one.
function toastRow(value) {
  var row = historyRow(value)
  row.expireTimeout = amount((value || {}).expireTimeout)
  row.progress = progressOf((value || {}).progress)
  var deadline = amount((value || {}).deadline)
  if (deadline) row.deadline = deadline
  return row
}

// A notification as a row, under `id` (its own by default), for the model
// to hold in its place: the server frees the object when the notification
// goes, and a row holding it would crash the next read.
function rowOf(notification, timestamp, id) {
  var row = historyRow({
    id: id === undefined ? notification.id : id,
    app: notification.appName,
    appIcon: notification.appIcon,
    summary: String(notification.summary || ""),
    body: notification.body,
    image: notification.image,
    glyph: hint(notification.hints, "nova-glyph"),
    execArgv: hint(notification.hints, "nova-exec-argv"),
    buttons: hint(notification.hints, "nova-buttons"),
    timestamp: timestamp
  })
  row.urgency = notification.urgency
  row.expireTimeout = amount(notification.expireTimeout)
  row.progress = progressOf(hint(notification.hints, "value"))
  return row
}

// The properties of a notification its row is made from, which its sender
// may change in place.
var WATCHED = ["summary", "body", "appName", "appIcon", "image", "urgency", "expireTimeout", "hints"]

// A row of the model's as a plain one.
function plain(row) {
  // QML's JavaScript has no Object.fromEntries.
  return ROLES.reduce((out, role) => Object.assign(out, { [role]: row[role] }), {})
}

// Whether an update changes what is drawn. A sender's update comes as one
// signal a property, and the look after a row is added mostly finds nothing
// new; without this a file would be written for each.
function differs(row, updated) {
  return SHOWN.some(role => (row || {})[role] !== (updated || {})[role])
}

// ------------------------------------------------------------------ files
//
// Each toast on screen has a file of its own in notifications/, so that the
// toasts come back when the shell restarts, as nova-update restarts it. It is
// written as the toast shows and moves into notifications/history/ as it
// goes, whatever takes it away; the history is the newest ten of those.

// A toast's file is named by its time and id, which tell toasts apart across
// shells, as every server counts ids from 1. The copies of its pictures are
// <stem>-appIcon and <stem>-image.
function stem(row) {
  return (row.timestamp || 0) + "-" + (row.originalId || 0)
}

function fileName(row) {
  return stem(row) + ".json"
}

function decoded(text) {
  try {
    return decodeURIComponent(text)
  } catch (e) {
    return text
  }
}

// The file behind a picture: a path, a file:// URL, or a path sent as the
// image-path hint, which Quickshell hands on as image://icon/<path>. "" for
// what cannot be copied: an icon's name, nothing, a picture in the server's
// memory.
function localFile(value) {
  var path = String(value || "").replace(/^image:\/\/icon\/(?=\/)/, "")
  if (path.startsWith("file://")) path = decoded(path.slice(7))
  return path.startsWith("/") ? path : ""
}

// A row as it is written, and the copies of its pictures to make first. A
// picture lasts only as long as its notification (Chromium deletes its files
// as it closes, a picture sent as data goes with the server's object), so
// the row names a copy in images/ instead; one in memory is dropped, and the
// card shows the app's icon. A row naming its copy already keeps it and
// copies nothing, so a toast written again after a restart changes nothing.
function forDisk(row, imagesDir) {
  const pictures = ["appIcon", "image"].map(role => ({
    role, source: localFile(row[role]), copy: String(imagesDir || "") + stem(row) + "-" + role,
    inMemory: String(row[role] || "").startsWith("image://")
  }))
  const entry = Object.assign({}, row)
  for (const picture of pictures) {
    if (picture.source || picture.inMemory) entry[picture.role] = picture.source ? "file://" + picture.copy : ""
  }
  const toCopy = pictures.filter(picture => picture.source && picture.source !== picture.copy)
  return { entry, copies: toCopy.map(picture => ({ from: picture.source, to: picture.copy })) }
}

// A file's one line: the files are read back joined, a line each.
function line(row) {
  return JSON.stringify(toastRow(row))
}

function newestFirst(a, b) {
  return (b.timestamp || 0) - (a.timestamp || 0)
}

function parsedLine(text) {
  try {
    var value = JSON.parse(text.trim())
    return value && typeof value === "object" ? value : null
  } catch (e) {
    return null
  }
}

// The rows of the toasts' files, read back joined, newest first. A line that
// does not parse, from a write a crash cut short, is passed over. Two files
// of one id both stay: with each server counting ids from 1 they are most
// likely two notifications, and a critical one brought back must not go for
// a new one. A crash between a replacement's write and the removal of the
// file it replaces shows the old toast once more, until it goes as toasts do.
function parseFiles(raw) {
  return String(raw || "").split("\n").map(parsedLine).filter(Boolean).map(toastRow).sort(newestFirst)
}

// Whether a toast the shell before left on screen has run out since. A
// toast brought back goes by its deadline, not its time, or a second restart
// would judge it by a clock it no longer shows by; one with no lifetime, a
// critical one, never runs out.
function expired(row, duration, now) {
  var deadline = amount(row.deadline)
  if (deadline) return Number(now) >= deadline
  var span = amount(duration)
  return span > 0 && Number(now) - Number(row.timestamp || 0) >= span
}

// What the history replays, newest first, `limit` at most: the toasts on
// screen as it was asked for, then the history's files. The toasts go to the
// history meanwhile, so the read may have them or not; a file and a toast of
// one name are one, and a moot one is none. Each replays for its urgency's
// lifetime, not what its sender asked.
function replayRows(raw, onScreen, limit) {
  var seen = {}
  return (onScreen || []).concat(parseFiles(raw)).filter(row => {
    if (!row || moot(row) || seen[fileName(row)]) return false
    seen[fileName(row)] = true
    return true
  }).map(historyRow).sort(newestFirst).slice(0, limit)
}

// notifications.json, {"version": 3, "dnd": true, "turn": "on 2026-11-16",
// "bySchedule": true}: do-not-disturb, null when it says nothing; its
// schedule's last turn made (Util.turnName), "" for none; whether
// do-not-disturb is as that turn left it; and whether it is an older one
// that kept the history too (as pending, past or entries), to be written
// again without. `problem` says why it does not parse.
function readSettings(raw) {
  var text = String(raw || "").trim()
  try {
    var json = text ? JSON.parse(text) : {}
    var turn = json && typeof json.turn === "string" && /^(on|off) \d{4}-\d\d-\d\d$/.test(json.turn) ? json.turn : ""
    return {
      dnd: json && typeof json.dnd === "boolean" ? json.dnd : null,
      turn: turn,
      bySchedule: turn !== "" && json.bySchedule === true,
      legacy: !!json && ["pending", "past", "entries"].some(key => !!json[key]),
      problem: ""
    }
  } catch (e) {
    return { dnd: null, turn: "", bySchedule: false, legacy: false, problem: String(e) }
  }
}
