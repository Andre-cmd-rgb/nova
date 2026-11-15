.pragma library

// What the menu knows, apart from how it is drawn: menu.jsonc read into a
// catalog of items, the rows the apps and the providers add to it, routes,
// the rows a menu, a search and the chooser list, the list's height, and the
// one bash script that answers every when: and checked:.
//
// A catalog is { items, kids }: items a Map from id to item, in the order
// the items came (the default file's, the user's new ones, then the rows
// added since), and kids a Map from a menu's id to its items, in that order.
// No function here changes a catalog it is handed; each change is a new
// one, which the menu puts in place of the old.
//
// An item is { id, parent, kind, icon, label, line, title, command,
// provider, aliases, when, checked, order, haystack, words }; an app's has
// its appId and appIcon too, and a provider's row the menu it fills
// (filling). kind is "menu", "action" or "app"; line is the app's generic
// name, "" for the rest; order is the item's place among the items when it
// came.

// ---------------------------------------------------------------- menu.jsonc

// menu.jsonc as JSON: its comments out, // to the end of the line and /* to
// */, then each comma before a } or a ] dropped; neither inside a string,
// where a label or a command may hold "//", "/*" or ",}" of its own. Each
// pass matches the strings too, first, and gives them back as they are.
const COMMENT = /"(?:[^"\\]|\\[\s\S])*"|\/\/[^\n]*|\/\*[\s\S]*?\*\//g
const LAST_COMMA = /"(?:[^"\\]|\\[\s\S])*"|,(?=\s*[}\]])/g

function asJson(text) {
  const blank = found => found[0] === '"' ? found : " "
  return String(text || "").replace(COMMENT, blank).replace(LAST_COMMA, blank)
}

// A menu file's entries as written, a Map from id to the fields it gives:
// empty for a file that is blank or not JSON. The fields are made into an
// item only once both files are read: a user's entry names only what it
// changes.
function readMenuFile(text) {
  const entries = new Map()
  let parsed = null
  try {
    parsed = JSON.parse(asJson(text))
  } catch (notJson) {
    return entries
  }
  if (!isFields(parsed)) return entries
  for (const id in parsed) {
    if (id && isFields(parsed[id])) entries.set(id, parsed[id])
  }
  return entries
}

