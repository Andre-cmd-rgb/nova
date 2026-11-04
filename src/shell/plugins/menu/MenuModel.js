.pragma library

// The menu's rules, kept apart from its window: reading menu.jsonc into a
// tree of items, the rows the apps and the providers add to it, routes, what
// a menu and a search list, the list's height, and the one bash script that
// answers every when: and checked:.
//
// A tree is { items: { id: item }, itemOrder: [id] }. Every change makes a
// new one, and none of these functions writes into the tree it is handed:
// the menu keeps its tree in a QML property, and a key written into an
// object held there is now and then lost: an id left in the order with no
// item behind it, or an app listed twice.

// ---- menu.jsonc

// JSONC as JSON: the comments out, // to the end of the line and /* to */,
// then a comma before a } or ] dropped. Neither inside a string, where a
// label or a command may hold "//", "/*" or ",}" of its own.
function jsonText(raw) {
  var text = String(raw || "").replace(/"(?:[^"\\]|\\[\s\S])*"|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, blankUnlessString)
  return text.replace(/"(?:[^"\\]|\\[\s\S])*"|,(?=\s*[}\]])/g, blankUnlessString)
}

function blankUnlessString(found) {
  return found.charAt(0) === '"' ? found : " "
}

// The entries of a menu file as written, each an object with its id: [] for
// a file that is empty or not JSON. They are made into items only once the
// two files are merged: a user's entry names only what it changes, and the
// defaults filled in here would overwrite the rest.
function parseMenuJsonc(raw) {
  var text = jsonText(raw)
  if (!text.trim()) return []
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (notJson) {
    return []
  }
  if (typeof parsed !== "object" || parsed === null) return []

  var entries = []
  for (var id in parsed) {
    var fields = parsed[id]
    if (!fields || typeof fields !== "object" || Array.isArray(fields)) continue
    var entry = { id: id }
    for (var key in fields) if (key !== "id") entry[key] = fields[key]
    entries.push(entry)
  }
  return entries
}

// The tree of the default file's entries with the user's on top, a field at
// a time. An entry sits under the id its own id extends (capture.screenrecord
// under capture); a root is added when neither file has one. Each item's
// order is its place in itemOrder.
function mergeMenuSources(defaults, user) {
  var fields = byId()
  var order = []
  ;[defaults || [], user || []].forEach(function(entries) {
    entries.forEach(function(entry) {
      if (!entry || !entry.id) return
      if (!fields[entry.id]) order.push(entry.id)
      var merged = {}
      var before = fields[entry.id] || {}
      for (var a in before) merged[a] = before[a]
      for (var b in entry) merged[b] = entry[b]
      merged.id = entry.id
      fields[entry.id] = merged
    })
  })

  var items = byId()
  order.forEach(function(id) { items[id] = menuItem(id, fields[id]) })
  if (!items.root) {
    items.root = searchable({ id: "root", parent: "", kind: "menu", icon: "", label: "Go", title: "", description: "", aliases: [], when: "", checked: "", action: "", provider: "" })
    order.unshift("root")
  }
  order.forEach(function(id, place) { items[id].order = place })
  return { items: items, itemOrder: order }
}

// An item from its merged fields. One with an action runs it, anything else
// is a menu of its own.
function menuItem(id, fields) {
  var value = fields || {}
  var parent = id.indexOf(".") >= 0 ? id.slice(0, id.lastIndexOf(".")) : "root"
  if (id === "root") parent = ""
  return searchable({
    id: id,
    parent: parent,
    kind: value.action ? "action" : "menu",
    icon: asText(value.icon),
    label: asText(value.label) || id,
    title: asText(value.title),
    description: "",
    action: asText(value.action),
    provider: asText(value.provider),
    aliases: aliasList(value.aliases),
    when: asText(value.when),
    checked: asText(value.checked)
  })
}

// A field as text. JSON lets a label be 2048 or true, but the list's rows
// and search take text.
function asText(value) {
  return value ? String(value) : ""
}

// "aliases" as written, a list.
function aliasList(value) {
  return Array.isArray(value) ? value.filter(function(alias) { return alias }) : []
}

