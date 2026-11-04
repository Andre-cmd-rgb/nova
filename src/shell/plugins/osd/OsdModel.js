.pragma library

// What the OSD shows for a request, and where on its card: an icon, and a
// level with its readout or a few words. Requests come as nova-osd sends
// them, every field a string, or from the shell's keys and panels, with
// numbers.

// Icons by the names callers give. A name not here is shown as it is, so a
// caller can pass a glyph of its own.
var ICONS = {
  "volume-muted": "\u{EEE8}", "volume-mute": "\u{EEE8}", "muted": "\u{EEE8}", "mute": "\u{EEE8}",
  "volume-low": "\u{F026}",
  "volume-medium": "\u{F027}",
  "volume-high": "\u{F028}", "volume": "\u{F028}",
  "microphone-muted": "\u{F036D}", "microphone-off": "\u{F036D}", "mic-muted": "\u{F036D}", "mic-off": "\u{F036D}",
  "microphone": "\u{F036C}", "mic": "\u{F036C}",
  "keyboard": "\u{F030C}",
  "brightness": "\u{F0379}", "display": "\u{F0379}",
  "touchpad": "\u{F07F8}",
  "touch": "\u{F0741}", "touchscreen": "\u{F0741}",
  "reboot": "\u{F0709}", "restart": "\u{F0709}",
  "shutdown": "\u{F0425}", "power": "\u{F0425}", "poweroff": "\u{F0425}",
  "logout": "\u{F0343}", "sign-out": "\u{F0343}", "leave": "\u{F0343}",
  "media": "\u{F075A}", "player": "\u{F075A}", "media-source": "\u{F075A}", "player-source": "\u{F075A}",
  "media-play": "\u{F040A}", "player-play": "\u{F040A}",
  "media-pause": "\u{F03E4}", "player-pause": "\u{F03E4}",
  "media-next": "\u{F04AD}", "player-next": "\u{F04AD}",
  "media-previous": "\u{F04AE}", "player-previous": "\u{F04AE}"
}

// The widest icon a level is shown with, and the widest readout. The card
// keeps their room beside a level, so that the bar stays put as the
// speaker's waves come and go and the percentage grows.
var widestIcon = ICONS["volume-high"]
var widestReadout = "100%"

// With no name, the speaker, its waves by the level (-1: none given).
function iconFor(name, percent) {
  var key = String(name || "").toLowerCase()
  if (Object.prototype.hasOwnProperty.call(ICONS, key)) return ICONS[key]
  if (key) return name
  if (percent <= 0) return ICONS["volume-muted"]
  if (percent <= 33) return ICONS["volume-low"]
  if (percent <= 66) return ICONS["volume-medium"]
  return ICONS["volume-high"]
}

// A field as nova-osd would have sent it.
function text(value) {
  return value === undefined ? "" : String(value)
}

// A request ({ icon, message, value, max, progressText, duration }, each one
// optional) as the card shows it:
//   glyph       the icon
//   level       whether it shows a level: a value given and no message
//   fill        the share of the bar the level fills, 0 to 1
//   words       the message, or the level's readout: progressText, or else
//               the percentage
//   duration    in ms, 0 to stay until closed, 1200 when none is given
//   fromPlayer  a player's, whose words get more room
function parse(request) {
  var message = String(request.message || "")
  var given = text(request.value)
  var max = Math.max(1, parseInt(text(request.max) || "100", 10))
  var number = parseInt(given || "0", 10)
  var level = given !== "" && !isNaN(number) && message === ""
  var value = level ? Math.min(max, Math.max(0, number)) : 0
  var percent = level ? Math.round(value * 100 / max) : -1
  var duration = parseInt(text(request.duration) || "1200", 10)
  return {
    glyph: iconFor(request.icon || "", percent),
    level: level,
    fill: value / max,
    words: message || (level ? String(request.progressText || percent + "%") : ""),
    duration: isNaN(duration) ? 1200 : Math.max(0, duration),
    fromPlayer: /^(media|player)/.test(String(request.icon || "").toLowerCase())
  }
}

// Where the card's pieces go, from its content's left edge, for a face of
// parse() and what the card measured of it:
//   ink, widestInk        the icon's ink, and the widest level icon's
//   readout, words        the widest readout's advance, and the words'
//   gap, bar, wordsMax    the gaps, the bar's length, the words' most room
// The icon sits in a column, as wide as its ink, or beside a level the
// widest icon's. The bar starts a gap after it. Words beside an icon look
// further from it than they are, as both fall away from their edges, so
// they start two thirds of the gap after it, and stop at wordsMax; a
// readout comes a gap after the bar and ends at the card's padding.
function layout(face, sizes) {
  var ink = Math.ceil(sizes.ink)
  var column = face.level ? Math.max(ink, Math.ceil(sizes.widestInk)) : ink
  var barX = column + sizes.gap
  var textX = face.level ? barX + sizes.bar + sizes.gap : column + Math.round(sizes.gap * 2 / 3)
  var textWidth = face.level ? Math.ceil(Math.max(sizes.readout, sizes.words))
    : Math.min(Math.ceil(sizes.words), sizes.wordsMax)
  return {
    ink: ink,
    column: column,
    barX: barX,
    textX: textX,
    textWidth: textWidth,
    width: face.level || face.words !== "" ? textX + textWidth : column
  }
}
