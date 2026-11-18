.pragma library

// Which tray icons the bar shows: all of them, in the order of their ids, but
// those the owner hid, whose ids the widget's `hidden` setting keeps.

// A setting as a list of ids, or none.
function list(value) {
  return Array.isArray(value) ? value.map(String) : []
}

function idOf(item) {
  return String(item && item.id || "")
}

// The icons to show: <items> but those whose id is in <hidden>, by id, then
// by title, so that the order is the same whichever app registered first.
function shown(items, hidden) {
  const away = list(hidden)
  return (Array.isArray(items) ? items : []).filter(item => away.indexOf(idOf(item)) === -1)
    .sort((one, other) => idOf(one).localeCompare(idOf(other))
      || String(one.title || "").localeCompare(String(other.title || "")))
}

// <hidden> with <id> added, or the same list when it is there already or
// is none.
function hide(hidden, id) {
  const away = list(hidden)
  return !id || away.indexOf(id) !== -1 ? away : away.concat([id])
}