// ---- Rows the providers add

// The Apps menu's rows for AppLibrary's sorted entries, with their names
// and the lines under them as AppLibrary gives them. The line and the
// entry's Keywords are what search finds an app by besides its name.
function appItems(sorted, nameOf, subtextOf) {
  var apps = []
  sorted.forEach(function(row) {
    var entry = row.entry
    var appId = String(entry.id || "")
    if (!appId) return
    var subtext = subtextOf(entry)
    var aliases = subtext ? [subtext] : []
    try {
      if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
    } catch (unreadable) { }
    apps.push(searchable({ id: "apps." + appId, parent: "apps", kind: "app", icon: "", appIcon: String(entry.icon || ""), appId: appId, label: nameOf(entry), title: "", description: subtext, action: "", provider: "", aliases: aliases, when: "", checked: "", order: 0 }))
  })
  return apps
}

// The tree with its apps swapped for <apps>, in the order given, each listed
// once; every other item keeps its place. An id in the order with no item
// is dropped rather than carried on.
function withApps(tree, apps) {
  return rebuilt(tree, function(item) { return item.kind === "app" }, apps)
}

// A bash provider's rows for the menu <menuId>, from what it printed: a
// "label<TAB>value<TAB>current" line each. The row whose value is current
// has a ✓ for its icon, and picking a row runs actionFor(value). Values
// that make the same id (Fira Code and Fira-Code) get one each.
function providerItems(menuId, text, icon, actionFor) {
  var rows = []
  var taken = byId()
  String(text || "").split("\n").forEach(function(line) {
    var parts = line.trim().split("\t")
    var label = parts[0] || ""
    var value = parts[1] || label
    if (!label) return
    var id = menuId + "." + slugify(value)
    while (taken[id]) id += "-"
    taken[id] = true
    rows.push(searchable({ id: id, parent: menuId, providerMenu: menuId, kind: "action", icon: value === (parts[2] || "") ? "✓" : icon || "", label: label, title: "", description: "", action: actionFor(value), provider: "", aliases: [], when: "", checked: "", order: 0 }))
  })
  return rows
}

// The tree with the rows the provider of <menuId> gave last time swapped for
// <rows>, so that a provider run again drops the rows it no longer gives;
// the menu's own items in menu.jsonc stay.
function withProviderRows(tree, menuId, rows) {
  return rebuilt(tree, function(item) { return item.providerMenu === menuId }, rows)
}

// The tree without the items <dropped> picks, with <added> after the rest;
// an added id already taken is left out.
function rebuilt(tree, dropped, added) {
  var items = byId()
  var order = []
  tree.itemOrder.forEach(function(id) {
    var item = tree.items[id]
    if (!item || dropped(item)) return
    items[id] = item
    order.push(id)
  })
  added.forEach(function(row) {
    if (!row || !row.id || items[row.id]) return
    row.order = order.length
    items[row.id] = row
    order.push(row.id)
  })
  return { items: items, itemOrder: order }
}

function slugify(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "item"
}

// ---- The tree

// A map by id that holds only what is put in it. A plain {} already has a
// constructor, a toString and the rest, and an entry of one of those names
// would be taken for one that is there, and never listed.
function byId() {
  return Object.create(null)
}

function item(items, id) {
  return items && items[id] ? items[id] : null
}

// What `nova menu <route>` opens: nothing is the root; otherwise an id,
// else the first item with the route as an alias, case and _ for - aside.
// Apps are never a route: their aliases are their Keywords, and an app could
// take a menu's name (htop has "system"). Anything else is tried as an id as
// it was written, and opens the root when there is none.
function resolveRoute(tree, route) {
  var name = String(route || "").toLowerCase().replace(/_/g, "-")
  if (!name) return "root"
  if (item(tree.items, name)) return name
  for (var i = 0; i < tree.itemOrder.length; i++) {
    var entry = item(tree.items, tree.itemOrder[i])
    if (!entry || entry.kind === "app" || !entry.aliases) continue
    for (var j = 0; j < entry.aliases.length; j++) {
      if (String(entry.aliases[j] || "").toLowerCase().replace(/_/g, "-") === name) return entry.id
    }
  }
  return name
}

