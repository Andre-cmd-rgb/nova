// What the notification service works out apart from its QML: the text a
// toast shows, the row it keeps of a notification, how long it stays, and
// the JSON files the toasts on screen and the history are kept in.

// Quickshell's NotificationUrgency.
var LOW = 0
var NORMAL = 1
var CRITICAL = 2

// ------------------------------------------------------------------- text

// Whether a tag, from its `<` to the next `>`, is an image. Qt names a tag by
// the first run of letters and digits after the `<`, skipping what it counts
// as space before it, and that is not JavaScript's \s: U+0085 is space to Qt
// and not to \s, U+FEFF the other way round (Qt 6.11). So everything before
// the run is skipped: a tag taken for an image by mistake is only dropped.
function isImageTag(tag) {
  var name = /^<[^A-Za-z0-9]*([A-Za-z0-9]+)/.exec(tag)
  return !!name && name[1].toLowerCase() === "img"
}

// The text with its image tags dropped. The body is drawn as StyledText, which
// fetches an <img src> from anywhere as soon as it is shown, with no one
// asking.
//
// A tag runs from a `<` to the next `>`, whatever is in between. Qt lets a `>`
// inside quotes pass, so a tag of Qt's can be longer than one taken here; that
// only ever splits it, and splitting can show an image tag hidden inside it but
// never hide one. Honouring the quotes instead would let
// `<b title="a>b"><img src="http://host/x.png">` through.
//
// Whole tags are dropped, never part of one: taking `<img src="http://a/d.png">`
// out of `<im<img src="http://a/d.png">g src="http://a/b.png">`, which Qt reads
// as one tag named `im`, would join what is left into a new image tag. The text
// between tags has no `<` in it, so dropping a tag cannot join its neighbours
// into one, and one pass is enough.
function withoutImages(text) {
  var out = ""
  var at = 0
  while (at < text.length) {
    var open = text.indexOf("<", at)
    if (open === -1) {
      out += text.slice(at)
      break
    }
    out += text.slice(at, open)
    // A tag left open at the end reaches Qt all the same, which closes it.
    var close = text.indexOf(">", open)
    var tag = close === -1 ? text.slice(open) : text.slice(open, close + 1)
    if (!isImageTag(tag)) out += tag
    at = close === -1 ? text.length : close + 1
  }
  return out
}

// Chromium and the browsers built on it begin a web page's notification with
// the site's address, which the toast leaves out.
function fromBrowser(app, appIcon) {
  var source = (String(app || "") + "\n" + String(appIcon || "")).toLowerCase()
  return source.indexOf("chrom") >= 0 || source.indexOf("brave") >= 0 || source.indexOf("vivaldi") >= 0
    || source.indexOf("microsoft-edge") >= 0 || source.indexOf("opera") >= 0
}

var LINKED_ADDRESS = /^\s*<a\b[^>]*>\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^<\s]*)?\s*<\/a>\s*/i
var ADDRESS = /^\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?\s+/i

// The body as the toast has it: no images, and from a browser no address
// first. A toast whose body is nothing then has one line.
function shownBody(body, app, appIcon) {
  var text = withoutImages(String(body || ""))
  if (!fromBrowser(app, appIcon)) return text
  return text.replace(LINKED_ADDRESS, "").replace(ADDRESS, "")
}

// The body as the toast draws it, its lines broken by <br/>, the last thing done
// to it before Qt reads it. The images are dropped again after: a kept tag
// with a line break and an image tag inside it, `<x`, newline,
// `<img src="http://...">`, is one tag named `x` until the break becomes
// `<x<br/>`, which leaves the image tag whole (Qt 6.11 fetches it).
function bodyMarkup(body, app, appIcon) {
  return withoutImages(shownBody(body, app, appIcon).replace(/\r\n|\r|\n/g, "<br/>"))
}

// Whether a one-character summary prefix stands for an icon: a character, a
// surrogate pair counting as one, then two spaces or more, as in "󰂚  Silenced".
// Such a toast shows no icon beside it.
function startsWithGlyph(summary) {
  var text = String(summary || "").replace(/^\s+/, "")
  if (!text) return false
  var at = text.length > 1 && text.charCodeAt(0) >= 0xd800 && text.charCodeAt(0) <= 0xdbff ? 2 : 1
  var spaces = 0
  for (; at < text.length && text.charAt(at) === " "; at++) spaces++
  return spaces >= 2
}

// A toast's glyph is drawn small, in line, when it has one line and no picture.
function compactGlyph(glyph, picture, oneLine) {
  return String(glyph || "").length > 0 && String(picture || "").length === 0 && !!oneLine
}

// ---------------------------------------------------------------- senders

function hint(hints, name) {
  try {
    if (hints) {
      var value = hints[name]
      if (value !== undefined && value !== null) return String(value)
    }
  } catch (e) {
  }
  return ""
}

