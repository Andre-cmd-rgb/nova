.pragma library

// The arithmetic of a border: a colour as a theme writes it, a width list as
// CSS writes it, and the outline of a border round a box with rounded
// corners, each side of its own width, as SVG path text for a Shape.

// ---------------------------------------------------------------- colours

// The forms of a colour a theme can write, Hyprland's own among them, so a
// border can be copied from the compositor's config as it is. Each reads a
// match into channels of 0 to 255 and an opacity of 0 to 1.
function hexPairs(digits) {
  return [0, 2, 4].map(function(at) { return parseInt(digits.substr(at, 2), 16) })
}

function byte(text) {
  return Math.max(0, Math.min(255, Math.round(Number(text))))
}

var colorForms = [
  { pattern: /^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$/,
    read: function(m) { return [hexPairs(m[1] + m[1] + m[2] + m[2] + m[3] + m[3]), 1] } },
  { pattern: /^#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?$/,
    read: function(m) { return [hexPairs(m[1]), m[2] ? parseInt(m[2], 16) / 255 : 1] } },
  { pattern: /^rgb\(([0-9A-Fa-f]{6})\)$/i,
    read: function(m) { return [hexPairs(m[1]), 1] } },
  { pattern: /^rgba\(([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})\)$/i,
    read: function(m) { return [hexPairs(m[1]), parseInt(m[2], 16) / 255] } },
  { pattern: /^rgb\(([0-9]+),([0-9]+),([0-9]+)\)$/i,
    read: function(m) { return [[byte(m[1]), byte(m[2]), byte(m[3])], 1] } },
  { pattern: /^rgba\(([0-9]+),([0-9]+),([0-9]+),([0-9.]+)\)$/i,
    read: function(m) { return [[byte(m[1]), byte(m[2]), byte(m[3])], unit(m[4])] } },
  // Hyprland's 0xaarrggbb.
  { pattern: /^0x([0-9A-Fa-f]{2})([0-9A-Fa-f]{6})$/,
    read: function(m) { return [hexPairs(m[2]), parseInt(m[1], 16) / 255] } }
]

// A number from 0 to 1; anything that is not a number is 0.
function unit(value) {
  var n = Number(value)
  return isFinite(n) ? Math.max(0, Math.min(1, n)) : 0
}

// <value> as a colour, at its own opacity times <opacity> (1 when not
// given), the alpha rounded to a byte. Text that is none of the forms, a
// colour's name or a role, comes back as it was, trimmed.
function canonicalColor(value, opacity) {
  var scale = opacity === undefined || opacity === null ? 1 : unit(opacity)
  var text = String(value || "").trim()
  for (var i = 0; i < colorForms.length; i++) {
    var m = colorForms[i].pattern.exec(text)
    if (!m) continue
    var read = colorForms[i].read(m)
    var rgb = read[0]
    return Qt.rgba(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, byte(read[1] * scale * 255) / 255)
  }
  return text
}

// ---------------------------------------------------------------- widths

// Widths from a CSS-style list: "all", "vertical horizontal", "top
// horizontal bottom" or "top right bottom left", each at least 0. No value,
// or one with no number in it, is <fallback> all round.
function parseWidthSpec(value, fallback) {
  var spare = Number(fallback)
  if (!isFinite(spare) || spare < 0) spare = 0
  var given = value === undefined || value === null || value === "" ? [] : String(value).match(/-?\d+(?:\.\d+)?/g) || []
  var list = given.slice(0, 4).map(function(word) {
    var n = Number(word)
    return isFinite(n) && n > 0 ? n : 0
  })
  if (list.length === 0) list = [spare]
  var n = list.length
  return { top: list[0], right: list[n > 1 ? 1 : 0], bottom: list[n > 2 ? 2 : 0], left: list[n > 3 ? 3 : n > 1 ? 1 : 0] }
}

function maxWidth(widths) {
  return widths ? Math.max(widths.top || 0, widths.right || 0, widths.bottom || 0, widths.left || 0) : 0
}

// ---------------------------------------------------------------- outlines
//
// A box's corners go clockwise from the top right: 0 top right, 1 bottom
// right, 2 bottom left, 3 top left. Side n runs into corner n: 0 is the top,
// 1 the right, 2 the bottom and 3 the left. A corner's arc goes, clockwise,
// from where the side before it ends to where the side after it starts.

// The corners of a <w> by <h> box at <x>, <y>, each [rx, ry] in <radii>
// (clockwise from the top right), shrunk all by one factor where two along
// a side would overlap, as CSS shrinks them.
function corners(x, y, w, h, radii) {
  var r = radii.map(function(pair) { return [Math.max(0, Number(pair[0]) || 0), Math.max(0, Number(pair[1]) || 0)] })
  var factor = 1
  ;[[w, r[3][0] + r[0][0]], [w, r[2][0] + r[1][0]], [h, r[3][1] + r[2][1]], [h, r[0][1] + r[1][1]]].forEach(function(side) {
    if (side[1] > side[0] && side[1] > 0) factor = Math.min(factor, side[0] / side[1])
  })
  if (factor < 1) r = r.map(function(pair) { return [pair[0] * factor, pair[1] * factor] })
  var right = x + w
  var bottom = y + h
  return [
    { rx: r[0][0], ry: r[0][1], from: [right - r[0][0], y], to: [right, y + r[0][1]] },
    { rx: r[1][0], ry: r[1][1], from: [right, bottom - r[1][1]], to: [right - r[1][0], bottom] },
    { rx: r[2][0], ry: r[2][1], from: [x + r[2][0], bottom], to: [x, bottom - r[2][1]] },
    { rx: r[3][0], ry: r[3][1], from: [x, y + r[3][1]], to: [x + r[3][0], y] }
  ]
}

