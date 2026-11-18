.pragma library

// The screen picker's rules, apart from its windows: what is offered, what is
// under a point, a region drawn, and where the keys move the highlight. A
// region is { x, y, w, h } in Hyprland's logical pixels across every screen,
// written "X,Y WxH" as slurp writes one, which is what the picker answers.

// "X,Y WxH" as a region, or null.
function parse(text) {
  var m = /^(-?\d+),(-?\d+) (\d+)x(\d+)$/.exec(String(text).trim())
  return m ? { x: +m[1], y: +m[2], w: +m[3], h: +m[4] } : null
}

function format(r) {
  return r.x + "," + r.y + " " + r.w + "x" + r.h
}

function same(a, b) {
  return !!a && !!b && a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h
}

// What `nova-capture-region --layout` prints, a region a line after its kind
// (focused, monitor, window), as { focused, monitors, windows }.
function layout(text) {
  var out = { focused: null, monitors: [], windows: [] }
  String(text || "").split("\n").forEach(function (line) {
    var at = line.indexOf(" ")
    if (at < 0) return
    var kind = line.slice(0, at), r = parse(line.slice(at + 1))
    if (!r) return
    if (kind === "focused") out.focused = r
    else if (kind === "monitor") out.monitors.push(r)
    else if (kind === "window") out.windows.push(r)
  })
  return out
}

function contains(r, px, py) {
  return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h
}

// Of <regions>, the smallest that the point is in, the first of those the
// same size: a floating window over a tiled one, a window over its monitor.
function under(px, py, regions) {
  var found = null
  for (var i = 0; i < regions.length; i++) {
    var r = regions[i]
    if (!contains(r, px, py)) continue
    if (found && r.w * r.h >= found.w * found.h) continue
    found = r
  }
  return found
}

// What a point offers: the window under it, else the monitor, else nothing.
function offered(lay, px, py) {
  return under(px, py, lay.windows) || under(px, py, lay.monitors)
}

// What RETURN takes: what the point offers, else the focused monitor.
function highlighted(lay, px, py) {
  return (isFinite(px) && isFinite(py) ? offered(lay, px, py) : null) || lay.focused
}

// The region between where a drag began and where it is, whole pixels.
function drawn(ax, ay, bx, by) {
  var x = Math.round(Math.min(ax, bx)), y = Math.round(Math.min(ay, by))
  return { x: x, y: y, w: Math.round(Math.max(ax, bx)) - x, h: Math.round(Math.max(ay, by)) - y }
}

// A press and a release that drew next to nothing: a click.
function isClick(r) {
  return !r || r.w * r.h < 20
}

// The part of <r> on <screen>, or null.
function clip(r, screen) {
  if (!r) return null
  var x = Math.max(r.x, screen.x), y = Math.max(r.y, screen.y)
  var right = Math.min(r.x + r.w, screen.x + screen.w), bottom = Math.min(r.y + r.h, screen.y + screen.h)
  return right > x && bottom > y ? { x: x, y: y, w: right - x, h: bottom - y } : null
}

// ---- the keys ---------------------------------------------------------------

// The points of a window tried for one where it is the window under the
// pointer, in eighths of its width and height: nearest the middle first,
// across and then down at the same distance. Its middle will not do where a
// smaller window covers that.
var EIGHTHS = (function () {
  var rings = []
  for (var i = 1; i <= 7; i++)
    for (var j = 1; j <= 7; j++) {
      var d = (i - 4) * (i - 4) + (j - 4) * (j - 4)
      ;(rings[d] = rings[d] || []).push([i, j])
    }
  var out = []
  rings.forEach(function (ring) { if (ring) out = out.concat(ring) })
  return out
})()

// For each window, a point where it is the one under the pointer, or null
// for one with no such point: covered, it could not be hovered either.
function spots(windows) {
  return windows.map(function (r) {
    for (var k = 0; k < EIGHTHS.length; k++) {
      var sx = r.x + Math.floor(r.w * EIGHTHS[k][0] / 8), sy = r.y + Math.floor(r.h * EIGHTHS[k][1] / 8)
      if (under(sx, sy, windows) === r) return { x: sx, y: sy }
    }
    return null
  })
}

// The windows that can be highlighted, in reading order: down the screen,
// then left to right.
function reading(windows) {
  var at = spots(windows)
  return windows.filter(function (r, i) { return at[i] !== null }).sort(function (a, b) {
    return a.y - b.y || a.x - b.x || (format(a) < format(b) ? -1 : format(a) > format(b) ? 1 : 0)
  })
}

// The window the highlight moves to from <current> (a window, or null) with
// the pointer at px, py: next and prev go round the windows in reading
// order; an arrow (left, right, up, down) goes to the nearest window whose
// middle is that way, a step aside counting double, the first in reading
// order of those as near. From the middle of the window highlighted, or from
// the pointer where none is. Null where there is nowhere to go.
function step(windows, current, px, py, way) {
  var order = reading(windows)
  var n = order.length
  if (n === 0) return null
  var place = -1
  for (var i = 0; i < n; i++) if (same(order[i], current)) place = i
  if (way === "next" || way === "prev") {
    var at = place >= 0 ? place : way === "next" ? -1 : n
    at += way === "next" ? 1 : -1
    return order[((at % n) + n) % n]
  }
  var unit = { left: [-1, 0], right: [1, 0], up: [0, -1], down: [0, 1] }[way]
  if (!unit) return null
  var ox = px, oy = py
  if (current) {
    ox = current.x + Math.floor(current.w / 2)
    oy = current.y + Math.floor(current.h / 2)
  }
  var best = -1, target = null
  for (var k = 0; k < n; k++) {
    var r = order[k]
    if (same(r, current)) continue
    var dx = r.x + Math.floor(r.w / 2) - ox, dy = r.y + Math.floor(r.h / 2) - oy
    var ahead = unit[0] * dx + unit[1] * dy, aside = unit[1] * dx - unit[0] * dy
    if (ahead <= 0) continue
    var score = ahead + 2 * Math.abs(aside)
    if (best < 0 || score < best) {
      best = score
      target = r
    }
  }
  return target
}