function isFields(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

// The catalog of Nova's entries with the user's laid over them a field at a
// time, and a root, Go, first when neither file has one.
function catalogOf(shipped, mine) {
  const merged = new Map()
  for (const file of [shipped, mine]) {
    for (const [id, fields] of file || []) merged.set(id, Object.assign({}, merged.get(id), fields))
  }
  const items = merged.has("root") ? [] : [fileItem("root", { label: "Go" })]
  for (const [id, fields] of merged) items.push(fileItem(id, fields))
  return catalogFrom(items.map((item, place) => Object.assign(item, { order: place })))
}

// An entry as an item. It sits in the menu its id extends (capture in the
// root, capture.screenrecord in capture); one with an action runs it, any
// other is a menu.
function fileItem(id, fields) {
  return searchable({
    id: id,
    parent: id === "root" ? "" : id.includes(".") ? id.slice(0, id.lastIndexOf(".")) : "root",
    kind: fields.action ? "action" : "menu",
    icon: text(fields.icon),
    label: text(fields.label) || id,
    line: "",
    title: text(fields.title),
    command: text(fields.action),
    provider: text(fields.provider),
    aliases: Array.isArray(fields.aliases) ? fields.aliases.filter(Boolean) : [],
    when: text(fields.when),
    checked: text(fields.checked)
  })
}

// A field as text: JSON lets a label be 2048 or true, and the rows and the
// search read text.
function text(value) {
  return value ? String(value) : ""
}

function catalogFrom(items) {
  const catalog = { items: new Map(), kids: new Map() }
  for (const item of items) {
    catalog.items.set(item.id, item)
    if (!catalog.kids.has(item.parent)) catalog.kids.set(item.parent, [])
    catalog.kids.get(item.parent).push(item)
  }
  return catalog
}

// ----------------------------------------------------------- the rows added

// The catalog without the items <old> picks, and with <fresh> after the
// rest, each with its place among them then; one whose id is taken is left
// out.
function swapped(catalog, old, fresh) {
  const items = Array.from(catalog.items.values()).filter(item => !old(item))
  const ids = new Set(items.map(item => item.id))
  for (const item of fresh) {
    if (ids.has(item.id)) continue
    ids.add(item.id)
    items.push(Object.assign(item, { order: items.length }))
  }
  return catalogFrom(items)
}

// The Apps menu's items, from the shell's app library, in its order. An app
// is found by its name, the line under it (its generic name) and its
// Keywords, and by the words of that line taken whole.
function appItems(library) {
  return library.sortedEntries().map(row => {
    const entry = row.entry
    const appId = String(entry.id || "")
    if (!appId) return null
    const line = library.entrySubtext(entry)
    let keywords = []
    try {
      keywords = Array.from(entry.keywords || [])
    } catch (unreadable) { }
    return searchable({
      id: "apps." + appId, parent: "apps", kind: "app", icon: "", label: library.entryName(entry), line: line,
      title: "", command: "", provider: "", aliases: (line ? [line] : []).concat(keywords), when: "", checked: "",
      appId: appId, appIcon: String(entry.icon || "")
    })
  }).filter(Boolean)
}

function withApps(catalog, apps) {
  return swapped(catalog, item => item.kind === "app", apps)
}

// A bash provider's items for the menu <menuId>, from what it printed: the
// value set now on the first line, then a value a line. The one set now has
// a ✓ for its glyph, and each runs commandFor(value). Values that make the
// same id (Fira Code and Fira-Code) get one each.
function providerItems(menuId, printed, glyph, commandFor) {
  const lines = String(printed || "").split("\n").map(line => line.trim())
  const now = lines.shift()
  const ids = new Set()
  return lines.filter(Boolean).map(value => {
    let id = menuId + "." + (value.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean).join("-") || "item")
    while (ids.has(id)) id += "-"
    ids.add(id)
    return searchable({
      id: id, parent: menuId, filling: menuId, kind: "action", icon: value === now ? "✓" : glyph, label: value,
      line: "", title: "", command: commandFor(value), provider: "", aliases: [], when: "", checked: ""
    })
  })
}

// The catalog with the rows the provider of <menuId> gave last time
// swapped for <fresh>: a value it no longer gives goes, and the menu's own
// entries stay.
function withFilled(catalog, menuId, fresh) {
  return swapped(catalog, item => item.filling === menuId, fresh)
}

// ------------------------------------------------------------------ the tree

// The ids above an item, its menu's first: up to the root, or to the first
// that is not in the catalog.
function above(catalog, item) {
  const ids = []
  for (let at = item; at && at.parent; at = catalog.items.get(at.parent)) ids.push(at.parent)
  return ids
}

// What `nova menu <route>` opens: an id, else the first item with the route
// among its aliases, either in any case and with _ for -; else the route as
// it is, which opens the root. Apps are never a route: their aliases are
// their Keywords, and an app could take a menu's name (htop has "system").
function resolve(catalog, route) {
  const plain = name => String(name).toLowerCase().replace(/_/g, "-")
  const wanted = plain(route)
  if (catalog.items.has(wanted)) return wanted
  for (const item of catalog.items.values()) {
    if (item.kind !== "app" && item.aliases.some(alias => plain(alias) === wanted)) return item.id
  }
  return wanted
}

// Whether a row shows: not when its when: said no, and a menu only while
// it has a row to show or a provider to fill it.
function shows(catalog, item, answers) {
  if (item.when && answers.when.get(item.id) === false) return false
  if (item.kind !== "menu" || item.provider) return true
  return (catalog.kids.get(item.id) || []).some(kid => shows(catalog, kid, answers))
}

// "Update › Restart › Shell": the labels from below the root down to the
// item, or "" for none.
function pathOf(catalog, item) {
  if (!item || item.id === "root") return ""
  const menus = above(catalog, item).map(id => catalog.items.get(id)).filter(menu => menu && menu.id !== "root")
  return menus.reverse().map(menu => menu.label).concat([item.label]).join(" › ")
}

// -------------------------------------------------------------------- search

// What a search reads of an item, made with it: its label, the last part of
// its id and its aliases, with . _ and - as spaces, as one text; and the
// words of its line, which match only whole.
function searchable(item) {
  const spaced = value => String(value).replace(/[._-]+/g, " ")
  item.haystack = [item.label, spaced(item.id.split(".").pop()), item.aliases.map(spaced).join(" ")].join(" ").toLowerCase()
  item.words = item.line.toLowerCase().split(/\s+/)
  return item
}

