.pragma library

// The arithmetic behind a border: colours as themes write them, width lists
// as CSS writes them, and the outline of a border whose sides each have their
// own width, round a box with rounded corners, as an SVG path for a Shape.
//
// Widths are { top, right, bottom, left }. A spec, as Border hands them out,
// is { color, widths, gradient: { colors, angle, enabled } }.

function clamp(value, min, max) {
  var n = Number(value)
  return isFinite(n) ? Math.max(min, Math.min(max, n)) : min
}

function clampAlpha(value) {
  return clamp(value, 0, 1)
}

// A channel of 0 to 255 as two hex digits.
function padHex(value) {
  var digits = clamp(Math.round(Number(value)), 0, 255).toString(16)
  return digits.length === 1 ? "0" + digits : digits
}

// A colour from six hex digits, with or without "#", and an alpha of 0 to
// 255. Outside QML, or with fewer than six digits, the colour as hex text.
function qmlHexColor(rgb, alphaByte) {
  var digits = String(rgb || "").replace(/^#/, "")
  var alpha = clamp(Math.round(Number(alphaByte)), 0, 255)
  if (typeof Qt !== "undefined" && Qt.rgba && digits.length >= 6) {
    var channel = function(at) { return parseInt(digits.substring(at, at + 2), 16) / 255 }
    return Qt.rgba(channel(0), channel(2), channel(4), alpha / 255)
  }
  var alphaDigits = padHex(alpha)
  return alphaDigits === "ff" ? "#" + digits : "#" + digits + alphaDigits
}

// The ways a theme writes a colour, each read into hex digits and an alpha
// byte with the caller's <scale> applied. Hyprland's own forms are among them,
// so a border can be copied from the compositor's config as it is.
var colorForms = [
  // #rgb
  [/^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$/, function(m, scale) {
    return qmlHexColor(m[1] + m[1] + m[2] + m[2] + m[3] + m[3], scale * 255)
  }],
  // #rrggbb, #rrggbbaa
  [/^#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?$/, function(m, scale) {
    return qmlHexColor(m[1], (m[2] ? parseInt(m[2], 16) / 255 : 1) * scale * 255)
  }],
  // rgb(rrggbb)
  [/^rgb\(([0-9A-Fa-f]{6})\)$/i, function(m, scale) {
    return qmlHexColor(m[1], scale * 255)
  }],
  // rgba(rrggbbaa)
  [/^rgba\(([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})\)$/i, function(m, scale) {
    return qmlHexColor(m[1], (parseInt(m[2], 16) / 255) * scale * 255)
  }],
  // rgb(r,g,b)
  [/^rgb\(([0-9]+),([0-9]+),([0-9]+)\)$/i, function(m, scale) {
    return qmlHexColor(padHex(m[1]) + padHex(m[2]) + padHex(m[3]), scale * 255)
  }],
  // rgba(r,g,b,a), a from 0 to 1
  [/^rgba\(([0-9]+),([0-9]+),([0-9]+),([0-9.]+)\)$/i, function(m, scale) {
    return qmlHexColor(padHex(m[1]) + padHex(m[2]) + padHex(m[3]), clampAlpha(m[4]) * scale * 255)
  }],
  // 0xaarrggbb
  [/^0x([0-9A-Fa-f]{2})([0-9A-Fa-f]{6})$/, function(m, scale) {
    return qmlHexColor(m[2], (parseInt(m[1], 16) / 255) * scale * 255)
  }]
]

// <value> as a colour, its alpha times <alpha> (1 when not given). What is
// none of the forms above, a name or a role, comes back as it was, trimmed.
function canonicalColor(value, alpha) {
  var scale = alpha === undefined || alpha === null ? 1 : clampAlpha(alpha)
  var text = String(value || "").trim()
  for (var i = 0; i < colorForms.length; i++) {
    var m = text.match(colorForms[i][0])
    if (m) return colorForms[i][1](m, scale)
  }
  return text
}

