.pragma library

// The bar's rules, kept apart from its windows: what a layout entry says,
// where the tray sits in a section, which copy of a widget a hotkey reaches,
// where a dragged widget lands, which edge a dragged bar goes to, and where
// a tooltip goes.

var EDGES = ["top", "bottom", "left", "right"]

// A number held between min and max; min for one that is not a number.
function clamp(value, min, max) {
  var n = Number(value)
  return isFinite(n) ? Math.max(min, Math.min(max, n)) : min
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// The edge shell.json names, top for anything else.
function edge(value) {
  var name = String(value || "").trim()
  return EDGES.indexOf(name) === -1 ? "top" : name
}

// A layout entry is a bare id or an object carrying one.
function entryId(entry) {
  if (typeof entry === "string") return entry
  var id = isObject(entry) ? entry.id : undefined
  return id === undefined || id === null ? "" : String(id)
}

// The entry's settings: everything in it but its id.
function entrySettings(entry) {
  var settings = {}
  if (!isObject(entry)) return settings
  for (var key in entry) {
    if (key !== "id") settings[key] = entry[key]
  }
  return settings
}

function indexOfId(entries, id) {
  if (!Array.isArray(entries)) return -1
  for (var i = 0; i < entries.length; i++) {
    if (entryId(entries[i]) === id) return i
  }
  return -1
}

function before(entries, id) {
  var at = indexOfId(entries, id)
  return at > 0 ? entries.slice(0, at) : []
}

function after(entries, id) {
  var at = indexOfId(entries, id)
  return at === -1 ? [] : entries.slice(at + 1)
}

// The tray's drawer opens away from the screen's edge, so the tray goes to
// the inner end of its section: first on the right, last on the left and in
// the centre. A section listing it twice keeps the last.
function trayInward(entries, section) {
  var rest = []
  var tray = null
  ;(Array.isArray(entries) ? entries : []).forEach(function(entry) {
    if (entryId(entry) === "nova.tray") tray = entry
    else rest.push(entry)
  })
  if (tray) {
    if (section === "right") rest.unshift(tray)
    else rest.push(tray)
  }
  return rest
}

// The widget the centre is centred on, the rest hanging off its sides. One
// shell.json names that is not in the centre, an id from before a rename, is
// the clock when the clock is there: with no anchor the centre is centred as
// one block, and every widget in it that changes width moves all the others.
// No anchor named at all is no anchor.
function centerAnchor(configured, center) {
  var anchor = String(configured || "")
  if (anchor === "" || indexOfId(center, anchor) !== -1) return anchor
  return indexOfId(center, "nova.clock") === -1 ? anchor : "nova.clock"
}

// A user's own widget: "command" (a program's output), "qml" (a file), or
// "" for one of Nova's. An entry naming no type is a command when it has
// one to run, and QML when it names a file.
function customType(entry) {
  var settings = entrySettings(entry)
  var type = String(settings.type || "")
  if (type) return type
  if (settings.exec) return "command"
  return settings.source ? "qml" : ""
}

// The file a QML widget is loaded from: its source, with ~ and $HOME
// expanded, or <config>/bar/modules/<id>.qml for an id that stays in there.
function customSource(entry, home, configDir) {
  var source = String(entrySettings(entry).source || "")
  if (source.indexOf("~/") === 0) return home + source.slice(1)
  if (source.indexOf("$HOME/") === 0) return home + source.slice(5)
  if (source) return source
  var id = entryId(entry)
  if (id === "" || id.indexOf("..") !== -1 || id[0] === "/") return ""
  return String(configDir || "") + "/bar/modules/" + id + ".qml"
}

// What a shell.json write changed, when it only changed settings: the same
// ids in the same order in every section, each changed entry as
// { region, index, entry }. Null for any other change, and for a change to
// a user's widget (which reads its entry, not settings pushed to it) or to
// an id the layout holds twice (which a push could not tell apart). The bar
// pushes settings in place rather than rebuild every widget on every screen.
function settingsOnlyChanges(current, next) {
  if (!isObject(current) || !isObject(next)) return null
  var sections = ["left", "center", "right"]
  var count = {}
  sections.forEach(function(section) {
    (Array.isArray(next[section]) ? next[section] : []).forEach(function(entry) {
      var id = entryId(entry)
      count[id] = (count[id] || 0) + 1
    })
  })
  var changes = []
  for (var s = 0; s < sections.length; s++) {
    var was = Array.isArray(current[sections[s]]) ? current[sections[s]] : []
    var now = Array.isArray(next[sections[s]]) ? next[sections[s]] : []
    if (was.length !== now.length) return null
    for (var i = 0; i < now.length; i++) {
      var id = entryId(now[i])
      if (entryId(was[i]) !== id) return null
      if (JSON.stringify(was[i]) === JSON.stringify(now[i])) continue
      if (customType(was[i]) || customType(now[i]) || count[id] > 1) return null
      changes.push({ region: sections[s], index: i, entry: now[i] })
    }
  }
  return changes
}

// Moves a widget in a shell.json being written: from its section to before
// `beforeId` in `toRegion`, or to that section's end. False when nothing
// moved. Sections the file lacks are made.
function moveEntry(config, fromRegion, id, toRegion, beforeId) {
  if (!isObject(config.bar)) config.bar = {}
  if (!isObject(config.bar.layout)) config.bar.layout = {}
  var layout = config.bar.layout
  ;[fromRegion, toRegion].forEach(function(region) {
    if (!Array.isArray(layout[region])) layout[region] = []
  })
  var from = layout[fromRegion]
  var to = layout[toRegion]
  var at = indexOfId(from, id)
  if (at === -1) return false
  var target = beforeId ? indexOfId(to, beforeId) : -1
  if (target === -1) target = to.length
  if (fromRegion === toRegion) {
    // Taken out first, a widget moving right lands one place earlier.
    if (at < target) target--
    if (at === target) return false
  }
  to.splice(target, 0, from.splice(at, 1)[0])
  return true
}

// Of a widget's live copies, one per screen's bar, the one a hotkey acts
// on. Candidates are { slot, screenName, opened }. An open copy comes first,
// so hide and toggle reach the panel on screen wherever it was opened; then
// the copies on the focused screen, or with none there those on the first
// copy's screen. Of these, a copy that is drawn: a widget that hides itself
// (the keyboard layout with one layout) keeps its slot at no size, which
// cannot anchor a popup.
function pickPanelSlot(candidates, focusedScreen) {
  var rows = (Array.isArray(candidates) ? candidates : []).filter(function(row) { return !!row })
  var open = rows.filter(function(row) { return row.opened === true })
  if (open.length > 0) rows = open
  var focused = String(focusedScreen || "")
  var here = rows.filter(function(row) { return row.screenName === focused })
  if (focused !== "" && here.length > 0) rows = here
  else if (rows.length > 0) rows = rows.filter(function(row) { return row.screenName === rows[0].screenName })

  var placeholder = null
  for (var i = 0; i < rows.length; i++) {
    var slot = rows[i].slot
    if (!slot) continue
    if (isDrawn(slot)) return slot
    if (!placeholder) placeholder = slot
  }
  return placeholder
}

function isDrawn(slot) {
  return slot.visible === true && slot.width > 0 && slot.height > 0
}

// Whether two screens are one: the same, or of the same name, as a screen
// can be handed out anew while its output stays.
function sameScreen(one, other) {
  return !!one && !!other && (one === other || (!!one.name && one.name === other.name))
}

// Where a dragged widget drops: before or after the widget whose near edge
// is closest along the bar, so the empty bar around a centred group takes a
// drop too. Candidates are { slot, x, y, width, height } in the window;
// returns { slot, after }, or null.
function dropPlace(candidates, point, vertical) {
  var along = Number(point && (vertical ? point.y : point.x))
  if (!isFinite(along)) return null
  var best = null
  var bestDistance = Infinity
  ;(Array.isArray(candidates) ? candidates : []).forEach(function(row) {
    if (!row || !row.slot) return
    var start = Number(vertical ? row.y : row.x)
    var size = Number(vertical ? row.height : row.width)
    if (!isFinite(start) || !isFinite(size) || size <= 0) return
    var toStart = Math.abs(along - start)
    var toEnd = Math.abs(along - (start + size))
    var distance = Math.min(toStart, toEnd)
    if (distance < bestDistance) {
      bestDistance = distance
      best = { slot: row.slot, after: toEnd < toStart }
    }
  })
  return best
}

// The edge a bar dragged to `point` goes to: the screen is cut along its
// diagonals, measured in fractions of its size so a wide screen does not
// favour its sides, and the quarter holding the pointer names the edge.
function nearestEdge(point, width, height) {
  var x = width > 0 ? clamp(point.x / width, 0, 1) : 0.5
  var y = height > 0 ? clamp(point.y / height, 0, 1) : 0.5
  var distances = { top: y, bottom: 1 - y, left: x, right: 1 - x }
  var nearest = "top"
  EDGES.forEach(function(name) {
    if (distances[name] < distances[nearest]) nearest = name
  })
  return nearest
}

// A point in a bar window, on its screen: a bottom or right bar's window
// starts that far from the screen's top or left.
function onScreen(point, edgeName, screenWidth, screenHeight, windowWidth, windowHeight) {
  var x = point ? point.x : 0
  var y = point ? point.y : 0
  if (edgeName === "bottom") y += Math.max(0, screenHeight - windowHeight)
  else if (edgeName === "right") x += Math.max(0, screenWidth - windowWidth)
  return { x: x, y: y }
}

// The line drawn where a dragged widget would land: across the bar, at the
// start or the end of the widget at `point` with `width` and `height`.
function dropMarker(point, width, height, after, vertical, thickness) {
  if (vertical) return { x: point.x, y: point.y + (after ? height : 0) - thickness / 2, width: width, height: thickness }
  return { x: point.x + (after ? width : 0) - thickness / 2, y: point.y, width: thickness, height: height }
}

// Where a tooltip <width> by <height> goes beside a widget <widgetWidth> by
// <widgetHeight> on a bar on <edgeName>, in the widget's coordinates: <gap>
// off the widget on its side away from the edge, centred on it along the
// bar.
function tipCorner(edgeName, widgetWidth, widgetHeight, width, height, gap) {
  if (edgeName === "left") return { x: widgetWidth + gap, y: widgetHeight / 2 - height / 2 }
  if (edgeName === "right") return { x: -width - gap, y: widgetHeight / 2 - height / 2 }
  var x = widgetWidth / 2 - width / 2
  return edgeName === "bottom" ? { x: x, y: -height - gap } : { x: x, y: widgetHeight + gap }
}

// "#rrggbb" for channels from 0 to 1.
function hex(red, green, blue) {
  return "#" + [red, green, blue].map(function(channel) {
    var byte = Math.round(clamp(channel, 0, 1) * 255)
    return (byte < 16 ? "0" : "") + byte.toString(16)
  }).join("")
}