// How good a find is, lower first. Its tier: the label is the search,
// starts with it or holds it; the haystack holds it; the line has each of
// its words. A menu goes a little ahead within its tier and an app further,
// as the apps come after every entry of menu.jsonc, which a tie goes by.
// Then the shallower, then the earlier.
function rank(item, wanted, terms, depth) {
  const label = item.label.toLowerCase()
  const tiers = [
    [label === wanted && item.parent !== "root", 0],
    [label === wanted, 2],
    // An app whose name has the search as a word ("zen" in Zen Browser) is
    // as good as an exact label, such as Zen in a menu.
    [item.kind === "app" && label.split(/\s+/).includes(wanted), 0],
    [label.startsWith(wanted), 10],
    [label.includes(wanted), 30],
    [item.haystack.includes(wanted), 40],
    [terms.every(term => item.words.includes(term)), 60],
    [true, 80]
  ]
  const tier = tiers.find(([holds]) => holds)[1] - ({ menu: 2, app: 5 }[item.kind] || 0)
  return tier * 1000 + depth * 25 + item.order
}

// What the search <query> finds under the menu <menuId>: the menu's own
// items best first, then those deeper down best first, under a divider when
// there are both, each with the path of the menu it is in. A menu whose
// when: said no keeps what is under it from the search too, down to the
// menu searched.
function searchRows(catalog, menuId, query, answers) {
  const wanted = String(query).trim().toLowerCase()
  const terms = wanted.split(/\s+/).filter(Boolean)
  const near = [], deeper = []
  for (const item of catalog.items.values()) {
    const menus = above(catalog, item)
    if (item.id === "root" || menuId !== "root" && !menus.includes(menuId)) continue
    if (!terms.every(term => item.haystack.includes(term) || item.words.includes(term))) continue
    if (!shows(catalog, item, answers) || hiddenBetween(catalog, menus, menuId, answers)) continue
    const depth = menus.filter(id => id !== "root").length
    ;(item.parent === menuId ? near : deeper).push({ item: item, rank: rank(item, wanted, terms, depth), path: pathOf(catalog, item) })
  }
  const best = (a, b) => a.rank - b.rank || a.path.localeCompare(b.path)
  const section = near.length && deeper.length ? "deeper" : ""
  const row = (find, under) => listRow(find.item, answers, pathOf(catalog, catalog.items.get(find.item.parent)), under)
  return near.sort(best).map(find => row(find, "")).concat(deeper.sort(best).map(find => row(find, section)))
}

function hiddenBetween(catalog, menus, menuId, answers) {
  for (const id of menus) {
    const menu = catalog.items.get(id)
    if (id === menuId || !menu) return false
    if (menu.when && answers.when.get(id) === false) return true
  }
  return false
}

// ----------------------------------------------------------- the list's rows

// A row of the list, as its model holds it: the item it is, what it does,
// and the line under it.
function listRow(item, answers, line, section) {
  return {
    key: item.id,
    kind: item.kind,
    glyph: item.icon,
    appIcon: item.appIcon || "",
    appId: item.appId || "",
    label: item.checked && answers.checked.get(item.id) ? item.label + " ✓" : item.label,
    line: line,
    command: item.command,
    section: section
  }
}

// The rows of the menu <menuId>, in the order of menu.jsonc; the apps by
// name, as DesktopEntries may list them in another order now. An app's line
// shows under it once anything is typed, blanks too, which search nothing.
function menuRows(catalog, menuId, answers, lined) {
  const rows = (catalog.kids.get(menuId) || []).filter(item => shows(catalog, item, answers))
    .map(item => listRow(item, answers, lined ? item.line : "", ""))
  const name = row => row.label.toLowerCase()
  const byName = (a, b) => name(a) < name(b) ? -1 : name(a) > name(b) ? 1 : a.key < b.key ? -1 : a.key > b.key ? 1 : 0
  return menuId === "apps" ? rows.sort(byName) : rows
}