// Widths from a CSS-style list: "all", "vertical horizontal", "top
// horizontal bottom" or "top right bottom left". A number that is not above
// zero is 0. No value, or one with no number in it, is <fallback> all round.
function parseWidthSpec(value, fallback) {
  var fallbackWidth = Number(fallback)
  if (!isFinite(fallbackWidth) || fallbackWidth < 0) fallbackWidth = 0
  if (value === undefined || value === null || value === "")
    return { top: fallbackWidth, right: fallbackWidth, bottom: fallbackWidth, left: fallbackWidth }

  var listed = (String(value).match(/-?\d+(?:\.\d+)?/g) || []).slice(0, 4).map(function(part) {
    var n = Number(part)
    return isFinite(n) && n > 0 ? n : 0
  })
  if (listed.length === 0) listed = [fallbackWidth]
  var top = listed[0]
  var right = listed.length > 1 ? listed[1] : top
  var bottom = listed.length > 2 ? listed[2] : top
  var left = listed.length > 3 ? listed[3] : right
  return { top: top, right: right, bottom: bottom, left: left }
}

// <widths> with each side given a value of its own replaced by it, at least
// 0. A side given nothing (undefined, null, "") keeps its width.
function withSideOverrides(widths, top, right, bottom, left) {
  var base = widths || {}
  function side(override, width) {
    if (override === undefined || override === null || override === "") return Number(width) || 0
    return Math.max(0, Number(override) || 0)
  }
  return {
    top: side(top, base.top),
    right: side(right, base.right),
    bottom: side(bottom, base.bottom),
    left: side(left, base.left),
  }
}

// "<colour> <colour> ... [<angle>deg]", Hyprland's way of writing a gradient,
// with every colour at <alpha>. With no colour in it, <fallbackColor> stands
// alone, if there is one; one colour is not a gradient.
function parseGradientSpec(value, fallbackColor, alpha) {
  var text = String(value || "").trim()
  var colors = []
  var angle = 0
  if (text.length > 0) {
    text.split(/\s+/).forEach(function(part) {
      var degrees = part.match(/^(-?\d+(?:\.\d+)?)deg$/)
      if (degrees) angle = Number(degrees[1])
      else colors.push(canonicalColor(part, alpha))
    })
  }
  if (colors.length === 0 && fallbackColor !== undefined && fallbackColor !== null)
    colors.push(canonicalColor(fallbackColor, alpha))
  return { colors: colors, angle: isFinite(angle) ? angle : 0, enabled: colors.length > 1 }
}

function isUniform(widths) {
  return !widths || (widths.top === widths.right && widths.top === widths.bottom && widths.top === widths.left)
}

function maxWidth(widths) {
  if (!widths) return 0
  return Math.max(widths.top || 0, widths.right || 0, widths.bottom || 0, widths.left || 0)
}

// Rectangle.border draws one colour at one width; anything more, a gradient or
// sides of different widths, takes the drawn outline (BorderOverlay).
function needsOverlay(spec) {
  if (!spec || maxWidth(spec.widths) <= 0) return false
  return !!(spec.gradient && spec.gradient.enabled) || !isUniform(spec.widths)
}

function canUseNative(spec) {
  return !!spec && maxWidth(spec.widths) > 0 && !needsOverlay(spec)
}

// ---------------------------------------------------------------- outlines
//
// Corners are { rx, ry }. A box's outline is walked clockwise from its top
// edge; side 0 is the top, 1 the right, 2 the bottom and 3 the left, and the
// corner of a side is the one its edge runs into: the top's is the top right.

// The corner radii of <r> (tlrx, tlry, trrx, ... blry) for a <w> by <h> box:
// none below 0, and all shrunk by one factor where two along an edge would
// overlap, as CSS shrinks them.
function normalizeRadii(w, h, r) {
  function corner(rx, ry) { return { rx: Math.max(0, Number(rx) || 0), ry: Math.max(0, Number(ry) || 0) } }
  var tl = corner(r.tlrx, r.tlry)
  var tr = corner(r.trrx, r.trry)
  var br = corner(r.brrx, r.brry)
  var bl = corner(r.blrx, r.blry)

  var factor = 1
  function fit(length, along) {
    if (along > length && along > 0) factor = Math.min(factor, length / along)
  }
  fit(w, tl.rx + tr.rx)
  fit(w, bl.rx + br.rx)
  fit(h, tl.ry + bl.ry)
  fit(h, tr.ry + br.ry)
  if (factor < 1) {
    ;[tl, tr, br, bl].forEach(function(c) { c.rx *= factor })
    ;[tl, tr, br, bl].forEach(function(c) { c.ry *= factor })
  }
  return { tl: tl, tr: tr, br: br, bl: bl }
}

