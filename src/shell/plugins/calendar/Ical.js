// iCalendar (RFC 5545), as the calendar keeps it: read into components and
// their properties, written back the same way. A property this calendar does
// not know is kept as it was read, so a file another program wrote, or a
// later sync, loses nothing to an edit made here.
//
// A component is { name, props: [{ name, params, value, raw }], components };
// a value is the property's text as it stands in the file, still escaped, and
// raw its name and parameters as they were read, written back the same, since
// a parameter can be a list (MEMBER="mailto:a","mailto:b") that params, read
// for what this calendar needs of them, does not keep. A property made or
// changed here has none, and is written from its params.

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
  return { name: parts[0].toUpperCase(), params: params, value: line.slice(colon + 1), raw: head }
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
  if (p.raw !== undefined) return fold(p.raw + ":" + p.value)
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

// The instant a time on the local clock names. One the clocks skip, going
// forward, is read with the offset before the skip, as RFC 5545 reads it:
// Qt's engine reads it with the offset after, an hour early, which puts a
// skipped midnight (Santiago's in September, Havana's in March) on the day
// before. Read this way, it is the first moment of its own day.
function localTime(year, month, date, hours, minutes, seconds, ms) {
  var t = new Date(year, month, date, hours || 0, minutes || 0, seconds || 0, ms || 0)
  var wanted = Date.UTC(year, month, date, hours || 0, minutes || 0, seconds || 0, ms || 0)
  var read = t.getTime() - t.getTimezoneOffset() * 60000
  return t.getTime() + Math.max(0, wanted - read)
}

// A DATE or DATE-TIME property as { time, allDay, zone }: a date is its day's
// first moment here, a time ending in Z is UTC, and a time with a TZID the
// file's VTIMEZONEs define (<zones>, zonesOf) is read on that zone's clock,
// which is returned with it. Any other time is this computer's: floating, or
// in a zone the file does not define (the calendar writes the system's own
// zone, with no VTIMEZONE, and reads it back so). null when unreadable.
function parseTime(p, zones) {
  if (!p) return null
  var m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/.exec(String(p.value).trim())
  if (!m) return null
  var y = +m[1], mo = +m[2] - 1, d = +m[3]
  if (m[4] === undefined || p.params.VALUE === "DATE") return { time: localTime(y, mo, d), allDay: true, zone: null }
  if (m[7] === "Z") return { time: Date.UTC(y, mo, d, +m[4], +m[5], +m[6]), allDay: false, zone: UTC }
  var zone = zones && p.params.TZID ? zones[p.params.TZID] || null : null
  if (zone) return { time: zone.wallToUtc(Date.UTC(y, mo, d, +m[4], +m[5], +m[6])), allDay: false, zone: zone }
  return { time: localTime(y, mo, d, +m[4], +m[5], +m[6]), allDay: false, zone: null }
}

// ---- time zones, as a file's VTIMEZONEs define them
//
// A zone is { offsetAt(utc), wallToUtc(wall) }, a wall time being the
// milliseconds Date.UTC gives for the numbers on the zone's clock.

var UTC = { offsetAt: function () { return 0 }, wallToUtc: function (wall) { return wall } }

// +hhmm or -hhmmss in milliseconds, or null.
function parseOffset(value) {
  var m = /^([+-])(\d{2})(\d{2})(\d{2})?$/.exec(String(value || "").trim())
  return m ? (m[1] === "-" ? -1 : 1) * ((+m[2] * 60 + +m[3]) * 60 + +(m[4] || 0)) * 1000 : null
}

// A date-time's numbers as Date.UTC reads them, whatever clock it is on, or
// null.
function wallOf(value) {
  var m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2}))?Z?$/.exec(String(value || "").trim())
  return m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0)) : null
}

function ruleParts(value) {
  var out = {}
  String(value || "").split(";").forEach(function (part) {
    var eq = part.indexOf("=")
    if (eq > 0) out[part.slice(0, eq).toUpperCase()] = part.slice(eq + 1).toUpperCase()
  })
  return out
}

// The day of <month> a yearly rule of a VTIMEZONE names: BYDAY with its
// ordinal (-1SU, the last Sunday; 2SU, the second), a weekday among the days
// BYMONTHDAY lists (SU among 8 to 14, the second Sunday, as older programs
// write it), or BYMONTHDAY alone; else <date>, the day the part starts on.
function ruleDate(rule, year, month, date) {
  var length = new Date(Date.UTC(year, month + 1, 0)).getUTCDate()
  var days = (rule.BYMONTHDAY || "").split(",").map(function (d) {
    var n = parseInt(d, 10)
    return n > 0 ? n : length + n + 1
  }).filter(function (n) { return n >= 1 && n <= length })
  var byday = /^([+-]?\d)?(SU|MO|TU|WE|TH|FR|SA)$/.exec(rule.BYDAY || "")
  if (byday) {
    var dow = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"].indexOf(byday[2])
    var matches = []
    for (var d = 1; d <= length; d++)
      if (new Date(Date.UTC(year, month, d)).getUTCDay() === dow && (byday[1] || !days.length || days.indexOf(d) >= 0)) matches.push(d)
    var n = byday[1] ? parseInt(byday[1], 10) : 1
    return n > 0 ? matches[n - 1] : matches[matches.length + n]
  }
  return days.length ? days[0] : date
}

