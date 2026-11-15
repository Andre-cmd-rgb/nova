.pragma library

// A colour as a theme's text writes it. Besides #rgb, #rrggbb and
// #rrggbbaa, Hyprland's own forms are read, rgb(rrggbb), rgba(rrggbbaa),
// rgb(r,g,b), rgba(r,g,b,a) and 0xaarrggbb, so that a border can be copied
// from the compositor's config as it is.

// A number from 0 to 1; anything that is not a number is 0.
function unit(value) {
  var n = Number(value)
  return isFinite(n) ? Math.max(0, Math.min(1, n)) : 0
}

// A channel from 0 to 255, rounded.
function channel(value) {
  return Math.max(0, Math.min(255, Math.round(Number(value))))
}

function fromHex(digits) {
  return [digits.slice(0, 2), digits.slice(2, 4), digits.slice(4, 6)].map(function(pair) { return parseInt(pair, 16) })
}

function hexAlpha(pair) {
  return pair ? parseInt(pair, 16) / 255 : 1
}

// Each form, and how a match of it gives [[red, green, blue], opacity]: the
// channels 0 to 255, the opacity 0 to 1.
var FORMS = [
  [/^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$/,
    function(m) { return [fromHex(m[1] + m[1] + m[2] + m[2] + m[3] + m[3]), 1] }],
  [/^#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?$/,
    function(m) { return [fromHex(m[1]), hexAlpha(m[2])] }],
  [/^rgb\(([0-9A-Fa-f]{6})\)$/i,
    function(m) { return [fromHex(m[1]), 1] }],
  [/^rgba\(([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})\)$/i,
    function(m) { return [fromHex(m[1]), hexAlpha(m[2])] }],
  [/^rgb\(([0-9]+),([0-9]+),([0-9]+)\)$/i,
    function(m) { return [[m[1], m[2], m[3]].map(channel), 1] }],
  [/^rgba\(([0-9]+),([0-9]+),([0-9]+),([0-9.]+)\)$/i,
    function(m) { return [[m[1], m[2], m[3]].map(channel), unit(m[4])] }],
  [/^0x([0-9A-Fa-f]{2})([0-9A-Fa-f]{6})$/,
    function(m) { return [fromHex(m[2]), hexAlpha(m[1])] }]
]

// <value> as a colour at its own opacity times <opacity> (1 when not
// given), the opacity rounded to a byte. Text in none of the forms, a
// colour's name or a palette role, comes back as it was, trimmed.
function read(value, opacity) {
  var times = opacity === undefined || opacity === null ? 1 : unit(opacity)
  var text = String(value || "").trim()
  for (var i = 0; i < FORMS.length; i++) {
    var found = FORMS[i][0].exec(text)
    if (found === null) continue
    var parts = FORMS[i][1](found)
    var rgb = parts[0]
    return Qt.rgba(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, channel(parts[1] * times * 255) / 255)
  }
  return text
}

// Whether <word> is a gradient's angle, "<n>deg".
function isAngle(word) {
  return /^-?\d+(?:\.\d+)?deg$/.test(word)
}