// Round <corner> to <point>, clockwise or back: an arc, or a straight line
// where the corner is square.
function turn(corner, clockwise, point) {
  if (corner.rx > 0 && corner.ry > 0) return ["A", corner.rx, corner.ry, 0, 0, clockwise ? 1 : 0, point[0], point[1]]
  return ["L", point[0], point[1]]
}

// The whole box, clockwise from the top side's start, the sides as H and V.
function box(c) {
  var path = ["M", c[3].to[0], c[3].to[1]]
  c.forEach(function(corner, side) {
    path = path.concat(side % 2 === 0 ? ["H", corner.from[0]] : ["V", corner.from[1]], turn(corner, true, corner.to))
  })
  return path.concat("Z")
}

// Along <order>'s corners, clockwise: to each corner's start, and round it.
function forward(c, order, lead) {
  var path = []
  order.forEach(function(n, i) { path = path.concat(i === 0 ? lead : "L", c[n].from, turn(c[n], true, c[n].to)) })
  return path
}

// Along <order>'s corners, counter-clockwise: to each corner's end, and back
// round it.
function backward(c, order, lead) {
  var path = []
  order.forEach(function(n, i) { path = path.concat(i === 0 ? lead : "L", c[n].to, turn(c[n], false, c[n].from)) })
  return path
}

// The outline of a border <widths> wide round a <w> by <h> box with corners
// of <radius>, as closed paths to fill by winding. All four sides make one
// path: the box, and the inner edge backwards inside it, which leaves the
// hole. Fewer make a band for each run of sides in a row, so a side with no
// width draws nothing along it, even at a rounded corner. Where the inner
// edge cannot keep its corners inside the box, the box is filled whole
// rather than risk painting outside it.
function borderPaths(w, h, radius, widths) {
  w = Math.max(0, Number(w) || 0)
  h = Math.max(0, Number(h) || 0)
  radius = Math.max(0, Number(radius) || 0)
  var wide = widths || {}
  var sides = [wide.top, wide.right, wide.bottom, wide.left].map(function(n) { return Math.max(0, Number(n) || 0) })
  var drawn = sides.map(function(n) { return n > 0 })
  if (w <= 0 || h <= 0 || drawn.indexOf(true) === -1) return []

  var outer = corners(0, 0, w, h, [[radius, radius], [radius, radius], [radius, radius], [radius, radius]])
  var whole = box(corners(0, 0, w, h, outer.map(function(c) { return [c.rx, c.ry] }))).join(" ")
  var top = sides[0], right = sides[1], bottom = sides[2], left = sides[3]
  var innerWidth = w - left - right
  var innerHeight = h - top - bottom
  if (innerWidth <= 0 || innerHeight <= 0) return [whole]

  // An inner corner is the outer one less the widths of the sides it joins.
  var cut = [[right, top], [right, bottom], [left, bottom], [left, top]]
  var radii = outer.map(function(c, n) { return [Math.max(0, c.rx - cut[n][0]), Math.max(0, c.ry - cut[n][1])] })
  var fits = radii[3][0] + radii[0][0] <= innerWidth && radii[2][0] + radii[1][0] <= innerWidth
    && radii[3][1] + radii[2][1] <= innerHeight && radii[0][1] + radii[1][1] <= innerHeight
  if (!fits) return [whole]
  var inner = corners(left, top, innerWidth, innerHeight, radii)

  if (drawn.indexOf(false) === -1) {
    var hole = backward(inner, [3, 2, 1, 0], "M").concat("L", inner[3].to, "Z")
    return [whole + " " + hole.join(" ")]
  }

  // A run starts at a drawn side after one that is not, and takes in the
  // corners on either side of it.
  var bands = []
  for (var start = 0; start < 4; start++) {
    if (!drawn[start] || drawn[(start + 3) % 4]) continue
    var order = [(start + 3) % 4]
    for (var side = start; drawn[side % 4] && order.length < 5; side++) order.push(side % 4)
    var band = forward(outer, order, "M").concat(backward(inner, order.slice().reverse(), "L"), "Z")
    bands.push(band.join(" "))
  }
  return bands
}

function ringPath(w, h, radius, widths) {
  return borderPaths(w, h, radius, widths).join(" ")
}

// ---------------------------------------------------------------- gradients

// The ends of a linear gradient at <angle> degrees across a <w> by <h> box:
// through its centre, as long as the box is across in that direction, as
// CSS draws one.
function gradientEndpoints(w, h, angle) {
  w = Math.max(1, Number(w) || 1)
  h = Math.max(1, Number(h) || 1)
  var radians = (Number(angle) || 0) * Math.PI / 180
  var dx = Math.cos(radians)
  var dy = Math.sin(radians)
  var reach = (Math.abs(w * dx) + Math.abs(h * dy)) / 2
  return { x1: w / 2 - dx * reach, y1: h / 2 - dy * reach, x2: w / 2 + dx * reach, y2: h / 2 + dy * reach }
}

// A gradient's stops are fixed in number (BorderOverlay has ten): the
// colours spread over the first of them, evenly, and the rest repeat the
// last colour at the far end.
function stopColor(colors, index) {
  if (!colors || colors.length === 0) return "transparent"
  return colors[Math.min(index, colors.length - 1)]
}

function stopPosition(colors, index) {
  var count = colors ? colors.length : 0
  if (count <= 1) return index === 0 ? 0 : 1
  return Math.min(1, index / (count - 1))
}
