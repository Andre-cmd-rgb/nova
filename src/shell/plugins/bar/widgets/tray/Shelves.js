.pragma library

// Where the tray puts an icon: on the bar ("pinned"), behind the chevron
// ("drawer") or nowhere ("hidden"), by its id and the two lists the widget's
// settings keep, `pinned` and `hidden`. An id on both is hidden.

// A setting as a list, or none.
function list(value) {
  return value instanceof Array ? value : []
}

function shelf(id, pinned, hidden) {
  if (hidden.indexOf(id) !== -1) return "hidden"
  return pinned.indexOf(id) !== -1 ? "pinned" : "drawer"
}

// The lists after <id> is put on the one named <onto> ("pinned" or
// "hidden"), or taken off it when it is there already. Put on one, it comes
// off the other: an icon hidden is unpinned, one pinned shows again.
function flipped(lists, onto, id) {
  var next = { pinned: lists.pinned.slice(), hidden: lists.hidden.slice() }
  var other = onto === "pinned" ? "hidden" : "pinned"
  var at = next[onto].indexOf(id)
  if (at !== -1) {
    next[onto].splice(at, 1)
    return next
  }
  next[onto].push(id)
  var elsewhere = next[other].indexOf(id)
  if (elsewhere !== -1) next[other].splice(elsewhere, 1)
  return next
}

// What the pin list calls an icon: its title, its tooltip's, or the last
// part of its id.
function name(item) {
  var title = String(item.title || "").trim()
  if (title !== "") return title
  var tip = String(item.tooltipTitle || "").trim()
  if (tip !== "") return tip
  var id = String(item.id || "")
  return id === "" ? "Unknown" : id.slice(id.lastIndexOf("/") + 1)
}
