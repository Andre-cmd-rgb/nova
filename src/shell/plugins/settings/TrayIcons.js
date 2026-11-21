.pragma library

// Settings → Menu Bar's tray icons (TrayIconsView): a row for each icon in
// the tray now and each hidden one, and the tray widget's `hidden` and
// `names` settings as a switch changes them. The bar's tray shows every
// icon but those in `hidden`; `names` keeps what each hidden one is called,
// as its app is not there to say once it is hidden and gone.

// <value> as a list: an array, or a list Qt hands over in its own wrapper.
function arrayOf(value) {
  if (Array.isArray(value)) return value
  return value && typeof value === "object" && typeof value.length === "number" ? Array.prototype.slice.call(value) : []
}

// A setting as a list of ids, or none.
function list(value) {
  return arrayOf(value).map(String)
}

function namesOf(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {}
}

// What an icon calls its app: its title, or else its tooltip's, in one line,
// not endless; "" when it says nothing.
function nameOf(item) {
  return String(item && (item.title || item.tooltipTitle) || "").replace(/\s+/g, " ").trim().slice(0, 60)
}

// The rows: each icon of <items> (one an id) and each id in <hidden>, as
// { id, name, hidden, here }, here being whether its app shows it now; by
// name, whatever its case. One that says nothing goes by the name kept for
// it, or its id.
function rows(items, hidden, names) {
  const away = list(hidden)
  const kept = namesOf(names)
  const out = []
  const seen = {}
  for (const item of arrayOf(items)) {
    const id = String(item && item.id || "")
    if (id === "" || seen[id]) continue
    seen[id] = true
    out.push({ id: id, name: nameOf(item) || String(kept[id] || "") || id, hidden: away.indexOf(id) !== -1, here: true })
  }
  for (const id of away) {
    if (seen[id]) continue
    seen[id] = true
    out.push({ id: id, name: String(kept[id] || "") || id, hidden: true, here: false })
  }
  return out.sort((one, other) => one.name.toLowerCase().localeCompare(other.name.toLowerCase())
    || one.id.localeCompare(other.id))
}

// <hidden> with <id> added, or the same list when it is there already or
// is none.
function hide(hidden, id) {
  const away = list(hidden)
  return !id || away.indexOf(id) !== -1 ? away : away.concat([id])
}

// <hidden> without <id>.
function show(hidden, id) {
  return list(hidden).filter(one => one !== id)
}

// <names> (by id) with <id> called what the icon calls its app. The same
// when it says nothing.
function named(names, id, item) {
  const out = Object.assign({}, namesOf(names))
  const title = nameOf(item)
  if (id && title) out[id] = title
  return out
}
