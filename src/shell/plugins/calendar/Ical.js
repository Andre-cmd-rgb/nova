// iCalendar (RFC 5545), as the calendar keeps it: read into components and
// their properties, written back the same way. A property this calendar does
// not know is kept as it was read, so a file another program wrote, or a
// later sync, loses nothing to an edit made here.
//
// A component is { name, props: [{ name, params, value }], components }; a
// value is the property's text as it stands in the file, still escaped.

// ---- reading

// A long line goes on in the next one, after a space or a tab.
function unfold(text) {
  return String(text || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n[ \t]/g, "")
}

// NAME;PARAM=value;PARAM="quoted: value":value, or null for a line that is
// none (no colon outside quotes).
function parseLine(line) {
  var quoted = false
  var colon = -1
  for (var i = 0; i < line.length; i++) {
    var c = line.charAt(i)
    if (c === '"') quoted = !quoted
    else if (c === ":" && !quoted) { colon = i; break }
  }
  if (colon < 0) return null
  var head = line.slice(0, colon)
  var parts = []
  var part = ""
  quoted = false
  for (var j = 0; j < head.length; j++) {
    var h = head.charAt(j)
    if (h === '"') quoted = !quoted
    if (h === ";" && !quoted) {
      parts.push(part)
      part = ""
    } else {
      part += h
    }
  }
  parts.push(part)
  var params = {}
  for (var k = 1; k < parts.length; k++) {
    var eq = parts[k].indexOf("=")
    if (eq < 0) continue
    var value = parts[k].slice(eq + 1)
    if (value.length >= 2 && value.charAt(0) === '"' && value.charAt(value.length - 1) === '"')
      value = value.slice(1, -1)
    params[parts[k].slice(0, eq).toUpperCase()] = value
  }
  return { name: parts[0].toUpperCase(), params: params, value: line.slice(colon + 1) }
}

// The file as a tree under a nameless root: its VCALENDAR is a component of
// it. An END with no BEGIN is dropped, a BEGIN with no END ends with the file.
function parse(text) {
  var root = { name: "", props: [], components: [] }
  var stack = [root]
  var lines = unfold(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue
    var p = parseLine(lines[i])
    if (!p) continue
    if (p.name === "BEGIN") {
      var c = { name: p.value.toUpperCase(), props: [], components: [] }
      stack[stack.length - 1].components.push(c)
      stack.push(c)
    } else if (p.name === "END") {
      if (stack.length > 1) stack.pop()
    } else {
      stack[stack.length - 1].props.push(p)
    }
  }
  return root
}

// ---- writing