// An arc to <point>, or a straight line where the corner is square.
function appendArc(path, rx, ry, sweep, point) {
  if (rx > 0 && ry > 0) path.push("A", rx, ry, 0, 0, sweep, point.x, point.y)
  else path.push("L", point.x, point.y)
}

// A box with rounded corners, <radii> as normalizeRadii takes them.
function roundedRectPath(x, y, w, h, radii) {
  if (w <= 0 || h <= 0) return ""
  var box = borderBoundary(x, y, w, h, normalizeRadii(w, h, radii))
  var path = ["M", box.start[0].x, box.start[0].y]
  var horizontal = true
  for (var side = 0; side < 4; side++) {
    // Each edge runs along one axis, so its end shares a coordinate with
    // where it starts: H or V gives the other.
    path.push(horizontal ? "H" : "V", horizontal ? box.end[side].x : box.end[side].y)
    appendForwardCorner(path, box, side)
    horizontal = !horizontal
  }
  path.push("Z")
  return path.join(" ")
}

// Where each side's straight edge of a box starts and ends, clockwise, and the
// corner after each. <radii> is either normalizeRadii's answer or the radii it
// takes.
function borderBoundary(x, y, w, h, radii) {
  var r = radii && radii.tl ? radii : normalizeRadii(w, h, radii)
  var right = x + w
  var bottom = y + h
  return {
    start: [
      { x: x + r.tl.rx, y: y },
      { x: right, y: y + r.tr.ry },
      { x: right - r.br.rx, y: bottom },
      { x: x, y: bottom - r.bl.ry },
    ],
    end: [
      { x: right - r.tr.rx, y: y },
      { x: right, y: bottom - r.br.ry },
      { x: x + r.bl.rx, y: bottom },
      { x: x, y: y + r.tl.ry },
    ],
    corner: [r.tr, r.br, r.bl, r.tl],
  }
}

// Clockwise round the corner after <side>, to where the next side starts.
function appendForwardCorner(path, boundary, side) {
  var corner = boundary.corner[side]
  appendArc(path, corner.rx, corner.ry, 1, boundary.start[(side + 1) % 4])
}

// Counter-clockwise round the corner after <side>, from the next side back to
// where <side> ends.
function appendReverseCorner(path, boundary, side) {
  var corner = boundary.corner[side]
  appendArc(path, corner.rx, corner.ry, 0, boundary.end[side])
}

// The box counter-clockwise from the top edge's start: inside a clockwise
// outline, under winding fill, the hole of a ring.
function reverseBoundaryPath(boundary) {
  var path = ["M", boundary.start[0].x, boundary.start[0].y]
  for (var side = 3; side >= 0; side--) {
    appendReverseCorner(path, boundary, side)
    path.push("L", boundary.start[side].x, boundary.start[side].y)
  }
  path.push("Z")
  return path.join(" ")
}

// One closed band over <length> sides in a row from <start>: out along the
// outer boundary, the corners at both ends included, and back along the inner.
function runPath(outer, inner, start, length) {
  var before = (start + 3) % 4
  var after = (start + length) % 4
  var path = ["M", outer.end[before].x, outer.end[before].y]
  appendForwardCorner(path, outer, before)
  for (var i = 0; i < length; i++) {
    var side = (start + i) % 4
    path.push("L", outer.end[side].x, outer.end[side].y)
    appendForwardCorner(path, outer, side)
  }
  path.push("L", inner.start[after].x, inner.start[after].y)
  for (var j = length - 1; j >= 0; j--) {
    var back = (start + j) % 4
    appendReverseCorner(path, inner, back)
    path.push("L", inner.start[back].x, inner.start[back].y)
  }
  appendReverseCorner(path, inner, before)
  path.push("Z")
  return path.join(" ")
}

// Whether radii (in normalizeRadii's input form) fit a <w> by <h> box as they
// are, with no two along an edge overlapping.
function radiiFit(w, h, r) {
  return r.tlrx + r.trrx <= w && r.blrx + r.brrx <= w && r.tlry + r.blry <= h && r.trry + r.brry <= h
}

