.pragma library

// What the shell's verbs do to a shell.json: where a widget is in the bar
// layout, where a new one goes, moving one, setting one up, and the lists
// that name a plugin as on or off. Each function works on the config it is
// handed, in place, and knows nothing of files or of which plugins exist.

var SECTIONS = ["left", "center", "right"]

// The widget after which a section's newcomer goes when nothing else says
// where.
var ANCHORS = { left: "nova.workspaces", center: "nova.weather", right: "nova.tray" }

function isObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function emptyLayout() {
  return { left: [], center: [], right: [] }
}

// The id of a layout entry, which is { id, ...settings } or the bare id.
function entryId(entry) {
  if (isObject(entry)) return String(entry.id)
  return String(entry || "")
}

// Where widget <id> is in the bar, looking only in section <only> when one
// is named: { section, index }, or null.
function find(config, id, only) {
  var layout = isObject(config) && isObject(config.bar) ? config.bar.layout : null
  if (!isObject(layout)) return null
  var wanted = String(id)
  for (var s = 0; s < SECTIONS.length; s++) {
    var section = SECTIONS[s]
    var list = layout[section]
    if ((only && only !== section) || !Array.isArray(list)) continue
    var index = list.findIndex(function(entry) { return entryId(entry) === wanted })
    if (index >= 0) return { section: section, index: index }
  }
  return null
}

// Where shell.json names plugin <id>: in the bar, else in plugins, as
// { list, index } (the list holding the entry), or null.
function locate(config, id) {
  if (!isObject(config)) return null
  var spot = find(config, id, "")
  if (spot) return { list: config.bar.layout[spot.section], index: spot.index }
  if (!Array.isArray(config.plugins)) return null
  var wanted = String(id)
  var at = config.plugins.findIndex(function(named) { return !!named && String(named.id || "") === wanted })
  return at >= 0 ? { list: config.plugins, index: at } : null
}

// Fills in what the verbs count on: a bar whose layout has its three
// lists, and a list of plugins.
function shape(config) {
  if (!isObject(config.bar)) config.bar = {}
  if (!isObject(config.bar.layout)) config.bar.layout = {}
  SECTIONS.forEach(function(section) {
    if (!Array.isArray(config.bar.layout[section])) config.bar.layout[section] = []
  })
  if (!Array.isArray(config.plugins)) config.plugins = []
}

// Where <placement> puts a widget: { section, index }, or { error }. Next to
// the widget it names before or after; else at its index; else after the
// section's anchor; else at the end. The section is the one it names, or
// <fallback>, whose list this makes if the layout has none.
function place(config, placement, fallback) {
  var wish = placement || {}
  var section = SECTIONS.indexOf(String(wish.section || "")) >= 0 ? String(wish.section) : fallback
  var neighbour = String(wish.before || wish.after || "")
  if (neighbour) {
    var next = find(config, neighbour, wish.section && section ? section : "")
    if (!next) return { error: "could not find target widget " + neighbour }
    return { section: next.section, index: wish.after ? next.index + 1 : next.index }
  }
  var layout = config.bar.layout
  if (!Array.isArray(layout[section])) layout[section] = []
  var end = layout[section].length
  if (wish.index !== undefined && wish.index !== null)
    return { section: section, index: Math.min(end, Math.max(0, Math.floor(Number(wish.index)))) }
  var anchor = find(config, ANCHORS[section], section)
  return { section: section, index: anchor ? anchor.index + 1 : end }
}

// Whether a placement names a place at all; {} leaves it to the defaults.
function namesPlace(placement) {
  return isObject(placement) && ["section", "index", "before", "after"].some(function(key) {
    var value = placement[key]
    return value !== undefined && value !== null && value !== ""
  })
}

// Where Nova's default layout, <defaults>, keeps widget <id>, in this bar:
// in its section there, before the first of its later neighbours there that
// this bar has, else after the nearest earlier one, else at the end. Null
// for a widget the default layout lacks.
function homePlace(config, defaults, id) {
  var home = find(defaults, id, "")
  if (!home) return null
  var row = defaults.bar.layout[home.section]
  for (var later = home.index + 1; later < row.length; later++) {
    var before = find(config, entryId(row[later]), home.section)
    if (before) return { section: home.section, index: before.index }
  }
  for (var earlier = home.index - 1; earlier >= 0; earlier--) {
    var after = find(config, entryId(row[earlier]), home.section)
    if (after) return { section: home.section, index: after.index + 1 }
  }
  return { section: home.section, index: config.bar.layout[home.section].length }
}

