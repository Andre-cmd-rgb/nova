.pragma library

// The ring a border paints when a Rectangle's own border cannot: round a box
// with rounded corners, each side as wide as it likes, and filled along a
// line at any angle. BorderSurface draws it with a Shape: path() is the
// ring's outline as SVG path text, axis() and stops() its gradient.
//
// A box's corners go clockwise from the top right: 0 top right, 1 bottom
// right, 2 bottom left, 3 top left. Side n runs into corner n, so 0 is the
// top, 1 the right, 2 the bottom and 3 the left. A corner's arc goes,
// clockwise, from where the side before it ends to where the side after it
// starts.

var SIDE_NAMES = ["top", "right", "bottom", "left"]

// Which of a list's values each side takes, by the list's length, as CSS
// reads "1", "1 2", "1 2 3" and "1 2 3 4".
var SHORTHAND = [null, [0, 0, 0, 0], [0, 1, 0, 1], [0, 1, 2, 1], [0, 1, 2, 3]]

// <value> as a size: a number from 0 up, and 0 for anything else.
function size(value) {
  return Math.max(0, Number(value) || 0)
}

function positive(word) {
  var n = Number(word)
  return isFinite(n) && n > 0 ? n : 0
}

// ---------------------------------------------------------------- widths

// A side's width each, from a list of up to four numbers in any text
// ("2", "0 4", "1 2 3 4px"), each under 0 made 0. No value, or one with no
// number in it, is <fallback> all round.
function sides(value, fallback) {
  var words = value === undefined || value === null || value === "" ? [] : String(value).match(/-?\d+(?:\.\d+)?/g) || []
  var list = words.length > 0 ? words.slice(0, 4).map(positive) : [positive(fallback)]
  var pick = SHORTHAND[list.length]
  var widths = {}
  SIDE_NAMES.forEach(function(name, n) { widths[name] = list[pick[n]] })
  return widths
}

// The widest side; 0 for no widths at all.
function widest(widths) {
  if (!widths) return 0
  return Math.max.apply(null, SIDE_NAMES.map(function(name) { return widths[name] || 0 }))
}

// ---------------------------------------------------------------- outline

// The four corners of a <w> by <h> box at <x>, <y>, each with its radii
// from <radii> ([rx, ry] each, clockwise from the top right), all shrunk by
// one factor where two along a side would overlap, as CSS shrinks them.
// Each corner knows where its arc starts and ends.
function cornersOf(x, y, w, h, radii) {
  var r = radii.map(function(pair) { return [size(pair[0]), size(pair[1])] })
  var along = [[w, r[3][0] + r[0][0]], [w, r[2][0] + r[1][0]], [h, r[3][1] + r[2][1]], [h, r[0][1] + r[1][1]]]
  var shrink = along.reduce(function(least, pair) {
    return pair[1] > pair[0] && pair[1] > 0 ? Math.min(least, pair[0] / pair[1]) : least
  }, 1)
  if (shrink < 1) r = r.map(function(pair) { return [pair[0] * shrink, pair[1] * shrink] })
  var right = x + w
  var bottom = y + h
  var ends = [
    [[right - r[0][0], y], [right, y + r[0][1]]],
    [[right, bottom - r[1][1]], [right - r[1][0], bottom]],
    [[x + r[2][0], bottom], [x, bottom - r[2][1]]],
    [[x, y + r[3][1]], [x + r[3][0], y]]
  ]
  return ends.map(function(pair, n) { return { rx: r[n][0], ry: r[n][1], from: pair[0], to: pair[1] } })
}

// Path words that go round <corner> to <point>, clockwise or back: an arc,
// or a straight line where the corner is square.
function rounding(corner, clockwise, point) {
  if (corner.rx > 0 && corner.ry > 0) return ["A", corner.rx, corner.ry, 0, 0, clockwise ? 1 : 0, point[0], point[1]]
  return ["L", point[0], point[1]]
}

// The whole box, closed, clockwise from the start of its top side.
function wholeBox(corners) {
  var words = ["M", corners[3].to[0], corners[3].to[1]]
  corners.forEach(function(corner, n) {
    words.push.apply(words, n % 2 === 0 ? ["H", corner.from[0]] : ["V", corner.from[1]])
    words.push.apply(words, rounding(corner, true, corner.to))
  })
  words.push("Z")
  return words
}