// The outline of a border <widths> wide round a <w> by <h> box with corners of
// <radius>, as closed paths to fill with the winding rule. All four sides are
// one path: the box, and inside it the inner edge reversed. Fewer are a band
// for each run of sides in a row, so a side with no width has nothing drawn
// along it, not even at a rounded corner. Where the inner edge cannot keep
// its corners, the whole box is filled rather than risk painting outside it.
function borderPaths(w, h, radius, widths) {
  w = Math.max(0, Number(w) || 0)
  h = Math.max(0, Number(h) || 0)
  radius = Math.max(0, Number(radius) || 0)
  widths = widths || { top: 0, right: 0, bottom: 0, left: 0 }
  if (w <= 0 || h <= 0) return []

  var top = Math.max(0, Number(widths.top) || 0)
  var right = Math.max(0, Number(widths.right) || 0)
  var bottom = Math.max(0, Number(widths.bottom) || 0)
  var left = Math.max(0, Number(widths.left) || 0)
  var drawn = [top > 0, right > 0, bottom > 0, left > 0]
  if (drawn.indexOf(true) === -1) return []

  var outerRadii = normalizeRadii(w, h, {
    tlrx: radius, tlry: radius, trrx: radius, trry: radius,
    brrx: radius, brry: radius, blrx: radius, blry: radius,
  })
  var outerPath = roundedRectPath(0, 0, w, h, {
    tlrx: outerRadii.tl.rx, tlry: outerRadii.tl.ry, trrx: outerRadii.tr.rx, trry: outerRadii.tr.ry,
    brrx: outerRadii.br.rx, brry: outerRadii.br.ry, blrx: outerRadii.bl.rx, blry: outerRadii.bl.ry,
  })

  var innerWidth = w - left - right
  var innerHeight = h - top - bottom
  if (innerWidth <= 0 || innerHeight <= 0) return [outerPath]

  // An inner corner is the outer one less the two sides' widths.
  var innerWanted = {
    tlrx: Math.max(0, outerRadii.tl.rx - left), tlry: Math.max(0, outerRadii.tl.ry - top),
    trrx: Math.max(0, outerRadii.tr.rx - right), trry: Math.max(0, outerRadii.tr.ry - top),
    brrx: Math.max(0, outerRadii.br.rx - right), brry: Math.max(0, outerRadii.br.ry - bottom),
    blrx: Math.max(0, outerRadii.bl.rx - left), blry: Math.max(0, outerRadii.bl.ry - bottom),
  }
  // Shrunk to fit, an inner corner could start outside the outer edge.
  if (!radiiFit(innerWidth, innerHeight, innerWanted)) return [outerPath]

  var outer = borderBoundary(0, 0, w, h, outerRadii)
  var inner = borderBoundary(left, top, innerWidth, innerHeight, normalizeRadii(innerWidth, innerHeight, innerWanted))
  if (drawn.indexOf(false) === -1) return [outerPath + " " + reverseBoundaryPath(inner)]

  var paths = []
  for (var start = 0; start < 4; start++) {
    // A run starts at a drawn side whose side before it is not drawn.
    if (!drawn[start] || drawn[(start + 3) % 4]) continue
    var length = 1
    while (length < 4 && drawn[(start + length) % 4]) length++
    paths.push(runPath(outer, inner, start, length))
  }
  return paths
}

function ringPath(w, h, radius, widths) {
  return borderPaths(w, h, radius, widths).join(" ")
}

// The ends of a linear gradient at <angle> degrees across a <w> by <h> box,
// through its centre and as long as the box is across in that direction, as
// CSS draws one.
function gradientEndpoints(w, h, angle) {
  w = Math.max(1, Number(w) || 1)
  h = Math.max(1, Number(h) || 1)
  var radians = (Number(angle) || 0) * Math.PI / 180
  var dx = Math.cos(radians)
  var dy = Math.sin(radians)
  var half = (Math.abs(w * dx) + Math.abs(h * dy)) / 2
  return {
    x1: w / 2 - dx * half,
    y1: h / 2 - dy * half,
    x2: w / 2 + dx * half,
    y2: h / 2 + dy * half,
  }
}

// A gradient has a fixed number of stops (BorderOverlay's ten); the colours
// spread evenly over them, and the stops past the last colour repeat it.
function stopColor(colors, index) {
  if (!colors || colors.length === 0) return "transparent"
  return index < colors.length ? colors[index] : colors[colors.length - 1]
}

function stopPosition(colors, index) {
  var count = colors ? colors.length : 0
  if (count <= 1) return index === 0 ? 0 : 1
  return index >= count ? 1 : index / (count - 1)
}
