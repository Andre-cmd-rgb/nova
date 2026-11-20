.pragma library

// The rules of Settings' Printers page, apart from its QML: what a printer's
// state and reasons say in plain words, how its ink, its paper and its jobs
// read, and how a device found is named. `nova-printers` gives the data
// (IPP's own: printer-state 3 idle, 4 printing, 5 stopped; reasons such as
// media-empty-error, with -error, -warning or -report on the end).

// A reason without its severity: "media-empty-error" is "media-empty".
function keyword(reason) {
  return String(reason).replace(/-(error|warning|report)$/, "")
}

function has(reasons, words) {
  return (reasons || []).some(function (r) { return words.indexOf(keyword(r)) >= 0 })
}

// The job being printed, if any, as a printer's jobs list it (state 5).
function printing(printer) {
  var jobs = printer.jobs || []
  for (var i = 0; i < jobs.length; i++) if (jobs[i].state === 5) return jobs[i]
  return null
}

// What a printer is doing, in a few plain words, and how much it matters:
// tone is "problem" (needs the user), "warning" (will soon), "busy",
// "quiet" (paused, not taking jobs) or "ready".
function status(printer) {
  var reasons = printer.reasons || []
  if (has(reasons, ["offline"])) return { text: "Can’t be reached", tone: "problem" }
  if (has(reasons, ["media-jam"])) return { text: "Paper jam", tone: "problem" }
  if (has(reasons, ["cover-open", "door-open", "interlock-open"])) return { text: "Cover open", tone: "problem" }
  if (has(reasons, ["media-empty", "media-needed"])) return { text: "Out of paper", tone: "problem" }
  if (has(reasons, ["toner-empty", "marker-supply-empty"])) return { text: "Out of ink or toner", tone: "problem" }
  if (has(reasons, ["paused", "moving-to-paused"])) return { text: "Paused", tone: "quiet" }
  if (printer.state === 5) return { text: "Stopped", tone: "problem" }
  if (printer.accepting === false) return { text: "Not accepting documents", tone: "quiet" }
  var low = has(reasons, ["toner-low", "marker-supply-low"]) ? "Low on ink or toner"
    : has(reasons, ["media-low"]) ? "Low on paper" : ""
  if (printer.state === 4) {
    var job = printing(printer)
    var text = job && job.name ? "Printing “" + job.name + "”" : "Printing"
    return { text: low ? text + "  ·  " + low : text, tone: "busy" }
  }
  if (low) return { text: low, tone: "warning" }
  return { text: "Ready", tone: "ready" }
}

// The printer's make and model, and where it is, for under its name.
function kind(printer) {
  var parts = []
  var model = String(printer.model || "").trim()
  var info = String(printer.info || "").trim()
  if (model && model !== "Unknown") parts.push(model)
  else if (info && info !== printer.name) parts.push(info)
  if (printer.location) parts.push(printer.location)
  return parts.join("  ·  ")
}

// A job's state in words: IPP's job-state 3 pending, 4 held, 5 processing,
// 6 stopped.
function jobText(job) {
  if (asksForPassword(job)) return "Asks for a user name and password"
  switch (job.state) {
  case 5: return "Printing"
  case 4: return "On hold"
  case 6: return "Stopped"
  default: return "Waiting"
  }
}

function asksForPassword(job) {
  return (job.reasons || []).some(function (r) { return /authentication|auth-info-required/.test(r) })
}

// ---- ink and toner -----------------------------------------------------------

// What a marker's bar shows: 0 to 100, or -1 when the printer does not say
// (it reports -1 unknown, -2 unavailable, -3 something left).
function levelOf(marker) {
  var level = Number(marker.level)
  return level >= 0 && level <= 100 ? level : -1
}

function levelText(marker) {
  var level = levelOf(marker)
  return level < 0 ? "" : level + "%"
}

// The bar's colour: the marker's own, and the page's foreground where the
// printer gives none or one that is not a colour (several in one cartridge).
function markerColor(marker, fallback) {
  return /^#[0-9a-fA-F]{6}$/.test(marker.color || "") ? marker.color : fallback
}

// Black and the darkest colours vanish on a dark page, and white on a light
// one: the bar is drawn over a track and outlined by the caller; this says
// whether a colour is too close to the background to see without it.
function brightness(color) {
  var n = parseInt(String(color).slice(1), 16)
  return (((n >> 16) & 255) * 299 + ((n >> 8) & 255) * 587 + (n & 255) * 114) / 1000
}

// ---- paper, sides and colour ---------------------------------------------------

// IPP's media keywords for sizes, as "iso_a4_210x297mm" or
// "na_letter_8.5x11in", in a person's words; null for anything else (a
// tray, a type of paper: "auto", "photo", "main").
function paperName(keyword) {
  var m = /^([a-z0-9-]+)_([a-z0-9._-]+)_([0-9.]+)x([0-9.]+)(mm|in)$/.exec(String(keyword))
  if (!m || /borderless/.test(keyword)) return null
  var cls = m[1], name = m[2], w = m[3], h = m[4], unit = m[5]
  if (cls === "iso" || cls === "jis") return /^[a-z]+[0-9]+$/.test(name) ? name.toUpperCase() : null
  if (cls === "na" && /^(letter|legal|ledger|executive|invoice|tabloid)$/.test(name))
    return name.charAt(0).toUpperCase() + name.slice(1)
  if (cls === "na" && /^index-/.test(name)) return name.slice(6).replace("x", "×") + " in"
  // Anything else by its size.
  return w.replace(/\.0+$/, "") + " × " + h.replace(/\.0+$/, "") + " " + (unit === "in" ? "in" : "mm")
}

