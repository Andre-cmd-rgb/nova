.pragma library

// The display panel's rules, apart from its items: what nova-monitor-state
// prints, the scales Hyprland will take for a display, the word for a
// brightness, and where the keys' cursor goes.

// nova-monitor-state's answer, a value a line: the brightness (or
// "unavailable"), four lines the panel does not read, the focused display,
// its scale, and every display as JSON.
function readState(text) {
  const [level, , , , , focused, scale, displays] = String(text || "").split("\n").map(line => line.trim())
  const lit = !!level && level !== "unavailable"
  const shown = readDisplays(displays || "")
  return {
    hasBacklight: lit,
    brightness: lit ? Math.max(0, Math.min(100, parseInt(level, 10))) : 0,
    focused: focused || "",
    scale: scaleText(scale || ""),
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
  const value = scale ? parseFloat(String(scale)) : NaN
  return isFinite(value) ? String(Math.round(value * 100) / 100) : ""
}

// The greatest whole number that divides both, by Euclid's steps.
function gcd(a, b) {
  return b ? gcd(b, a % b) : a
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
  const closest = new Map()
  presets.forEach((preset, index) => {
    const asked = Number(preset)
    const given = Number(snapScale(asked, width, height))
    if (!isFinite(asked) || !isFinite(given)) return
    const off = Math.abs(asked - given)
    const key = scaleText(given)
    if (!closest.has(key) || off < closest.get(key).off) closest.set(key, { value: String(preset), index, off })
  })
  return Array.from(closest.values()).sort((one, other) => one.index - other.index).map(pick => pick.value)
}

// Which of <scales> the display is at: of those that land on <current>,
// the closest; -1 for none.
function scaleIndex(scales, current, width, height) {
  const now = Number(current)
  const lands = scale => snapScale(scale, width, height) === scaleText(now)
  return isFinite(now) ? nearestIndex(scales, scale => lands(scale) ? Math.abs(Number(scale) - now) : NaN, -1) : -1
}

// The index of the item of <list> nearest by <offOf>, the first on a tie;
// an item it gives NaN for is not in the running, and <none> is for none.
function nearestIndex(list, offOf, none) {
  return list.reduce((best, item, index) => {
    const off = offOf(item)
    return off < best.off ? { index, off } : best
  }, { index: none, off: Infinity }).index
}

// The line under "Display": the brightness, from 0 to 100.
function note(value) {
  return "Brightness " + Math.max(0, Math.min(100, Math.round(value))) + "%"
}

// The index of the stop in <stops> nearest <px>, the first on a tie; the
// first for none.
function nearestStop(stops, px) {
  return nearestIndex(stops, stop => Math.abs(stop - px), 0)
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
// A section left with no rows gives the cursor to the one above it.
function clamp(cursor, list, counts) {
  const here = list.indexOf(cursor.section)
  const count = rows(cursor.section, counts)
  const startOf = section => at(section, entry(section))
  if (here < 0) return startOf(list[0])
  if (isSlider(cursor.section)) return at(cursor.section, -1)
  if (cursor.section === "scale") return cursor.index >= 0 && cursor.index < count ? cursor : at("scale", 0)
  return count > 0 ? at(cursor.section, Math.max(0, Math.min(count - 1, cursor.index))) : startOf(list[Math.max(0, here - 1)])
}