// How many menus down from the root's own items an item is. A walk up the
// tree stops after 32 steps, for a user's menus that are each other's parent.
function depth(items, id) {
  var steps = 0
  for (var at = item(items, id); at && at.parent && at.parent !== "root" && steps < 32; at = item(items, at.parent)) steps++
  return steps
}

// "Update › Restart › Shell": the labels from the root down to the item.
function path(items, id) {
  var labels = []
  for (var at = item(items, id); at && at.id !== "root" && labels.length < 32; at = item(items, at.parent)) labels.unshift(at.label)
  return labels.join(" › ")
}

function isUnder(items, id, menuId) {
  if (menuId === "root") return id !== "root"
  var steps = 0
  for (var at = item(items, id); at && at.parent && steps < 32; at = item(items, at.parent), steps++) {
    if (at.parent === menuId) return true
  }
  return false
}

// Whether a menu between <menuId> and the entry said no in its when:, which
// hides what is under it from search as well.
function hiddenAbove(items, whenResults, entry, menuId) {
  if (!whenResults) return false
  var steps = 0
  for (var at = item(items, entry.parent); at && at.id !== menuId && steps < 32; at = item(items, at.parent), steps++) {
    if (at.when && whenResults[at.id] === false) return true
  }
  return false
}

// Whether a row shows: not when its when: said no; a menu only with a row of
// its own to show, or a provider that fills it.
function isShown(tree, whenResults, entry, steps) {
  if (!entry) return false
  if (entry.when && whenResults && whenResults[entry.id] === false) return false
  if (entry.kind !== "menu") return true
  if (entry.provider) return true
  var deeper = steps || 0
  if (deeper >= 32) return false
  for (var i = 0; i < tree.itemOrder.length; i++) {
    var child = item(tree.items, tree.itemOrder[i])
    if (child && child.parent === entry.id && isShown(tree, whenResults, child, deeper + 1)) return true
  }
  return false
}

// ---- Search

// What search reads of an item, made once with it: its label, the last part
// of its id and its aliases as one text, with . _ and - as spaces; and the
// words of its description, which match only whole.
function searchable(entry) {
  var aliases = (Array.isArray(entry.aliases) ? entry.aliases : []).map(spaced)
  var leaf = String(entry.id || "").split(".").pop()
  entry.searchName = [entry.label, spaced(leaf), aliases.join(" ")].join(" ").toLowerCase()
  entry.searchWords = String(entry.description || "").toLowerCase().split(/\s+/)
  return entry
}

function spaced(value) {
  return String(value || "").replace(/[._-]+/g, " ")
}

function searchOf(query) {
  var text = String(query || "").toLowerCase().trim()
  return { text: text, terms: text.split(/\s+/).filter(function(term) { return term }) }
}

// Every word of the search is in the item's name, or a word of its
// description.
function finds(entry, search) {
  return search.terms.every(function(term) {
    return entry.searchName.indexOf(term) >= 0 || entry.searchWords.indexOf(term) >= 0
  })
}

// A rank for a find, lower first: the label is the search, starts with it,
// holds it, the name does, the description has every word; a menu a little
// ahead of a command, and an app further, but within its tier. Then the
// shallower first, then the order of menu.jsonc.
function rank(items, entry, search) {
  var label = entry.label.toLowerCase()
  var needle = search.text
  var tier = 80
  if (label === needle) tier = entry.parent === "root" ? 2 : 0
  // An app whose name has the search as a word ("zen" in Zen Browser) is as
  // good as an exact label, such as a menu's Zen.
  else if (entry.kind === "app" && label.split(/\s+/).indexOf(needle) >= 0) tier = 0
  else if (label.indexOf(needle) === 0) tier = 10
  else if (label.indexOf(needle) >= 0) tier = 30
  else if (entry.searchName.indexOf(needle) >= 0) tier = 40
  else if (search.terms.every(function(term) { return entry.searchWords.indexOf(term) >= 0 })) tier = 60

  if (entry.kind === "menu") tier -= 2
  // Apps come after every menu item in the order, which a tie goes by; this
  // puts them ahead of an equal find without passing a better one.
  if (entry.kind === "app") tier -= 5
  return tier * 1000 + depth(items, entry.id) * 25 + entry.order
}