// The paper sizes a printer takes, in the order it lists them, once each,
// as { value, label }.
function papers(supported) {
  var seen = {}
  var list = []
  var named = {}
  ;(supported || []).forEach(function (keyword) {
    var label = paperName(keyword)
    if (!label || seen[keyword]) return
    seen[keyword] = true
    // Two keywords can share a name (the same size in inches and millimetres):
    // the first stays.
    if (named[label]) return
    named[label] = true
    list.push({ value: keyword, label: label })
  })
  return list.slice(0, 40)
}

var sidesNames = {
  "one-sided": "One-sided",
  "two-sided-long-edge": "Two-sided",
  "two-sided-short-edge": "Two-sided, short edge"
}

// Only a printer that does two sides is asked about them.
function sides(supported) {
  var list = (supported || []).filter(function (s) { return sidesNames[s] })
  var two = list.some(function (s) { return s.indexOf("two-sided") === 0 })
  return two ? list.map(function (s) { return { value: s, label: sidesNames[s] } }) : []
}

var colorNames = { color: "Color", monochrome: "Black and white" }

// Color and black and white, when the printer does both.
function colors(supported) {
  var list = (supported || []).filter(function (c) { return colorNames[c] })
  return list.length > 1 ? list.map(function (c) { return { value: c, label: colorNames[c] } }) : []
}

// A choice's options: the printer's own setting first ("Default (A4)"),
// then each of <choices>.
function withDefault(choices, own) {
  var label = ""
  choices.forEach(function (c) { if (c.value === own) label = c.label })
  var first = { value: "default", label: label ? "Default (" + label + ")" : "Default" }
  return [first].concat(choices)
}

// What a choice is set to, as the dropdown's value.
function chosen(choices, mine) {
  return mine && choices.some(function (c) { return c.value === mine }) ? mine : "default"
}

// ---- rights ---------------------------------------------------------------------

// One plain line for why the controls are off, "" when they are on.
function adminLine(admin) {
  if (!admin || admin.allowed !== false) return ""
  var groups = (admin.groups || []).filter(function (g) { return g !== "root" })
  var group = groups.indexOf("wheel") >= 0 ? "wheel" : groups[0]
  return "Adding, removing and pausing printers is for administrators" + (group ? " (the " + group + " group)" : "") + ". This account is not one."
}

// ---- adding a printer -------------------------------------------------------------

// A printer's name as CUPS has it (no spaces, slashes or number signs) from
// what the device calls itself, not one of <taken>.
function suggestName(device, taken) {
  var base = String(device.info || device.model || "Printer")
    .replace(/[^A-Za-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "").replace(/_+/g, "_")
  if (!base) base = "Printer"
  base = base.slice(0, 40)
  var name = base
  var n = 2
  while ((taken || []).indexOf(name) >= 0) name = base + "_" + n++
  return name
}

// Whether <name> is one CUPS takes.
function validName(name) {
  return /^[^-/#\s][^/#\s]*$/.test(String(name)) && name.length <= 127
}

// How a device found is described under its name.
function deviceText(device) {
  var how = device.driverless ? "Works without a driver"
    : /^usb:/.test(device.uri) ? "USB"
    : /^(socket|lpd|ipp|ipps|http|https|dnssd):/.test(device.uri) ? "Network"
    : ""
  var model = device.model && device.model !== "Unknown" && device.model !== device.info ? device.model : ""
  return [model, how].filter(function (s) { return s }).join("  ·  ")
}

// The devices not yet printers: one a printer was added with is left out, and
// one found twice (a USB printer, and the driverless address ipp-usb gives
// it) stays once, the driverless one. Those that work without a driver come
// first.
function newDevices(devices, printers) {
  var used = {}
  ;(printers || []).forEach(function (p) { used[p.uri] = true })
  var fresh = (devices || []).filter(function (d) { return !used[d.uri] })
  var driverless = {}
  fresh.forEach(function (d) { if (d.driverless) driverless[d.info || d.uri] = true })
  var seen = {}
  var kept = fresh.filter(function (d) {
    var key = d.info || d.uri
    if (!d.driverless && driverless[key]) return false
    if (seen[key + (d.driverless ? "|1" : "|0")]) return false
    seen[key + (d.driverless ? "|1" : "|0")] = true
    return true
  })
  return kept.filter(function (d) { return d.driverless }).concat(kept.filter(function (d) { return !d.driverless }))
}

// The drivers whose names have every word typed, up to <limit>.
function matchingDrivers(drivers, text, limit) {
  var words = String(text).toLowerCase().split(/\s+/).filter(function (w) { return w })
  var out = []
  for (var i = 0; i < (drivers || []).length && out.length < (limit || 100); i++) {
    var name = drivers[i].name.toLowerCase()
    if (words.every(function (w) { return name.indexOf(w) >= 0 })) out.push(drivers[i])
  }
  return out
}

// The driver to offer for a device: IPP Everywhere (-m everywhere) when it
// talks IPP, else the first of the drivers CUPS lists for its make and model
// (the best fit comes first).
function recommended(device, drivers) {
  if (device.driverless) return { id: "everywhere", name: "Works without a driver", driverless: true }
  var best = (drivers || [])[0]
  return best ? { id: best.id, name: best.name, driverless: false } : null
}
