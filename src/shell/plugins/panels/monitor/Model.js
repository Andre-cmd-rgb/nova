.pragma library

// The display panel's rules, apart from its items: what nova-monitor-state
// prints, the scales Hyprland will take for a display, the word for a
// brightness, and where the keys' cursor goes.

// nova-monitor-state's answer, a value a line: the brightness (or
// "unavailable"), four lines the panel does not read, the focused display,
// its scale, and every display as JSON.
function readState(text) {
  var lines = String(text || "").split("\n")
  var line = function(n) { return String(lines[n] || "").trim() }
  var level = line(0)
  var lit = level !== "unavailable" && level !== ""
  var shown = readDisplays(line(7))
  return {
    hasBacklight: lit,
    brightness: lit ? Math.max(0, Math.min(100, parseInt(level, 10))) : 0,
    focused: line(5),
    scale: scaleText(line(6)),
    displays: shown.displays,
    enabled: shown.enabled
  }
}

// The displays' JSON, and how many of them are on. Anything but a list
// reads as none.
function readDisplays(json) {
  var list
  try {
    list = json ? JSON.parse(String(json)) : []
  } catch (e) {
    list = []
  }
  if (!Array.isArray(list)) list = []
  var on = list.filter(function(d) { return d && d.enabled }).length
  return { displays: list, enabled: on }
}

// The icon of one display, and of two or more.
function screensIcon(count) {
  return count > 1 ? "󰍺" : "󰍹"
}

// A brightness the panel sets: a whole percent from 1 to 100; 1 for
// anything not a number.
function percent(value) {
  var n = Number(value)
  return isFinite(n) ? Math.max(1, Math.min(100, Math.round(n))) : 1
}

// A scale as the panel writes it, to two places at most ("1.25", "2");
// empty for anything not a number.
function scaleText(scale) {
  var n = parseFloat(String(scale || ""))
  return isFinite(n) ? String(Math.round(n * 100) / 100) : ""
}

function gcd(a, b) {
  while (b) {
    var r = a % b
    a = b
    b = r
  }
  return a
}

// The scale Hyprland gives a <width> by <height> mode when <scale> is asked
// for. It counts in 120ths and takes only a scale that divides both sides
// into whole pixels, so the nearest such one at or above the one asked
// for. Empty when any of the three is not a number above 0.
function snapScale(scale, width, height) {
  var s = Number(scale)
  var w = Number(width)
  var h = Number(height)
  if (!(isFinite(s) && isFinite(w) && isFinite(h) && s > 0 && w > 0 && h > 0)) return ""
  var whole = gcd(Math.round(w * 120), Math.round(h * 120))
  var units = Math.min(Math.round(s * 120), whole)
  while (whole % units !== 0) units++
  return scaleText(units / 120)
}

// <presets> as a display of <width> by <height> takes them: each scale it
// ends up at once, by the preset closest to it, in the presets' order.
function scalesFor(presets, width, height) {
  if (Number(width) <= 0 || Number(height) <= 0) return presets
  var best = {}
  presets.forEach(function(preset, index) {
    var asked = Number(preset)
    var given = Number(snapScale(asked, width, height))
    if (!isFinite(asked) || !isFinite(given)) return
    var key = scaleText(given)
    var off = Math.abs(asked - given)
    if (!best[key] || off < best[key].off) best[key] = { value: String(preset), index: index, off: off }
  })
  return Object.keys(best)
    .map(function(key) { return best[key] })
    .sort(function(a, b) { return a.index - b.index })
    .map(function(pick) { return pick.value })
}

// Which of <scales> the display is at: of those that land on <current>,
// the closest; -1 for none.
function scaleIndex(scales, current, width, height) {
  var now = Number(current)
  if (!isFinite(now)) return -1
  var want = scaleText(now)
  var found = -1
  var nearest = Infinity
  scales.forEach(function(s, i) {
    if (snapScale(s, width, height) !== want) return
    var off = Math.abs(Number(s) - now)
    if (off < nearest) {
      found = i
      nearest = off
    }
  })
  return found
}

