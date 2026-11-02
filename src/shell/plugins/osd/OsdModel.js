// What the OSD shows for a request: an icon, and a level with its readout or
// a message. Requests come as nova-osd sends them, every field a string, or
// from the shell's keys and panels, with numbers.

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

// The widest icon a level is shown with. The icon's column is kept this
// wide, so the bar stays put as the speaker's waves come and go.
var widestIcon = ICONS["volume-high"]

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

function given(value) {
  return value === undefined ? "" : String(value)
}

// A request ({ icon, message, value, max, progressText, duration }, each one
// optional) as the card shows it. A message wins over a level; a level shows
// as a percentage unless progressText says otherwise. The duration is in ms,
// 0 to stay up until closed, 1200 when none is given.
function parse(request) {
  var message = request.message || ""
  var valueText = given(request.value)
  var max = Math.max(1, parseInt(given(request.max) || "100", 10))
  var level = parseInt(valueText || "0", 10)
  var hasProgress = valueText !== "" && !isNaN(level) && message === ""
  var value = hasProgress ? Math.max(0, Math.min(max, level)) : 0
  var percent = hasProgress ? Math.round(value * 100 / max) : -1
  var duration = parseInt(given(request.duration) || "1200", 10)
  return {
    iconKey: String(request.icon || "").toLowerCase(),
    icon: iconFor(request.icon || "", percent),
    hasProgress: hasProgress,
    value: value,
    maxValue: max,
    message: String(message || (hasProgress ? request.progressText || percent + "%" : "")),
    duration: isNaN(duration) ? 1200 : Math.max(0, duration)
  }
}
