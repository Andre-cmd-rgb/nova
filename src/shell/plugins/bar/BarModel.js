.pragma library

// The bar's rules, kept apart from its windows: what a layout entry says,
// which copy of a widget a key reaches, where a dragged widget lands, and
// where a tooltip goes.

var SECTIONS = ["left", "center", "right"]

// A number held between min and max; min for one that is not a number.
function clamp(value, min, max) {
  const n = Number(value)
  return isFinite(n) ? Math.max(min, Math.min(max, n)) : min
}

// An object read from JSON, as it reaches a Repeater's delegate too: not
// null, not a list.
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// A layout entry is a bare id or an object carrying one.
function entryId(entry) {
  if (typeof entry === "string") return entry
  const id = isObject(entry) ? entry.id : undefined
  return id === undefined || id === null ? "" : String(id)
}

// The entry's settings: everything in it but its id.
function entrySettings(entry) {
  const settings = Object.assign({}, isObject(entry) ? entry : null)
  delete settings.id
  return settings
}

function indexOfId(entries, id) {
  return Array.isArray(entries) ? entries.findIndex(entry => entryId(entry) === id) : -1
}

function before(entries, id) {
  const at = indexOfId(entries, id)
  return at > 0 ? entries.slice(0, at) : []
}

function after(entries, id) {
  const at = indexOfId(entries, id)
  return at === -1 ? [] : entries.slice(at + 1)
}

// A section of <layout>: its list of entries, empty for none.
function section(layout, name) {
  const entries = isObject(layout) ? layout[name] : null
  return Array.isArray(entries) ? entries : []
}

// The bar's part of a shell.json being written, made when it has none.
function barOf(config) {
  if (!isObject(config.bar)) config.bar = {}
  return config.bar
}

// The widget the centre is centred on, the rest hanging off its sides. One
// shell.json names that is not in the centre, an id from before a rename, is
// the clock when the clock is there: with no anchor the centre is centred as
// one block, and every widget in it that changes width moves all the others.
// No anchor named at all is no anchor.
function centerAnchor(configured, center) {
  const anchor = String(configured || "")
  if (anchor === "" || indexOfId(center, anchor) !== -1) return anchor
  return indexOfId(center, "nova.clock") === -1 ? anchor : "nova.clock"
}

// A user's own widget: "command" (a program's output), "qml" (a file), or
// "" for one of Nova's. An entry naming no type is a command when it has
// one to run, and QML when it names a file.
function customType(entry) {
  const asked = isObject(entry) ? entry : {}
  return String(asked.type || "") || (asked.exec ? "command" : asked.source ? "qml" : "")
}

// The file a QML widget is loaded from: its source, with ~ and $HOME
// expanded, or <config>/bar/modules/<id>.qml for an id that stays in there.
function customSource(entry, home, configDir) {
  const source = String(entrySettings(entry).source || "")
  for (const prefix of ["~/", "$HOME/"]) {
    if (source.startsWith(prefix)) return home + "/" + source.slice(prefix.length)
  }
  if (source) return source
  const name = entryId(entry)
  const leaves = name === "" || name.includes("..") || name.startsWith("/")
  return leaves ? "" : String(configDir || "") + "/bar/modules/" + name + ".qml"
}

// What a shell.json write changed, when it only changed settings: the same
// ids in the same order in every section, each changed entry as
// { region, index, entry }. Null for any other change, and for a change to
// a user's widget (which reads its entry, not settings pushed to it) or to
// an id the layout holds twice (which a push could not tell apart). The bar
// pushes settings in place rather than rebuild every widget on every screen.
function settingsOnlyChanges(current, next) {
  if (!isObject(current) || !isObject(next)) return null
  if (SECTIONS.some(name => section(current, name).length !== section(next, name).length)) return null
  // Every entry of the new layout with its place and the entry it replaces.
  let places = []
  for (const region of SECTIONS) {
    const old = section(current, region)
    places = places.concat(section(next, region).map((entry, index) => ({ region, index, entry, old: old[index] })))
  }
  if (places.some(place => entryId(place.old) !== entryId(place.entry))) return null
  const twice = id => places.filter(place => entryId(place.entry) === id).length > 1
  const changed = places.filter(place => JSON.stringify(place.old) !== JSON.stringify(place.entry))
  if (changed.some(place => customType(place.old) || customType(place.entry) || twice(entryId(place.entry)))) return null
  return changed.map(place => ({ region: place.region, index: place.index, entry: place.entry }))
}