// A brightness in words, a band of ten to twenty points each, so a small
// nudge keeps the word and a real change finds a new one.
var moods = [[95, "Sun blast"], [80, "Solar flare"], [65, "Golden hour"], [45, "Even day"],
  [30, "Soft glow"], [20, "Lamp light"], [10, "Candlelit"]]

function mood(value) {
  var p = Math.round(value)
  for (var i = 0; i < moods.length; i++) {
    if (p >= moods[i][0]) return moods[i][1]
  }
  return "Night owl"
}

// The index of the stop in <stops> nearest <px>, the first on a tie.
function nearestStop(stops, px) {
  var found = 0
  var nearest = 1e9
  stops.forEach(function(stop, i) {
    var off = Math.abs(stop - px)
    if (off < nearest) {
      nearest = off
      found = i
    }
  })
  return found
}

// What hyprctl eval takes to turn the display <name> off (<on>, it is on
// now) or back on, as Hyprland picks.
function displayCall(name, on) {
  var output = '"' + name.replace(/[\\"]/g, "\\$&") + '"'
  return on
    ? 'hl.monitor({ output = ' + output + ', disabled = true })'
    : 'hl.monitor({ output = ' + output + ', disabled = false, mode = "preferred", position = "auto", scale = "auto" })'
}

// ---------------------------------------------------------------- cursor

// The keys' cursor is a section and an index in it. A slider (the
// brightness, the text size) is one stop at index -1; the scale presets
// are one stop for j and k, walked by h and l; each display is a stop of
// its own. <counts> gives the scale presets and the displays.

// The sections shown, top to bottom: the brightness only with a backlight
// to set, the displays only when there are two or more.
function sections(hasBacklight, displayCount) {
  var list = hasBacklight ? ["brightness"] : []
  list.push("textsize", "scale")
  if (displayCount > 1) list.push("monitors")
  return list
}

function isSlider(section) {
  return section === "brightness" || section === "textsize"
}

function oneStop(section) {
  return isSlider(section) || section === "scale"
}

function entry(section) {
  return isSlider(section) ? -1 : 0
}

function rows(section, counts) {
  if (section === "scale") return counts.scale
  if (section === "monitors") return counts.monitors
  return 0
}

function at(section, index) {
  return { section: section, index: index }
}

// j (<delta> 1) or k (-1): the next stop down or up, into the next section
// at a section's end; the last display coming up into the displays.
function move(cursor, delta, list, counts) {
  var here = list.indexOf(cursor.section)
  if (here < 0) return at(list[0], entry(list[0]))
  var inside = !oneStop(cursor.section)
  if (delta > 0) {
    if (inside && cursor.index < rows(cursor.section, counts) - 1) return at(cursor.section, cursor.index + 1)
    if (here < list.length - 1) return at(list[here + 1], entry(list[here + 1]))
  } else {
    if (inside && cursor.index > 0) return at(cursor.section, cursor.index - 1)
    if (here > 0) {
      var above = list[here - 1]
      return at(above, oneStop(above) ? entry(above) : rows(above, counts) - 1)
    }
  }
  return cursor
}

// h or l along the scale presets, held at either end.
function along(index, delta, count) {
  var next = Math.max(0, index + delta)
  return next > count - 1 ? count - 1 : next
}

// The cursor kept on something shown once sections or rows come or go.
function clamp(cursor, list, counts) {
  var here = list.indexOf(cursor.section)
  if (here < 0) return at(list[0], entry(list[0]))
  var count = rows(cursor.section, counts)
  if (isSlider(cursor.section)) return at(cursor.section, -1)
  if (cursor.section === "scale") return cursor.index < 0 || cursor.index >= count ? at("scale", 0) : cursor
  if (count === 0) {
    var to = here > 0 ? list[here - 1] : list[0]
    return at(to, entry(to))
  }
  return at(cursor.section, Math.max(0, Math.min(count - 1, cursor.index)))
}
