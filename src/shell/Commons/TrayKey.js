.pragma library

// What names a tray icon in the tray widget's `hidden` and `names` settings,
// which the bar reads (plugins/bar/widgets/tray/TrayList.js) and Settings →
// Menu Bar writes (plugins/settings/TrayIcons.js): one rule for both.
//
// An icon is known by its StatusNotifierItem Id. Two apps can share one:
// Electron's apps all count chrome_status_icon_1, _2… for themselves, so
// Discord's and Slack's are the same. Such an icon goes by its Id and its
// Title, a tab between, and hiding it hides it alone; any other goes by its
// Id, so that a title that changes does not bring it back. An Id alone, as
// earlier releases kept them, hides every icon with it.

function idOf(item) {
  return String(item && item.id || "")
}

function titleOf(item) {
  return String(item && item.title || "")
}

// Whether <id> says nothing of its app: Chromium's own counter.
function shared(id) {
  return /^chrome_status_icon_[0-9]+$/.test(id)
}

// What names <item> among <items> (those in the tray now): its Id, with its
// Title when the Id says nothing of the app or another icon with a title of
// its own has it too (two the same are one to the user).
function keyOf(item, items) {
  const id = idOf(item)
  const title = titleOf(item)
  const others = (Array.isArray(items) ? items : []).filter(one => idOf(one) === id && titleOf(one) !== title)
  return shared(id) || others.length > 0 ? id + "\t" + title : id
}

// The Id a key names, and the Title, "" for a key that is an Id alone.
function idIn(key) {
  const tab = String(key).indexOf("\t")
  return tab === -1 ? String(key) : String(key).slice(0, tab)
}

function titleIn(key) {
  const tab = String(key).indexOf("\t")
  return tab === -1 ? "" : String(key).slice(tab + 1)
}

// Whether <away>, a list of keys, hides <item>: its Id alone, or its Id with
// its Title.
function hides(away, item) {
  const id = idOf(item)
  return away.indexOf(id) !== -1 || away.indexOf(id + "\t" + titleOf(item)) !== -1
}