// The chooser's rows: its options that hold <query> in the label or in the
// line under it. An option is "label", "glyph<TAB>label" or
// "glyph<TAB>label<TAB>line"; the glyph is drawn and never given back.
function choiceRows(options, query) {
  const wanted = String(query).trim().toLowerCase()
  const holds = row => row.label.toLowerCase().includes(wanted) || row.line.toLowerCase().includes(wanted)
  return options.map(option => {
    const parts = String(option || "").split("\t")
    const glyph = parts.length > 1 ? parts.shift() : ""
    const label = parts.shift()
    return { key: "", kind: "choice", glyph: glyph, appIcon: "", appId: "", label: label, line: parts.join("\t"), command: "", section: "" }
  }).filter(row => !wanted || holds(row))
}

// --------------------------------------------------------- the list's height

// How tall the list is in <room>: all of it when it fits. When it does not,
// it ends size.peek into a row, never on a row's edge: the row cut short is
// what says there is more below. One cut above its first row's peek takes
// the room, never less than a row, which is also the height of no rows. A
// row is size.tall with a line under it and size.row without, size.gap
// apart, and size.divider more above the first of a search's deeper rows.
function listHeight(rows, room, size) {
  if (!rows.length) return size.row
  const ends = []
  rows.reduce((end, row, i) => {
    const divider = row.section === "deeper" && (i === 0 || rows[i - 1].section !== "deeper") ? size.divider : 0
    ends.push((i === 0 ? 0 : end + size.gap) + divider + (row.line ? size.tall : size.row))
    return ends[i]
  }, 0)
  if (ends[ends.length - 1] <= room) return ends[ends.length - 1]
  let whole = ends.findIndex(end => end > room)
  while (whole > 1 && ends[whole - 1] + size.gap + size.peek > room) whole--
  return whole < 1 ? Math.max(room, size.row) : ends[whole - 1] + size.gap + size.peek
}

// ------------------------------------------------------- when: and checked:

// Commands a checked: reads a value out of, which rows side by side ask
// alike: Style › Menu Bar's rows compare `nova-bar position`. The script
// runs each once, first, and a guard's `$(command)` reads what it printed
// instead: both drop the trailing newlines and split alike unquoted. Only
// that form is swapped; `command -v nova-bar` or `X=1 nova-bar position`
// still run the command. Each is read before the guards, as each guard runs
// in a subshell, and what one kept would be gone by the next.
const SHARED_READS = ["nova-bar position", "nova-bar transparent"]

function quoted(text) {
  return "'" + String(text).replace(/'/g, "'\\''") + "'"
}

// One bash script for every when: (w) and checked: (c) of the catalog, ""
// when there is none. Each guard runs by eval in a subshell of its own, so
// that one bash cannot read is a no for its own row alone, and one that
// exits, sets a variable or changes directory does so for itself. Each
// prints a line, "w1 <id>" or "w0 <id>": the id last, as it may hold
// anything. The menu opens on the last answers, so the time this takes is
// how long a row can be wrong.
function guardScript(catalog) {
  const shared = n => "${__nova_shared_" + n + "}"
  let guards = ""
  for (const item of catalog.items.values()) {
    for (const [tag, test] of [["w", item.when], ["c", item.checked]]) {
      if (!test) continue
      const read = SHARED_READS.reduce((line, command, n) => line.split("$(" + command + ")").join(shared(n)), test)
      const id = quoted(item.id)
      guards += "if ( eval " + quoted(read) + " ) >/dev/null 2>&1; then echo " + tag + "1 " + id + "; else echo " + tag + "0 " + id + "; fi\n"
    }
  }
  if (!guards) return ""
  // `|| :` keeps a command that fails from ending the script in a login
  // shell that sets errexit.
  const reads = SHARED_READS.map((command, n) => guards.includes(shared(n)) ? "__nova_shared_" + n + "=$(" + command + " 2>/dev/null) || :\n" : "")
  return reads.join("") + guards
}

// The guard script's answers: { when, checked }, each a Map from an id to
// whether its guard said yes.
function readAnswers(printed) {
  const answers = noAnswers()
  for (const line of String(printed || "").split("\n")) {
    const into = { w: answers.when, c: answers.checked }[line[0]]
    if (into && /^.[01] /.test(line)) into.set(line.slice(3), line[1] === "1")
  }
  return answers
}

function noAnswers() {
  return { when: new Map(), checked: new Map() }
}
