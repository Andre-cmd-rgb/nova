.pragma library
.import "../../../../Commons/TrayKey.js" as TrayKey

// Which tray icons the bar shows: all of them, in the order of their ids, but
// those the owner hid, which the widget's `hidden` setting names (Settings →
// Menu Bar writes it, and `names`, what each hidden one is called): by Id, or
// by Id and Title where apps share an Id (Commons/TrayKey.js).

// A setting as a list of ids, or none.
function list(value) {
  return Array.isArray(value) ? value.map(String) : []
}

function idOf(item) {
  return String(item && item.id || "")
}

// The icons to show: <items> but those <hidden> names, by id, then by title,
// so that the order is the same whichever app registered first.
function shown(items, hidden) {
  const away = list(hidden)
  return (Array.isArray(items) ? items : []).filter(item => !TrayKey.hides(away, item))
    .sort((one, other) => idOf(one).localeCompare(idOf(other))
      || String(one.title || "").localeCompare(String(other.title || "")))
}
