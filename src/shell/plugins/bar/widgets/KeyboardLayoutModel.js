.pragma library

// What the keyboard layout widget makes of xkb's and Hyprland's answers,
// kept apart from Qt.

// Devices Hyprland counts as keyboards that nobody types on: fcitx5's
// virtual keyboard, kept on the US layout, and the power button, sleep key,
// lid switch and video bus, which carry the seat's layouts all the same.
// Any of them can be Hyprland's "main" keyboard, and each switches layouts
// with the rest.
const untyped = /^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)/

// xkb's code for each layout, by the description Hyprland names a keymap
// with: { "English (US)": "en" }. `xkbcli list` writes a YAML block for
// each layout and variant,
//
//   - layout: 'us'
//     variant: ''
//     brief: 'en'
//     description: English (US)
//
// and a description takes the brief above it in its own block. Models and
// option groups have none at that depth, and give nothing.
function codes(listing) {
  const found = {}
  for (const block of String(listing || "").split(/^(?=\s*- )/m)) {
    const brief = /^  brief: (.*)$/m.exec(block)
    const named = /^  description: (.*)$/m.exec(block)
    const code = brief ? brief[1].replace(/^'|'$/g, "") : ""
    if (code && named && named.index > brief.index) found[named[1]] = code
  }
  return found
}

// The widget's text for a keymap, three letters at most: xkb's code without
// a script after it (Burmese Zawgyi's my-zwg is MY), a language code as
// GNOME shows one (EO for Esperanto, AR for Arabic), or where xkb has none,
// the first word of the description (ENG, POR).
function label(keymap, known) {
  if (!keymap) return ""
  // Its own key only: "constructor" would find Object's.
  const code = Object.prototype.hasOwnProperty.call(known || {}, keymap) ? known[keymap] : ""
  return (code ? code.split("-")[0] : keymap.split(/\s+/)[0]).slice(0, 3).toUpperCase()
}

// The keyboard an activelayout event names, or "" for fcitx5's virtual
// one. The event is cut in two, so a layout with a comma in its name stays
// whole.
function named(event) {
  const name = String(event.parse(2)[0] || "")
  return name.startsWith("hl-virtual-keyboard") ? "" : name
}

// What `hyprctl -j devices` says of the keyboards typed on: how many there
// are, and the one the widget speaks for while it has a keymap, else null.
// That is the one the last switch named, while it is there, else the one
// furthest along its layouts, the first of a tie: only the keyboard typed
// on moves along, and one gone round past its last layout to the first is
// still the one named, where its place would lose it. An answer that is no
// list, a reading cut short, says nothing at all: null.
function seat(answer, lastNamed) {
  let listed
  try {
    listed = JSON.parse(answer || "{}").keyboards
  } catch (error) {
    return null
  }
  if (!Array.isArray(listed)) return null

  const typed = listed.filter(device => !untyped.test(String(device.name || "")))
  let speaker = typed.find(device => device.name === lastNamed)
  if (!speaker) {
    for (const device of typed) {
      if (!speaker || along(device) > along(speaker)) speaker = device
    }
  }
  return { count: typed.length, keyboard: speaker && speaker.active_keymap ? speaker : null }
}

function along(keyboard) {
  return keyboard.active_layout_index || 0
}