// ---- The list's rows

// A row of the list, as its model holds it: the item, what it opens or runs,
// and the line under it.
function listRow(entry, checkedResults, detail, section) {
  var checked = entry.checked && checkedResults && checkedResults[entry.id]
  return {
    itemId: entry.id,
    kind: entry.kind,
    icon: entry.icon,
    appIcon: entry.appIcon || "",
    appId: entry.appId || "",
    label: checked ? entry.label + " ✓" : entry.label,
    detail: detail || "",
    action: entry.action || "",
    section: section || ""
  }
}

// The rows of the menu <menuId>, in the order of menu.jsonc; the apps by
// name, whatever order DesktopEntries has them in now.
function menuRows(tree, menuId, whenResults, checkedResults) {
  var rows = []
  tree.itemOrder.forEach(function(id) {
    var entry = item(tree.items, id)
    if (!entry || entry.parent !== menuId || !isShown(tree, whenResults, entry)) return
    rows.push(listRow(entry, checkedResults, entry.description, ""))
  })
  if (menuId === "apps") rows.sort(byName)
  return rows
}

function byName(a, b) {
  var left = String(a.label || "").toLowerCase()
  var right = String(b.label || "").toLowerCase()
  if (left !== right) return left < right ? -1 : 1
  var leftId = String(a.itemId || "")
  var rightId = String(b.itemId || "")
  return leftId < rightId ? -1 : leftId > rightId ? 1 : 0
}

// What a search finds under the menu <menuId>, each row with the path of the
// menu it is in: the menu's own items best first, then those deeper down
// best first, under a divider when there are both.
function searchRows(tree, menuId, query, whenResults, checkedResults) {
  var search = searchOf(query)
  var near = []
  var deeper = []
  tree.itemOrder.forEach(function(id) {
    var entry = item(tree.items, id)
    if (!entry || entry.id === "root" || !isUnder(tree.items, entry.id, menuId)) return
    if (!finds(entry, search) || !isShown(tree, whenResults, entry) || hiddenAbove(tree.items, whenResults, entry, menuId)) return
    var found = { entry: entry, rank: rank(tree.items, entry, search), path: path(tree.items, entry.id) }
    if (entry.parent === menuId) near.push(found)
    else deeper.push(found)
  })
  near.sort(bestFirst)
  deeper.sort(bestFirst)
  var section = near.length > 0 && deeper.length > 0 ? "drilldown" : ""
  function row(found, under) {
    var parent = found.entry.parent
    var where = parent && parent !== "root" ? path(tree.items, parent) : ""
    return listRow(found.entry, checkedResults, where, under)
  }
  return near.map(function(found) { return row(found, "") }).concat(deeper.map(function(found) { return row(found, section) }))
}

function bestFirst(a, b) {
  return a.rank !== b.rank ? a.rank - b.rank : a.path.localeCompare(b.path)
}

// The chooser's rows for its options, those that hold <query> in the label
// or the line under it. An option is "label", "glyph<TAB>label" or
// "glyph<TAB>label<TAB>line"; the glyph is drawn and never given back.
function chooserRows(options, query) {
  var needle = String(query || "").trim().toLowerCase()
  var rows = []
  options.forEach(function(option, index) {
    var parts = String(option || "").split("\t")
    var icon = parts.length > 1 ? parts.shift() : ""
    var label = parts.shift() || ""
    var line = parts.join("\t")
    if (needle && label.toLowerCase().indexOf(needle) < 0 && line.toLowerCase().indexOf(needle) < 0) return
    rows.push({ itemId: "choice." + index, kind: "choice", icon: icon, appIcon: "", appId: "", label: label, detail: line, action: "", section: "" })
  })
  return rows
}

// ---- The list's height

