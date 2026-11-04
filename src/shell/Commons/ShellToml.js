.pragma library
.import "ColorText.js" as ColorText

// The two files a theme's colours come from, read as far as the shell needs
// them: colors.toml's palette, and shell.toml's sections.

// shell.toml as "section.key" -> the value's text. A value is a quoted
// string, a list of up to four numbers, or a bare word, and a comment may
// follow it; readers make numbers of what they need as numbers. A key
// before the first section, and a line of any other shape, is passed over.
var HEADER = /^\[([A-Za-z0-9_-]+)\]\s*(#.*)?$/
var ENTRY = /^([A-Za-z0-9_-]+)\s*=\s*(?:["']([^"']+)["']|(-?\d+(?:\.\d+)?(?:\s+-?\d+(?:\.\d+)?){0,3})|([A-Za-z][A-Za-z0-9_-]*))\s*(#.*)?$/

function parse(raw) {
  var table = {}
  var section = ""
  String(raw || "").split("\n").map(function(line) { return line.trim() }).forEach(function(text) {
    if (text === "" || text.charAt(0) === "#") return
    var header = HEADER.exec(text)
    if (header) {
      section = header[1]
      return
    }
    var entry = ENTRY.exec(text)
    if (entry && section) table[section + "." + entry[1]] = entry[2] || entry[3] || entry[4]
  })
  return table
}

// colors.toml's "#rrggbb" values by name, color1 by the name red.
function paletteNames(raw) {
  var named = {}
  String(raw || "").split("\n").forEach(function(line) {
    var found = /^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/.exec(line)
    if (found) named[found[1] === "color1" ? "red" : found[1]] = found[2]
  })
  return named
}

// The first word of a value that is not an angle: a gradient's first
// colour. With none, the value as it is.
function firstColor(value) {
  var words = String(value || "").trim().split(/\s+/)
  var colour = words.find(function(word) { return !ColorText.isAngle(word) })
  return colour === undefined ? value : colour
}