// Moves a widget in a shell.json being written: from its section to before
// `beforeId` in `toRegion`, or to that section's end. False when nothing
// moved. Sections the file lacks are made.
function moveEntry(config, fromRegion, id, toRegion, beforeId) {
  const bar = barOf(config)
  if (!isObject(bar.layout)) bar.layout = {}
  const layout = bar.layout
  for (const region of [fromRegion, toRegion]) {
    if (!Array.isArray(layout[region])) layout[region] = []
  }
  const from = layout[fromRegion]
  const to = layout[toRegion]
  const at = indexOfId(from, id)
  if (at === -1) return false
  let target = beforeId ? indexOfId(to, beforeId) : -1
  if (target === -1) target = to.length
  if (fromRegion === toRegion) {
    // Taken out first, a widget moving right lands one place earlier.
    if (at < target) target--
    if (at === target) return false
  }
  to.splice(target, 0, from.splice(at, 1)[0])
  return true
}

// Of a widget's live copies, one per screen's bar, the one a key or a call
// reaches. Copies are { slot, screen, open }. An open copy comes first, so
// hide and toggle reach the panel on screen wherever it was opened; then
// the copies on the focused screen, or with none there those on the first
// copy's screen. Of these, a copy that is drawn: a widget that hides itself
// (the keyboard layout with one layout) keeps its slot at no size, which
// cannot anchor a popup. Its slot, or null.
function reached(copies, focusedScreen) {
  let pool = (Array.isArray(copies) ? copies : []).filter(copy => copy && copy.slot)
  if (pool.some(copy => copy.open === true)) pool = pool.filter(copy => copy.open === true)
  const focused = String(focusedScreen || "")
  const screen = focused !== "" && pool.some(copy => copy.screen === focused) ? focused : pool.length > 0 ? pool[0].screen : null
  pool = pool.filter(copy => copy.screen === screen)
  const pick = pool.find(copy => isDrawn(copy.slot)) || pool[0]
  return pick ? pick.slot : null
}

function isDrawn(slot) {
  return slot.visible === true && slot.width > 0 && slot.height > 0
}

// Whether two screens are one: the same, or of the same name, as a screen
// can be handed out anew while its output stays.
function sameScreen(one, other) {
  return !!one && !!other && (one === other || (!!one.name && one.name === other.name))
}

// <list> with <item> at its end, or without it when not <on>: the same list
// when that changes nothing, so that what reads it is not told of a change.
function listed(list, item, on) {
  if (!item || on === list.includes(item)) return list
  return on ? list.concat([item]) : list.filter(other => other !== item)
}

// How far the pointer went from <from> to <to>, along and across together.
function travelled(from, to) {
  return Math.abs(to.x - from.x) + Math.abs(to.y - from.y)
}

// Where a dragged widget drops: before or after the widget whose near edge
// is closest along the bar, so the empty bar around a centred group takes a
// drop too. Candidates are { slot, x, y, width, height } in the window;
// returns { slot, after }, or null.
function dropPlace(candidates, point) {
  const along = Number(point && point.x)
  if (!isFinite(along)) return null
  let nearest = null
  for (const place of Array.isArray(candidates) ? candidates : []) {
    if (!place || !place.slot) continue
    const start = Number(place.x)
    const length = Number(place.width)
    if (!isFinite(start) || !isFinite(length) || length <= 0) continue
    const toStart = Math.abs(along - start)
    const toEnd = Math.abs(along - (start + length))
    const off = Math.min(toStart, toEnd)
    if (nearest === null || off < nearest.off) nearest = { slot: place.slot, after: toEnd < toStart, off: off }
  }
  return nearest && { slot: nearest.slot, after: nearest.after }
}

// The line drawn where a dragged widget would land: across the bar, at the
// start or the end of the widget at `point` with `width` and `height`.
function dropMarker(point, width, height, after, thickness) {
  return { x: point.x + (after ? width : 0) - thickness / 2, y: point.y, width: thickness, height: height }
}

// Where a tooltip <width> wide goes below a widget <widgetWidth> by
// <widgetHeight>, in the widget's coordinates: <gap> under it, centred on it.
function tipCorner(widgetWidth, widgetHeight, width, gap) {
  return { x: widgetWidth / 2 - width / 2, y: widgetHeight + gap }
}

// "#rrggbb" for channels from 0 to 1.
function hex(red, green, blue) {
  return "#" + [red, green, blue].map(function(channel) {
    const byte = Math.round(clamp(channel, 0, 1) * 255)
    return (byte < 16 ? "0" : "") + byte.toString(16)
  }).join("")
}
