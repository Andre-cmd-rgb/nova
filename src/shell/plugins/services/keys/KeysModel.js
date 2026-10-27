// The volume and brightness keys' arithmetic, as nova-audio-output-volume and
// nova-brightness-display have it, in whole percents.

// The volume <volume> (PipeWire's, 1.0 at 100%) moves to by <delta> percent.
// Up stops at 100 even from above it; down only at 0.
function volumeStep(volume, delta) {
  var next = Math.round(Number(volume || 0) * 100) + delta
  if (delta > 0) next = Math.min(next, 100)
  return Math.max(0, next)
}

// Whether a held volume key has further to go from <percent>.
function volumeMore(percent, delta) {
  return delta > 0 ? percent < 100 : percent > 0
}

// The OSD's icon for the volume: the speaker struck through when muted or
// silent.
function volumeIcon(percent, muted) {
  return muted || percent === 0 ? "volume-muted" : "volume-high"
}

// The brightness a key moves to from <current>: by 1 at or below 5% and by 5
// above it, by 1 with Alt, all the way with Shift. Never below 1%, where a
// panel is as dim as it goes and still lit.
function brightnessStep(current, key) {
  switch (key) {
    case "up": return Math.min(100, current + (current < 5 ? 1 : 5))
    case "down": return Math.max(1, current - (current <= 5 ? 1 : 5))
    case "up-fine": return Math.min(100, current + 1)
    case "down-fine": return Math.max(1, current - 1)
    case "max": return 100
    case "min": return 1
  }
  return current
}

// Whether a held brightness key has further to go from <percent>: Shift's
// all-the-way is one press.
function brightnessMore(percent, key) {
  if (key === "up" || key === "up-fine") return percent < 100
  if (key === "down" || key === "down-fine") return percent > 1
  return false
}

// The percent a backlight's raw <value> out of <max> is, or -1 unread.
function backlightPercent(value, max) {
  value = parseInt(value, 10)
  max = parseInt(max, 10)
  if (isNaN(value) || isNaN(max) || max <= 0) return -1
  return Math.round(value * 100 / max)
}

// What nova-brightness-display-ddc takes for a key, on an external display.
function ddcStep(key) {
  var steps = { "up": "+5%", "down": "5%-", "up-fine": "+1%", "down-fine": "1%-", "max": "100%", "min": "1%" }
  return steps[key] || ""
}