function quoteParam(value) {
  value = String(value)
  return /[:;,]/.test(value) ? '"' + value.replace(/"/g, "") + '"' : value
}

// The UTF-8 bytes a character takes, for folding at 75 octets.
function octets(code) {
  return code < 0x80 ? 1 : code < 0x800 ? 2 : code >= 0xd800 && code <= 0xdbff ? 4 : code >= 0xdc00 && code <= 0xdfff ? 0 : 3
}

// Folded at 75 octets, never inside a character.
function fold(line) {
  var out = []
  var current = ""
  var size = 0
  for (var i = 0; i < line.length; i++) {
    var code = line.charCodeAt(i)
    var n = octets(code)
    // The low half of a pair goes with its high half.
    if (n > 0 && size + n > (out.length ? 74 : 75)) {
      out.push(current)
      current = ""
      size = 0
    }
    current += line.charAt(i)
    size += n
  }
  out.push(current)
  return out.join("\r\n ")
}

function propLine(p) {
  var line = p.name
  for (var key in p.params) line += ";" + key + "=" + quoteParam(p.params[key])
  return fold(line + ":" + p.value)
}

function serializeComponent(c, out) {
  out.push("BEGIN:" + c.name)
  for (var i = 0; i < c.props.length; i++) out.push(propLine(c.props[i]))
  for (var j = 0; j < c.components.length; j++) serializeComponent(c.components[j], out)
  out.push("END:" + c.name)
}

// The tree parse() made, as a file: CRLF line ends, as the RFC has them.
function serialize(root) {
  var out = []
  for (var i = 0; i < root.components.length; i++) serializeComponent(root.components[i], out)
  return out.join("\r\n") + "\r\n"
}

// ---- properties

function prop(c, name) {
  for (var i = 0; i < c.props.length; i++) if (c.props[i].name === name) return c.props[i]
  return null
}

function props(c, name) {
  return c.props.filter(function (p) { return p.name === name })
}

// Replaces the first property of the name, or adds one; the rest of that
// name go.
function setProp(c, name, value, params) {
  var at = -1
  c.props = c.props.filter(function (p, i) {
    if (p.name !== name) return true
    if (at < 0) at = i
    return false
  })
  var p = { name: name, params: params || {}, value: String(value) }
  if (at < 0) c.props.push(p)
  else c.props.splice(Math.min(at, c.props.length), 0, p)
}

function removeProp(c, name) {
  c.props = c.props.filter(function (p) { return p.name !== name })
}

function child(c, name) {
  for (var i = 0; i < c.components.length; i++) if (c.components[i].name === name) return c.components[i]
  return null
}

// ---- values

function escapeText(text) {
  return String(text).replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n")
}

function unescapeText(text) {
  return String(text || "").replace(/\\([\\;,nN])/g, function (m, c) { return c === "n" || c === "N" ? "\n" : c })
}

function text(c, name) {
  var p = prop(c, name)
  return p ? unescapeText(p.value) : ""
}

function pad(n, width) {
  var s = String(n)
  while (s.length < (width || 2)) s = "0" + s
  return s
}

// A DATE or DATE-TIME property as { time, allDay }: a date is its local
// midnight, a time ending in Z is UTC, and any other time is taken as local,
// with or without a TZID (the calendar writes the system's own zone, which it
// cannot convert from another). null when unreadable.
function parseTime(p) {
  if (!p) return null
  var m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/.exec(String(p.value).trim())
  if (!m) return null
  var y = +m[1], mo = +m[2] - 1, d = +m[3]
  if (m[4] === undefined || p.params.VALUE === "DATE") return { time: new Date(y, mo, d).getTime(), allDay: true }
  var time = m[7] === "Z" ? Date.UTC(y, mo, d, +m[4], +m[5], +m[6]) : new Date(y, mo, d, +m[4], +m[5], +m[6]).getTime()
  return { time: time, allDay: false }
}

function formatDate(time) {
  var t = new Date(time)
  return pad(t.getFullYear(), 4) + pad(t.getMonth() + 1) + pad(t.getDate())
}

function formatLocal(time) {
  var t = new Date(time)
  return formatDate(time) + "T" + pad(t.getHours()) + pad(t.getMinutes()) + pad(t.getSeconds())
}

function formatUtc(time) {
  var t = new Date(time)
  return pad(t.getUTCFullYear(), 4) + pad(t.getUTCMonth() + 1) + pad(t.getUTCDate()) + "T" +
    pad(t.getUTCHours()) + pad(t.getUTCMinutes()) + pad(t.getUTCSeconds()) + "Z"
}

// Sets a DATE (allDay) or a local DATE-TIME in <zone>, the system's, or with
// none (floating) when it is not known.
function setTime(c, name, time, allDay, zone) {
  if (allDay) setProp(c, name, formatDate(time), { VALUE: "DATE" })
  else setProp(c, name, formatLocal(time), zone ? { TZID: zone } : {})
}

// [+|-]P[nW][nD][T[nH][nM][nS]] in milliseconds, or null.
function parseDuration(value) {
  var m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(String(value || "").trim())
  if (!m || value === "P" || /T$/.test(value)) return null
  var ms = ((+(m[2] || 0) * 7 + +(m[3] || 0)) * 86400 + +(m[4] || 0) * 3600 + +(m[5] || 0) * 60 + +(m[6] || 0)) * 1000
  return m[1] === "-" ? -ms : ms
}

function formatDuration(ms) {
  var sign = ms < 0 ? "-" : ""
  var s = Math.round(Math.abs(ms) / 1000)
  if (s === 0) return "PT0S"
  var days = Math.floor(s / 86400)
  s -= days * 86400
  var out = sign + "P" + (days ? days + "D" : "")
  if (s) {
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60
    out += "T" + (h ? h + "H" : "") + (m ? m + "M" : "") + (sec ? sec + "S" : "")
  }
  return out
}
