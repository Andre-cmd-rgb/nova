// What the Displays page offers for each display, from `nova monitor list
// --json`: its resolutions and the rates of each, its scales in percent, its
// rotation, where it sits next to another, the arrangement drawn small, and
// the clock on a change not kept yet.

var rotations = [
  { value: "0", label: "Normal" },
  { value: "90", label: "90°" },
  { value: "180", label: "180°" },
  { value: "270", label: "270°" }
]

var places = [
  { value: "left-of", label: "Left" },
  { value: "right-of", label: "Right" },
  { value: "above", label: "Above" },
  { value: "below", label: "Below" }
]

// Each display's name in the page: its make and model, with its connector
// where two are the same model.
function labels(displays) {
  var count = {}
  var out = {}
  ;(displays || []).forEach(function (d) { count[d.label] = (count[d.label] || 0) + 1 })
  ;(displays || []).forEach(function (d) { out[d.name] = count[d.label] > 1 ? d.label + " (" + d.name + ")" : d.label })
  return out
}

// "3840x2400" for each resolution, in the order nova monitor lists the modes:
// widest first.
function resolutions(modes) {
  var seen = {}
  var out = []
  ;(modes || []).forEach(function (m) {
    var value = m.width + "x" + m.height
    if (seen[value]) return
    seen[value] = true
    out.push({ value: value, label: m.width + " × " + m.height })
  })
  return out
}

// 60 Hz, but 59.95 Hz: a display offering both means them as two.
function hz(refresh) {
  var whole = Math.round(refresh)
  return (Math.abs(refresh - whole) < 0.02 ? whole : Math.round(refresh * 100) / 100) + " Hz"
}

// The rates at <resolution>, fastest first, each the mode to ask for.
function rates(modes, resolution) {
  return (modes || []).filter(function (m) { return m.width + "x" + m.height === resolution })
    .sort(function (a, b) { return b.refresh - a.refresh })
    .map(function (m) { return { value: m.mode, label: hz(m.refresh), refresh: m.refresh } })
}

// The mode at <resolution> that runs at <refresh>, or "" when none does.
function rateValue(modes, resolution, refresh) {
  var at = rates(modes, resolution)
  for (var i = 0; i < at.length; i++) {
    if (Math.abs(at[i].refresh - refresh) < 0.02) return at[i].value
  }
  return ""
}

// The mode a new resolution is asked for in: at the rate the display runs at
// now where it has it there, else at the fastest.
function modeAt(modes, resolution, refresh) {
  var same = rateValue(modes, resolution, refresh)
  if (same !== "") return same
  var at = rates(modes, resolution)
  return at.length > 0 ? at[0].value : ""
}

function percent(scale) {
  return Math.round(scale * 100) + "%"
}

// The scale offered that the display is at, or its own where none is: a
// scale set in monitors.lua need not be one of the page's.
function scaleValue(scales, current) {
  var near = (scales || []).filter(function (s) { return Math.abs(s - current) < 0.005 })
  return String(near.length > 0 ? near[0] : current)
}

function scaleOptions(scales, current) {
  var list = (scales || []).slice()
  if (!list.some(function (s) { return Math.abs(s - current) < 0.005 })) {
    list.push(current)
    list.sort(function (a, b) { return a - b })
  }
  return list.map(function (s) { return { value: String(s), label: percent(s) } })
}

// Hyprland's transforms 0 to 3 are the turns; 4 to 7, flipped, are none of
// the page's.
function rotation(transform) {
  return transform >= 0 && transform <= 3 ? rotations[transform].value : ""
}

// Where <a> sits next to <b>, as `nova monitor set <a> position` takes it, or
// "" where they overlap.
function relation(a, b) {
  if (!a || !b) return ""
  if (a.x + a.logicalWidth <= b.x) return "left-of"
  if (a.x >= b.x + b.logicalWidth) return "right-of"
  if (a.y + a.logicalHeight <= b.y) return "above"
  if (a.y >= b.y + b.logicalHeight) return "below"
  return ""
}

// The display named, among <list>, or the first.
function pick(list, name) {
  var found = (list || []).filter(function (d) { return d.name === name })
  return found.length > 0 ? found[0] : ((list || [])[0] || null)
}

// The displays that are on, as they are arranged, fitted into a box of
// <width> by <height> and centred in it.
function layout(displays, width, height) {
  var shown = (displays || []).filter(function (d) { return d.enabled && d.logicalWidth > 0 && d.logicalHeight > 0 })
  if (shown.length === 0 || width <= 0 || height <= 0) return []
  var left = Math.min.apply(null, shown.map(function (d) { return d.x }))
  var top = Math.min.apply(null, shown.map(function (d) { return d.y }))
  var right = Math.max.apply(null, shown.map(function (d) { return d.x + d.logicalWidth }))
  var bottom = Math.max.apply(null, shown.map(function (d) { return d.y + d.logicalHeight }))
  var f = Math.min(width / (right - left), height / (bottom - top))
  var ox = (width - (right - left) * f) / 2
  var oy = (height - (bottom - top) * f) / 2
  return shown.map(function (d) {
    return {
      name: d.name, focused: d.focused === true,
      x: ox + (d.x - left) * f, y: oy + (d.y - top) * f,
      width: d.logicalWidth * f, height: d.logicalHeight * f
    }
  })
}

// Whole seconds until <until> (epoch seconds), from <nowMs>.
function secondsLeft(until, nowMs) {
  return Math.max(0, Math.ceil(until - nowMs / 1000))
}

function countdown(seconds) {
  if (seconds <= 0) return "Going back…"
  return "Going back in " + seconds + (seconds === 1 ? " second." : " seconds.")
}
