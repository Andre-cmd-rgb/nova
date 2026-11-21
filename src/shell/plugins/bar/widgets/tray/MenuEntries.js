.pragma library

// Which of a tray menu level's entries the card leaves out (TrayMenu): on the
// first level, a first entry that only repeats the app's name (a submenu
// called after it, which some apps put at the top); and on every level a
// separator with nothing shown above it, one right after another, and one
// with nothing shown below it, as Qt's and GTK's own menus leave them out.
// Each entry is a QsMenuEntry or a stand-in with its text, isSeparator and
// hasChildren; the answer is a list as long, true for each left out.
function leftOut(entries, firstLevel, app) {
  const list = Array.isArray(entries) ? entries : []
  const out = list.map(() => false)
  const name = String(app || "").toLowerCase()
  const first = list[0]
  if (firstLevel && name !== "" && first && !first.isSeparator && first.hasChildren
      && String(first.text || "").toLowerCase() === name)
    out[0] = true
  let shownBefore = false
  let pending = -1
  for (let i = 0; i < list.length; i++) {
    if (out[i] || !list[i]) continue
    if (list[i].isSeparator) {
      if (!shownBefore || pending !== -1) out[i] = true
      else pending = i
    } else {
      shownBefore = true
      pending = -1
    }
  }
  if (pending !== -1) out[pending] = true
  return out
}