// A VTIMEZONE as a zone, or null where it has no part that reads. Its
// changes are its STANDARD and DAYLIGHT parts, each a first change (DTSTART,
// on the clock before it) and, where it goes on, a yearly rule or RDATEs.
function zoneOf(vtimezone) {
  var observances = []
  vtimezone.components.forEach(function (c) {
    if (c.name !== "STANDARD" && c.name !== "DAYLIGHT") return
    var from = parseOffset((prop(c, "TZOFFSETFROM") || {}).value)
    var to = parseOffset((prop(c, "TZOFFSETTO") || {}).value)
    var wall = wallOf((prop(c, "DTSTART") || {}).value)
    if (from === null || to === null || wall === null) return
    var rdates = []
    props(c, "RDATE").forEach(function (p) {
      String(p.value).split(",").forEach(function (v) {
        var w = wallOf(v)
        if (w !== null) rdates.push(w)
      })
    })
    var rule = prop(c, "RRULE") ? ruleParts(prop(c, "RRULE").value) : null
    if (rule && rule.FREQ !== "YEARLY") rule = null
    var until = rule && rule.UNTIL ? wallOf(rule.UNTIL) : null
    observances.push({ from: from, to: to, wall: wall, rdates: rdates, rule: rule, until: until })
  })
  if (observances.length === 0) return null

  // The changes up to the end of a year, from the start of the one before:
  // { at (UTC), offset (after) }, in order.
  var cache = {}
  function changes(year) {
    if (cache[year]) return cache[year]
    var out = []
    var lo = Date.UTC(year - 1, 0, 1) - 86400000, hi = Date.UTC(year + 1, 0, 1) + 86400000
    observances.forEach(function (o) {
      function add(wall) {
        var at = wall - o.from
        if (at >= lo && at < hi) out.push({ at: at, offset: o.to })
      }
      add(o.wall)
      o.rdates.forEach(add)
      if (!o.rule) return
      var base = new Date(o.wall)
      for (var y = Math.max(year - 1, base.getUTCFullYear()); y <= year; y++) {
        var month = o.rule.BYMONTH ? parseInt(o.rule.BYMONTH, 10) - 1 : base.getUTCMonth()
        var date = ruleDate(o.rule, y, month, base.getUTCDate())
        if (!date) continue
        var wall = Date.UTC(y, month, date, base.getUTCHours(), base.getUTCMinutes(), base.getUTCSeconds())
        if (wall <= o.wall || (o.until !== null && wall - o.from > o.until)) continue
        add(wall)
      }
    })
    out.sort(function (a, b) { return a.at - b.at })
    cache[year] = out
    return out
  }

  // The changes on fixed days, its parts' first ones and their RDATEs: with
  // no rule for the year asked, the latest of them before it holds. Before
  // the first change of all, a zone is at the offset that change leaves.
  var fixed = []
  observances.forEach(function (o) {
    [o.wall].concat(o.rdates).forEach(function (wall) { fixed.push({ at: wall - o.from, offset: o.to, from: o.from }) })
  })
  fixed.sort(function (a, b) { return a.at - b.at })

  function offsetAt(utc) {
    var list = changes(new Date(utc).getUTCFullYear())
    var found = null
    for (var i = 0; i < list.length && list[i].at <= utc; i++) found = list[i]
    if (found) return found.offset
    for (var j = 0; j < fixed.length && fixed[j].at <= utc; j++) found = fixed[j]
    return found ? found.offset : fixed[0].from
  }

  // A time on the zone's clock that is there twice (the clocks went back)
  // is the first; one the clocks skip is read by the offset before the skip,
  // as RFC 5545 has it.
  function wallToUtc(wall) {
    var day = 86400000
    var offsets = [offsetAt(wall - day), offsetAt(wall + day)]
    var found = []
    offsets.forEach(function (o) { if (offsetAt(wall - o) === o) found.push(wall - o) })
    return found.length ? Math.min.apply(null, found) : wall - offsets[0]
  }

  return { offsetAt: offsetAt, wallToUtc: wallToUtc }
}

// The zones a calendar's VTIMEZONEs define, by their TZID.
function zonesOf(calendar) {
  var out = {}
  calendar.components.forEach(function (c) {
    if (c.name !== "VTIMEZONE") return
    var id = text(c, "TZID")
    var zone = id ? zoneOf(c) : null
    if (zone) out[id] = zone
  })
  return out
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
