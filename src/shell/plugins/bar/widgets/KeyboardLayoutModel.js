.pragma library

// What the keyboard layout widget reads from xkb and Hyprland, kept apart from
// Qt.

// The two- or three-letter code xkb gives each layout, by the description
// Hyprland names the active keymap with: { "English (US)": "en", ... }. It
// comes from `xkbcli list`, whose YAML holds one block per layout or variant:
//
//   - layout: 'us'
//     variant: ''
//     brief: 'en'
//     description: English (US)
//
// A brief belongs to its own block only; the models and option groups in the
// same list have none, so they add nothing.
function layoutBriefs(text) {
  var briefs = {}
  var brief = ""
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (/^\s*- /.test(lines[i])) brief = ""
    var field = /^  (brief|description): (.*)$/.exec(lines[i])
    if (!field) continue
    if (field[1] === "brief") {
      brief = field[2].replace(/^'|'$/g, "")
    } else if (brief) {
      briefs[field[2]] = brief
      brief = ""
    }
  }
  return briefs
}

// The label for a keymap: its brief, a language code as GNOME shows it (EO
// for Esperanto, AR for Arabic), or for a keymap xkb has none for, the first
// word of its description (ENG, POR). A brief with a script after it
// (Burmese Zawgyi's my-zwg) loses the script, and every label stops at three
// letters, the room the widget has between its neighbours.
function shortLabel(description, briefs) {
  if (!description) return ""
  // Only a string is a brief: "constructor" would find Object's own.
  var brief = briefs ? briefs[description] : undefined
  var word = typeof brief === "string" && brief !== "" ? brief.split("-")[0] : description.split(/\s+/)[0]
  return word.substring(0, 3).toUpperCase()
}

// The keyboard an activelayout event says switched, its first field. The
// event is cut in two so that a layout with a comma in its name stays whole;
// a Quickshell too old to cut it hands over the raw data, cut here. fcitx5's
// virtual keyboard switches too, but no one types on it, so it names none.
function eventKeyboardName(event) {
  var fields = null
  try {
    if (event && event.parse) fields = event.parse(2)
  } catch (error) {
    fields = null
  }
  if (!fields) fields = String(event && event.data ? event.data : "").split(",")
  var name = String(fields[0] || "")
  return name.indexOf("hl-virtual-keyboard") === 0 ? "" : name
}

// Hyprland lists more than keyboards as keyboards: fcitx5's virtual one, kept
// on the US layout, and the power button, sleep key, lid switch and video bus,
// which carry the seat's layouts though no one types on them. Each switches
// layouts and can be the "main" one, so a widget that took any of them would
// describe a button. A device not named here stays in.
function isTypedKeyboard(name) {
  return !/^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)/.test(String(name || ""))
}

// The keyboard the widget speaks for. The one the last switch named, while it
// is still there; else the one furthest along the layout list, the first of
// those when they tie. Only the keyboard typed on moves along the list, and
// one that went past the last layout back to the first is still the one named,
// so a position alone would lose it.
function selectKeyboard(keyboards, named) {
  var list = keyboards || []
  var furthest = list[0]
  for (var i = 0; i < list.length; i++) {
    if (list[i].name === named) return list[i]
    if (layoutIndex(list[i]) > layoutIndex(furthest)) furthest = list[i]
  }
  return furthest
}

function layoutIndex(keyboard) {
  return (keyboard && keyboard.active_layout_index) || 0
}
