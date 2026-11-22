.pragma library
.import "../../Commons/TrayKey.js" as TrayKey

// Settings → Menu Bar's tray icons (TrayIconsView): a row for each icon in
// the tray now that the user can tell apart and each hidden one, and the tray
// widget's `hidden` and `names` settings as a switch changes them. The bar's
// tray shows every icon but those `hidden` names; `names` keeps what each
// hidden one is called, as its app is not there to say once it is hidden and
// gone. Both go by an icon's key (Commons/TrayKey.js): its Id, or its Id and
// Title where apps share an Id, so that hiding Discord leaves Slack.

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

// The rows: each icon of <items> (one a key) and each key in <hidden>, as
// { id, name, hidden, here }, id being the key and here whether its app
// shows it now; by name, whatever its case. One that says nothing goes by
// the name kept for it, or its id.
function rows(items, hidden, names) {
  const away = list(hidden)
  const kept = namesOf(names)
  const all = arrayOf(items)
  const out = []
  const seen = {}
  for (const item of all) {
    const id = TrayKey.idOf(item)
    const key = TrayKey.keyOf(item, all)
    if (id === "" || seen[key]) continue
    // What hides it is listed with it, not as one not running.
    seen[key] = seen[id] = seen[id + "\t" + TrayKey.titleOf(item)] = true
    out.push({ id: key, name: nameOf(item) || String(kept[key] || kept[id] || "") || id,
      hidden: TrayKey.hides(away, item), here: true })
  }
  for (const key of away) {
    if (seen[key]) continue
    seen[key] = true
    out.push({ id: key, name: String(kept[key] || "") || TrayKey.titleIn(key) || TrayKey.idIn(key), hidden: true, here: false })
  }
  return out.sort((one, other) => one.name.toLowerCase().localeCompare(other.name.toLowerCase())
    || one.id.localeCompare(other.id))
}

// <hidden> with <key> added, or the same list when it is there already or
// is none.
function hide(hidden, key) {
  const away = list(hidden)
  return !key || away.indexOf(key) !== -1 ? away : away.concat([key])
}

// The icon among <items> whose key is <key>, or none.
function itemOf(items, key) {
  const all = arrayOf(items)
  return all.find(one => TrayKey.keyOf(one, all) === key)
}

// <hidden> without what hides <key>'s icon: the key, and its Id when that
// hid it with others of <items> (an Id kept alone hides every icon with
// it), which stay hidden by their own keys; for an Id alone, with any key
// of that Id and a title too.
function show(hidden, key, items) {
  const away = list(hidden)
  const id = TrayKey.idIn(key)
  const alone = id === key
  const out = away.filter(one => one !== key && one !== id && !(alone && TrayKey.idIn(one) === id))
  if (!alone && away.indexOf(id) !== -1) {
    const all = arrayOf(items)
    for (const other of all) {
      const theirs = TrayKey.keyOf(other, all)
      if (TrayKey.idOf(other) === id && theirs !== key && out.indexOf(theirs) === -1) out.push(theirs)
    }
  }
  return out
}

// <names> (by key) with <id> called what the icon calls its app. The same
// when it says nothing.
function named(names, id, item) {
  const out = Object.assign({}, namesOf(names))
  const title = nameOf(item)
  if (id && title) out[id] = title
  return out
}