// Moves widget <id> to where <placement> says (place): from
// fromSection[fromIndex] when it gives an index, else from wherever it is,
// in fromSection if it names one. "" when done, else what was wrong, with
// the layout as it was.
function move(config, id, placement) {
  var wanted = String(id)
  var layout = config.bar.layout
  var from
  if (placement.fromIndex !== undefined && placement.fromIndex !== null) {
    var section = String(placement.fromSection || "")
    if (!section) return "from-index requires from-section"
    var at = Math.floor(Number(placement.fromIndex))
    var list = layout[section]
    if (!Array.isArray(list) || at < 0 || at >= list.length) return "no widget at " + section + "[" + at + "]"
    if (entryId(list[at]) !== wanted) return "widget at " + section + "[" + at + "] is not " + wanted
    from = { section: section, index: at }
  } else {
    from = find(config, wanted, String(placement.fromSection || ""))
    if (!from) return "could not find widget " + wanted
  }
  var moving = layout[from.section].splice(from.index, 1)[0]
  var to = place(config, placement, from.section)
  if (to.error) {
    layout[from.section].splice(from.index, 0, moving)
    return to.error
  }
  layout[to.section].splice(to.index, 0, moving)
  return ""
}

// Sets <key> to <value> in widget <id>'s entry: the one at the selector's
// (from)section[(from)index] when it gives an index, else the widget
// wherever it is, in that section if it names one. "" when done, else what
// was wrong.
function setOption(config, id, key, value, selector) {
  var which = selector || {}
  var section = String(which.fromSection || which.section || "")
  var index = which.fromIndex !== undefined && which.fromIndex !== null ? which.fromIndex : which.index
  var spot
  if (index === undefined || index === null) {
    spot = find(config, id, section)
    if (!spot) return "could not find widget " + id
  } else {
    if (!section) return "index requires section"
    var at = Math.floor(Number(index))
    var list = config.bar.layout[section]
    if (!Array.isArray(list) || at < 0 || at >= list.length) return "no widget at " + section + "[" + at + "]"
    spot = { section: section, index: at }
  }
  var entry = config.bar.layout[spot.section][spot.index]
  if (entryId(entry) !== String(id)) return "widget at " + spot.section + "[" + spot.index + "] is not " + id
  if (!isObject(entry)) return "widget entry must be an object"
  entry[String(key)] = value
  return ""
}

// Writes plugin <id>'s <settings>, the whole of them (an id among them is
// ignored), into each of its entries in the bar, a bare id becoming an
// object, or else into its entries in plugins. Whether any entry changed.
function writeSettings(config, id, settings) {
  if (!isObject(config.bar)) config.bar = { layout: emptyLayout() }
  if (!isObject(config.bar.layout)) config.bar.layout = emptyLayout()
  if (!Array.isArray(config.plugins)) config.plugins = []
  var entry = { id: id }
  for (var key in settings) {
    if (key !== "id") entry[key] = settings[key]
  }
  var written = JSON.stringify(entry)
  var named = false
  var changed = false
  function rewrite(list, matches) {
    for (var i = 0; i < list.length; i++) {
      if (!matches(list[i])) continue
      named = true
      if (JSON.stringify(list[i]) === written) continue
      list[i] = JSON.parse(written)
      changed = true
    }
  }
  SECTIONS.forEach(function(section) {
    rewrite(config.bar.layout[section] || [], function(other) {
      return typeof other === "string" ? other === id : !!other && String(other.id || "") === id
    })
  })
  if (!named) rewrite(config.plugins, function(other) { return !!other && other.id === id })
  return changed
}

// disabledPlugins: the plugins on by default that have been switched off.
function isOff(config, id) {
  return isObject(config) && Array.isArray(config.disabledPlugins) && config.disabledPlugins.indexOf(String(id)) >= 0
}

function markOff(config, id) {
  if (isOff(config, id)) return
  if (Array.isArray(config.disabledPlugins)) config.disabledPlugins.push(id)
  else config.disabledPlugins = [id]
}

// Takes <id> out of disabledPlugins, and the list out once it is empty.
function unmarkOff(config, id) {
  if (!Array.isArray(config.disabledPlugins)) return
  var rest = config.disabledPlugins.filter(function(other) { return other !== id })
  if (rest.length > 0) config.disabledPlugins = rest
  else delete config.disabledPlugins
}