// Path words through the corners numbered in <order>, clockwise or back,
// rounding each: the first is reached with <lead> ("M" or "L"), the others
// with a line.
function through(corners, order, clockwise, lead) {
  var words = []
  order.forEach(function(n, i) {
    var corner = corners[n]
    var start = clockwise ? corner.from : corner.to
    var end = clockwise ? corner.to : corner.from
    words.push(i === 0 ? lead : "L", start[0], start[1])
    words.push.apply(words, rounding(corner, clockwise, end))
  })
  return words
}

// The outline of a border <widths> wide round a <w> by <h> box with corners
// of <radius>, as one SVG path text to fill by winding. With all four sides
// it is the box, and inside it the inner edge backwards, which leaves the
// hole. With fewer, each run of sides in a row is a band of its own, so a
// side with no width draws nothing along it, even round a corner. Where the
// inner edge cannot keep its corners inside the box, the whole box is
// filled rather than risk painting outside it.
function path(w, h, radius, widths) {
  var width = size(w)
  var height = size(h)
  var round = size(radius)
  var given = widths || {}
  var across = SIDE_NAMES.map(function(name) { return size(given[name]) })
  var drawn = across.map(function(n) { return n > 0 })
  if (width <= 0 || height <= 0 || drawn.indexOf(true) < 0) return ""

  var outer = cornersOf(0, 0, width, height, [[round, round], [round, round], [round, round], [round, round]])
  var box = wholeBox(cornersOf(0, 0, width, height, outer.map(function(c) { return [c.rx, c.ry] }))).join(" ")
  var top = across[0], right = across[1], bottom = across[2], left = across[3]
  var innerWidth = width - left - right
  var innerHeight = height - top - bottom
  if (innerWidth <= 0 || innerHeight <= 0) return box

  // An inner corner is the outer one less the widths of the two sides it
  // joins.
  var joins = [[right, top], [right, bottom], [left, bottom], [left, top]]
  var radii = outer.map(function(c, n) { return [Math.max(0, c.rx - joins[n][0]), Math.max(0, c.ry - joins[n][1])] })
  var inside = radii[3][0] + radii[0][0] <= innerWidth && radii[2][0] + radii[1][0] <= innerWidth
    && radii[3][1] + radii[2][1] <= innerHeight && radii[0][1] + radii[1][1] <= innerHeight
  if (!inside) return box
  var inner = cornersOf(left, top, innerWidth, innerHeight, radii)

  if (drawn.indexOf(false) < 0) {
    var hole = through(inner, [3, 2, 1, 0], false, "M").concat("L", inner[3].to, "Z")
    return box + " " + hole.join(" ")
  }

  // A run begins at a drawn side after one that is not, and takes in the
  // corner before it and the corner after each of its sides.
  var bands = []
  drawn.forEach(function(on, first) {
    var before = (first + 3) % 4
    if (!on || drawn[before]) return
    var order = [before]
    for (var side = first; drawn[side % 4]; side++) order.push(side % 4)
    var band = through(outer, order, true, "M").concat(through(inner, order.slice().reverse(), false, "L"), "Z")
    bands.push(band.join(" "))
  })
  return bands.join(" ")
}

// ---------------------------------------------------------------- gradient

// The ends of a gradient at <angle> degrees across a <w> by <h> box: through
// its middle, and as long as the box is across in that direction, as CSS
// draws one.
function axis(w, h, angle) {
  var width = Math.max(1, Number(w) || 1)
  var height = Math.max(1, Number(h) || 1)
  var turn = (Number(angle) || 0) * Math.PI / 180
  var dx = Math.cos(turn)
  var dy = Math.sin(turn)
  var reach = (Math.abs(width * dx) + Math.abs(height * dy)) / 2
  var middle = [width / 2, height / 2]
  return { x1: middle[0] - dx * reach, y1: middle[1] - dy * reach, x2: middle[0] + dx * reach, y2: middle[1] + dy * reach }
}

// <count> stops through <colors>: the colours spread evenly over the first
// of them, and the rest repeat the last colour at the far end. No colours
// at all are transparent.
function stops(colors, count) {
  var list = colors && colors.length > 0 ? colors : ["transparent"]
  var last = list.length - 1
  var span = Math.max(1, last)
  var made = []
  for (var i = 0; i < count; i++) made.push({ position: Math.min(1, i / span), color: list[Math.min(i, last)] })
  return made
}
