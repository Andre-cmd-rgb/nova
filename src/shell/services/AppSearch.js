.pragma library

// The menu's Apps list: which desktop entries it shows, and in what order.
// The menu finds an app by its own search, over the rows it makes of these.

function entryName(entry) {
  return entry ? String(entry.name || entry.id || "") : ""
}

function entrySubtext(entry) {
  return entry ? String(entry.genericName || "") : ""
}

// The entries to list, as rows of { entry, key } (key is the lowercase
// name), leaving out NoDisplay ones, nameless ones and any <isHidden> says to
// hide. By name; two of one name by their desktop IDs, as the order the
// entries come in changes from one start of the shell to the next.
function sortedEntries(values, isHidden) {
  var rows = []
  for (var i = 0; i < values.length; i++) {
    var entry = values[i]
    var name = entry && !entry.noDisplay && !(isHidden && isHidden(entry)) ? entryName(entry) : ""
    if (name) rows.push({ entry: entry, key: name.toLowerCase() })
  }
  return rows.sort(function(a, b) {
    if (a.key !== b.key) return a.key < b.key ? -1 : 1
    var first = String(a.entry.id || ""), second = String(b.entry.id || "")
    return first < second ? -1 : first > second ? 1 : 0
  })
}

// What runs an app from the menu, as words for Quickshell.execDetached: no
// shell in between. uwsm-app runs it in a scope of its own under
// app-graphical.slice, and finds the entry itself, which honours Terminal,
// Path, TryExec and the Exec's field codes, in about a millisecond in its
// daemon. A DBusActivatable entry is run by its Exec there, as the spec
// keeps one for, rather than activated outside the scope. An ID that uwsm
// will not take (one with a space in it, from a file name) goes through
// gtk-launch, which takes any; it wants the .desktop suffix, or an ID such
// as org.telegram.desktop is not found.
function launchWords(appId) {
  var id = String(appId || "")
  if (!id) return []
  if (/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(id)) return ["uwsm-app", "--", id + ".desktop"]
  return ["uwsm-app", "--", "gtk-launch", id + ".desktop"]
}