// What do-not-disturb lets through: Nova's own toasts (nova-action), which
// answer something just done, and critical ones from notify-send, which
// scripts send. Chat apps mark messages critical too, but under their own
// name.
function breaksThroughDnd(notification) {
  var app = String((notification && notification.appName) || "")
  if (app === "nova-action") return true
  return app === "notify-send" && notification && notification.urgency === CRITICAL
}

// A notification no one looks back at: one marked transient, one from
// notify-send with no app named, and Nova's own. Silenced, it is not kept.
function passing(notification) {
  var transient = false
  try {
    transient = !!(notification.hints && notification.hints["transient"])
  } catch (e) {
    transient = false
  }
  var app = String(notification.appName || "")
  return transient || app === "notify-send" || app === "nova-action"
}

// The command a click on the toast runs, from its nova-exec-argv hint, which
// nova-notification-send sets and a toast's file keeps, so a toast restored
// after a restart still runs it: a JSON array of strings, the program first.
// Anything else runs nothing, nor does a program starting with "-", which
// would be read as an option. This checks the form only: any program on the
// session bus may send the hint, and could run anything anyway.
function runnable(value) {
  var text = String(value || "")
  if (!text) return null
  var argv
  try {
    argv = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!Array.isArray(argv) || argv.length === 0) return null
  for (var i = 0; i < argv.length; i++)
    if (typeof argv[i] !== "string") return null
  if (!argv[0] || argv[0].charAt(0) === "-") return null
  return argv
}

// ------------------------------------------------------------------- rows

function nonNegative(value) {
  var number = Number(value || 0)
  return isFinite(number) && number >= 0 ? number : 0
}

// The row a toast keeps of a notification, in the order its file has the keys.
// The model holds this copy and never the object, which the server frees when
// the notification goes; a row still holding it would crash the next read.
function rowOf(notification, timestamp) {
  var n = notification || {}
  var id = n.id || 0
  return {
    id: id,
    originalId: id,
    app: n.appName || "",
    appIcon: n.appIcon || "",
    summary: String(n.summary || ""),
    body: n.body || "",
    image: n.image || "",
    glyph: hint(n.hints, "nova-glyph"),
    execArgv: hint(n.hints, "nova-exec-argv"),
    urgency: n.urgency,
    expireTimeout: nonNegative(n.expireTimeout),
    timestamp: timestamp === undefined ? Date.now() : timestamp
  }
}

// The row again after its sender replaced the notification: the new content
// under the toast's own id and time, which name its file.
function updatedRow(notification, originalId, timestamp) {
  var row = rowOf(notification, timestamp)
  row.id = originalId
  row.originalId = originalId
  return row
}

// What the card draws, so what an update writes to the row and its file.
function shownRoles() {
  return ["app", "appIcon", "summary", "body", "image", "glyph", "execArgv", "urgency", "expireTimeout"]
}

// Whether an update changes what is drawn. A sender's update comes as one
// signal per property, and the catch-up after a row is added mostly finds
// nothing new; without this a file would be written for each.
function differs(row, updated) {
  var roles = shownRoles()
  for (var i = 0; i < roles.length; i++)
    if ((row || {})[roles[i]] !== (updated || {})[roles[i]]) return true
  return false
}

// How long a toast stays: a critical one until it is closed (0), the others as
// long as their sender asked, at least 5 s (low) or 8 s and at most 30 s.
function lifetime(urgency, expireTimeout) {
  if (urgency === CRITICAL) return 0
  var asked = Number(expireTimeout || 0)
  asked = isFinite(asked) && asked > 0 ? Math.round(asked) : 0
  return Math.min(30000, Math.max(urgency === LOW ? 5000 : 8000, asked))
}

// The toasts' margins: the bar's room on the edge it is on, top or right, and
// the gap elsewhere.
function margins(barPosition, clearance, gap) {
  var position = String(barPosition || "top")
  clearance = isFinite(Number(clearance)) ? Number(clearance) : 0
  gap = isFinite(Number(gap)) ? Number(gap) : 0
  return { top: position === "top" ? clearance : gap, right: position === "right" ? clearance : gap }
}

// ------------------------------------------------------------------ files
//
// Each toast on screen has a file of its own in notifications/, so the toasts
// come back after the shell restarts, as nova-update restarts it. It is
// written as the toast shows and moved into notifications/history/ as it goes,
// whatever takes it away; the history is the newest ten of those.

// A toast's file is named by its time and id, which tell toasts apart across
// shells, as every server counts ids from 1. Its pictures' copies are named
// <stem>-appIcon and <stem>-image after it.
function stem(row) {
  var e = row || {}
  return String(e.timestamp || 0) + "-" + String(e.originalId || 0)
}

function fileName(row) {
  return stem(row) + ".json"
}

// A row as the history has it: no lifetime of its own.
function historyRow(value) {
  var e = value || {}
  return {
    id: e.id || 0,
    originalId: e.originalId || e.id || 0,
    app: e.app || "",
    appIcon: e.appIcon || "",
    summary: e.summary || "",
    body: e.body || "",
    image: e.image || "",
    glyph: e.glyph || "",
    execArgv: e.execArgv || "",
    urgency: typeof e.urgency === "number" ? e.urgency : NORMAL,
    expireTimeout: 0,
    timestamp: e.timestamp || 0
  }
}

