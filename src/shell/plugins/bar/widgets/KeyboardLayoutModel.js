.pragma library

// The keyboard layout widget's reading of xkb and Hyprland, apart from Qt.

// Devices Hyprland lists as keyboards that nobody types on: fcitx5's virtual
// keyboard, kept on the US layout, and the power button, sleep key, lid
// switch and video bus, which carry the seat's layouts all the same. Any of
// them can be the "main" keyboard, and switches layouts with the rest.
var notTypedOn = /^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)/

// The short code xkb gives each layout, by the description Hyprland names
// the active keymap with: { "English (US)": "en", ... }. `xkbcli list`
// writes a YAML block per layout or variant,
//
//   - layout: 'us'
//     variant: ''
//     brief: 'en'
//     description: English (US)
//
// and a brief counts only with the description of its own block. Models
// and option groups have none, and add nothing.
function layoutBriefs(text) {
  var briefs = {}
  var open = ""
  String(text || "").split("\n").forEach(function(line) {
    if (/^\s*- /.test(line)) open = ""
    var key = /^  (brief|description): (.*)$/.exec(line)
    if (!key) return
    if (key[1] === "brief") {
      open = key[2].replace(/^'|'$/g, "")
    } else if (open) {
      briefs[key[2]] = open
      open = ""
    }
  })
  return briefs
}

// What the widget shows for a keymap, three letters at most: its brief
// without a script after it (Burmese Zawgyi's my-zwg is MY), a language code
// as GNOME shows it (EO for Esperanto, AR for Arabic), or where xkb has none,
// the first word of the description (ENG, POR).
function shortLabel(description, briefs) {
  if (!description) return ""
  // A brief is a string: "constructor" would find Object's own.
  var brief = briefs && briefs[description]
  var word = typeof brief === "string" && brief ? brief.split("-")[0] : description.split(/\s+/)[0]
  return word.slice(0, 3).toUpperCase()
}

// The keyboard an activelayout event names, its first field: Quickshell cuts
// the event in two, so a layout with a comma in its name stays whole, and an
// older one hands over the raw data. fcitx5's virtual keyboard names none.
function eventKeyboardName(event) {
  var fields = null
  try {
    fields = event && event.parse ? event.parse(2) : null
  } catch (error) {
    fields = null
  }
  var name = String((fields || String(event && event.data ? event.data : "").split(","))[0] || "")
  return name.indexOf("hl-virtual-keyboard") === 0 ? "" : name
}

function isTypedKeyboard(name) {
  return !notTypedOn.test(String(name || ""))
}

// The keyboard the widget speaks for: the one the last switch named, while
// it is there, else the one furthest along its layouts, the first of a tie.
// Only the keyboard typed on moves along, and one gone round past the last
// layout to the first is still the one named, so where it is would lose it.
function selectKeyboard(keyboards, named) {
  var list = keyboards || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].name === named) return list[i]
  }
  return list.reduce(function(furthest, keyboard) {
    return layoutIndex(keyboard) > layoutIndex(furthest) ? keyboard : furthest
  }, list[0])
}

function layoutIndex(keyboard) {
  return (keyboard && keyboard.active_layout_index) || 0
}