// Where each row ends, from the top of the list: <spacing> between rows, a
// divider's height above the first of a search's deeper rows, and a row
// <withLine> tall where it has a line under it, <plain> otherwise.
function rowBottoms(rows, plain, withLine, spacing, divider) {
  var bottoms = []
  var bottom = 0
  rows.forEach(function(row, i) {
    if (i > 0) bottom += spacing
    if (row.section === "drilldown" && (i === 0 || rows[i - 1].section !== "drilldown")) bottom += divider
    bottom += row.detail ? withLine : plain
    bottoms.push(bottom)
  })
  return bottoms
}

// The list's height in <room>: all of it when it fits. When it does not, the
// list ends <peek> into a row, never on a row's edge: the row cut short is
// what shows there is more below. A list cut above its first row's peek
// takes the room, but never less than one row (<least>), which is also the
// height of a list with no rows.
function foldedHeight(bottoms, room, peek, spacing, least) {
  var count = bottoms.length
  if (count === 0) return least
  if (bottoms[count - 1] <= room) return bottoms[count - 1]
  var whole = 0
  while (whole < count && bottoms[whole] <= room) whole++
  while (whole > 1 && bottoms[whole - 1] + spacing + peek > room) whole--
  if (whole < 1) return Math.max(room, least)
  return bottoms[whole - 1] + spacing + peek
}

// ---- when: and checked:

// Commands a `checked:` reads a value out of, which rows side by side ask
// alike: Style > Menu Bar's two rows both compare `nova-bar position`. The
// script runs each once, first, and the rows read what it printed. They are
// read eagerly: each guard runs in a subshell, and a value one kept there
// would be gone by the next.
var GUARD_READERS = ["nova-bar position", "nova-bar transparent"]

function readerSlot(index) {
  return "${__nova_read_" + index + "}"
}

// A reader's `$(command)` in an expression is the variable holding what it
// printed: both drop trailing newlines and split alike unquoted. Only that
// form is: a function in its place would also answer `command -v reader`
// or `VAR=x reader`, wrongly, which run the real command instead.
function withReaders(expression) {
  return GUARD_READERS.reduce(function(text, reader, index) {
    return text.split("$(" + reader + ")").join(readerSlot(index))
  }, expression)
}

// A guard's line. Its expression runs by eval in a subshell of its own, so
// that one bash cannot read fails alone, as a no, and one that exits, execs,
// or changes the shell (cd, set, a variable) does so for itself, not for the
// script and every answer after it. Its id is quoted, for the same reason:
// any id prints as it is.
function guardLine(id, tag, expression) {
  var answer = quoted(id + ":" + tag + ":")
  return "if ( eval " + quoted(withReaders(expression)) + " ) >/dev/null 2>&1; then echo " + answer + "1; else echo " + answer + "0; fi\n"
}

function quoted(text) {
  return "'" + String(text).replace(/'/g, "'\\''") + "'"
}

// One bash script for every when: and checked: of the tree, printing
// "<id>:<w|c>:<1|0>" for each, or "" for a tree with none. The menu opens on
// the last answers, so the time this takes is how long a row can be wrong.
function guardScript(items) {
  var lines = ""
  Object.keys(items || {}).forEach(function(id) {
    var entry = items[id]
    if (!entry) return
    if (entry.when) lines += guardLine(id, "w", entry.when)
    if (entry.checked) lines += guardLine(id, "c", entry.checked)
  })
  if (!lines) return ""
  var readers = GUARD_READERS.map(function(reader, index) {
    // `|| :` keeps a reader that fails from ending the script in a login
    // shell that sets errexit.
    return lines.indexOf(readerSlot(index)) < 0 ? "" : "__nova_read_" + index + "=$(" + reader + " 2>/dev/null) || :\n"
  })
  return readers.join("") + lines
}

// The script's answers: { when: { id: bool }, checked: { id: bool } }. An id
// may hold colons; the tag and the answer are the last two fields.
function readGuards(text) {
  var answers = { when: byId(), checked: byId() }
  String(text || "").split("\n").forEach(function(line) {
    var fields = line.trim().split(":")
    if (fields.length < 3) return
    var answer = fields.pop() === "1"
    var tag = fields.pop()
    if (tag === "w") answers.when[fields.join(":")] = answer
    else if (tag === "c") answers.checked[fields.join(":")] = answer
  })
  return answers
}