// A row as a toast's file has it: its sender's timeout, and the deadline a
// restored toast was given, which is left out when there is none so that the
// row has the same keys as a new one.
function toastRow(value) {
  var row = historyRow(value)
  row.expireTimeout = nonNegative((value || {}).expireTimeout)
  var deadline = Number((value || {}).deadline || 0)
  if (isFinite(deadline) && deadline > 0) row.deadline = deadline
  return row
}

// The file behind a picture's value: a path, a file:// URL, or a path sent as
// the image-path hint, which Quickshell hands over as image://icon/<path>. ""
// for one that cannot be copied: an icon's name, nothing, or a picture held in
// the server's memory.
function localFile(value) {
  var path = String(value || "")
  if (path.indexOf("image://icon//") === 0) path = path.slice("image://icon/".length)
  if (path.indexOf("file://") === 0) {
    path = path.slice(7)
    try { path = decodeURIComponent(path) } catch (e) {}
  }
  return path.charAt(0) === "/" ? path : ""
}

// A row as it is written, and the copies of its pictures to make before. A
// picture lasts only as long as its notification (Chromium deletes its files
// when it closes, a picture sent as data goes with the server's object), so
// the row names a copy in images/ instead; one held in memory is dropped and
// the card shows the app's icon. A value naming its copy already stays and
// makes no copy, so writing a restored toast again changes nothing.
function forDisk(row, imagesDir) {
  var out = {}
  for (var key in row || {}) out[key] = row[key]
  var copies = []
  var roles = ["appIcon", "image"]
  for (var i = 0; i < roles.length; i++) {
    var value = String(out[roles[i]] || "")
    if (!value) continue
    var source = localFile(value)
    if (source) {
      var copy = String(imagesDir || "") + stem(row) + "-" + roles[i]
      if (source !== copy) copies.push({ from: source, to: copy })
      out[roles[i]] = "file://" + copy
    } else if (value.indexOf("image://") === 0) {
      out[roles[i]] = ""
    }
  }
  return { entry: out, copies: copies }
}

// A file's one line: the files are read back joined, and parsed a line each.
function line(row) {
  return JSON.stringify(toastRow(row))
}

// The rows of the toast files, read back joined, newest first. A line that
// does not parse, from a write a crash cut short, is skipped. Two files with
// one id both stay: with ids counted from 1 by each server, they are most
// likely two notifications, and a critical one restored must not go for a new
// one. A crash between a replacement's write and the replaced file's removal
// shows the replaced toast once more, until it goes as toasts do.
function parseFiles(raw) {
  var lines = String(raw || "").split("\n")
  var rows = []
  for (var i = 0; i < lines.length; i++) {
    var text = lines[i].trim()
    if (!text) continue
    try {
      var value = JSON.parse(text)
      if (value && typeof value === "object") rows.push(toastRow(value))
    } catch (e) {
    }
  }
  rows.sort(function (a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return rows
}

// Whether a toast the shell before left on screen ran out since. A restored
// toast's deadline counts instead of its time, or a second restart would judge
// it by a clock it is no longer shown by; a toast with no lifetime, a critical
// one, never runs out.
function expired(row, duration, now) {
  var deadline = Number((row || {}).deadline || 0)
  if (isFinite(deadline) && deadline > 0) return Number(now) >= deadline
  var span = Number(duration || 0)
  if (!isFinite(span) || span <= 0) return false
  return Number(now) - Number((row || {}).timestamp || 0) >= span
}

// The rows the history replays, newest first, `limit` at most: the toasts on
// screen as it was asked for, then the history's files. Those toasts go to
// the history meanwhile, so the read may have them or not; a file and a
// toast of one name are one. Each is replayed for its urgency's lifetime, not
// what its sender asked.
function replayRows(raw, onScreen, limit) {
  var rows = []
  var seen = {}
  var both = (onScreen || []).concat(parseFiles(raw))
  for (var i = 0; i < both.length; i++) {
    if (!both[i] || seen[fileName(both[i])]) continue
    seen[fileName(both[i])] = true
    rows.push(historyRow(both[i]))
  }
  rows.sort(function (a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return rows.slice(0, limit)
}

// notifications.json: {"version": 3, "dnd": true}. Versions before kept the
// history in it too, as pending, past or entries; `legacy` says so, and the
// file is written again without it.
function parseSettings(raw) {
  var text = String(raw || "").trim()
  if (!text) return { error: false, dnd: null, legacy: false }
  try {
    var parsed = JSON.parse(text)
    return {
      error: false,
      dnd: parsed && typeof parsed.dnd === "boolean" ? parsed.dnd : null,
      legacy: !!(parsed && (parsed.pending || parsed.past || parsed.entries))
    }
  } catch (e) {
    return { error: true, errorMessage: String(e), dnd: null, legacy: false }
  }
}
