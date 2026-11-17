.pragma library

// The welcome's pages, in the order they come, and which of them come on
// this computer. The installer has asked the rest (the keyboard, the
// account, the computer's name and time zone, a fingerprint where there is a
// reader), so nothing here asks it again.
//
// A page is wanted, or not, at the moment it would come next: a network
// that joins while the first page is read takes the Wi-Fi page away, and
// one joined on the Wi-Fi page brings the apps. What the window knows,
// <facts>:
//   loaded      the state is read (nova-settings state)
//   wifi        a Wi-Fi card
//   onWifi      the card is on a network
//   laptop      a battery: a computer that leaves its cable behind
//   online      NetworkManager finds the internet
//   portal      a network that wants a sign-in first, which a notification
//               offers
//   nightlight  the night light's service is on
//   missing     the packages of Chrome and VS Code that are not installed
//   installing  nova update is installing them now

var order = ["welcome", "wifi", "look", "nightlight", "apps", "keys"]

var pages = {
  welcome: { title: "Welcome to Nova", icon: "" },
  wifi: { title: "Wi-Fi", icon: "󰖩" },
  look: { title: "Appearance", icon: "󰸌" },
  nightlight: { title: "Night Light", icon: "󰔎" },
  apps: { title: "Apps", icon: "󰀻" },
  keys: { title: "Keyboard Shortcuts", icon: "󰌌" }
}

// The Wi-Fi comes without the internet, and on a laptop installed on a
// cable that is still in, which has no Wi-Fi network for when it is out.
function wanted(id, facts) {
  facts = facts || {}
  switch (id) {
  case "wifi": return facts.wifi === true && facts.portal !== true
    && (facts.online !== true || (facts.laptop === true && facts.onWifi !== true))
  case "nightlight": return facts.nightlight === true
  case "apps": return facts.installing === true || (facts.online === true && (facts.missing || []).length > 0)
  default: return order.indexOf(id) >= 0
  }
}

// The page after <from>, or "" after the last.
function next(from, facts) {
  for (var i = order.indexOf(from) + 1; i < order.length; i++)
    if (wanted(order[i], facts)) return order[i]
  return ""
}

// Chrome and VS Code as Settings' state has them installed (apps.browsers
// and apps.editors, by short name), as the packages nova apps install
// builds: those not there. Nothing before the state is read.
function missing(apps) {
  if (!apps || !apps.browsers || !apps.editors) return []
  var out = []
  if (Array.prototype.indexOf.call(apps.browsers, "chrome") < 0) out.push("google-chrome")
  if (Array.prototype.indexOf.call(apps.editors, "code") < 0) out.push("visual-studio-code-bin")
  return out
}

// What the apps page says under Chrome and VS Code, and its button
// ("install", "retry" or ""): from the run of nova update that installs them
// (UpdateRun's state and status; "" for a run the page did not start, whose
// end is not this page's to tell) and what is still missing.
function apps(state, status, missing) {
  status = status || {}
  if (state === "running") return { detail: (status.text || "Installing") + "…", action: "" }
  if ((missing || []).length === 0) return { detail: "Installed", action: "" }
  if (state === "failed") return { detail: "Could not install: " + (status.error || "it failed") + ".", action: "retry" }
  if (state === "problems" || state === "stopped") return { detail: "Could not install.", action: "retry" }
  return { detail: "Not installed", action: "install" }
}

// The wordmark's pixels, from the text of it that the stick's screens and
// the screensaver show (theme/wordmark/nova.txt: two pixel rows to a line,
// ▀ the upper, ▄ the lower, █ both), as runs along each pixel row:
// { columns, rows, runs: [{ x, y, length, spark }] }. The spark is the star
// above the a, right of where the letters end on the bottom row; the
// wordmark background draws it in the accent.
function wordmark(text) {
  var lines = String(text || "").replace(/\s+$/, "").split("\n")
  var rows = []
  lines.forEach(function (line) {
    var upper = [], lower = []
    for (var i = 0; i < line.length; i++) {
      upper.push(line[i] === "▀" || line[i] === "█")
      lower.push(line[i] === "▄" || line[i] === "█")
    }
    rows.push(upper, lower)
  })
  while (rows.length > 0 && rows[rows.length - 1].indexOf(true) < 0) rows.pop()
  if (rows.length === 0) return { columns: 0, rows: 0, runs: [] }
  var edge = rows[rows.length - 1].lastIndexOf(true)
  var columns = 0, runs = []
  rows.forEach(function (row, y) {
    columns = Math.max(columns, row.length)
    for (var x = 0; x < row.length; x++) {
      if (!row[x]) continue
      var spark = x > edge
      var last = runs[runs.length - 1]
      if (last && last.y === y && last.x + last.length === x && last.spark === spark) last.length++
      else runs.push({ x: x, y: y, length: 1, spark: spark })
    }
  })
  return { columns: columns, rows: rows.length, runs: runs }
}

// The keys a new account learns first; Super+K has every other.
var keys = [
  { keys: ["Super", "Space"], does: "The menu, with Settings in it" },
  { keys: ["Super", "Return"], does: "A terminal" },
  { keys: ["Super", "Shift", "Return"], does: "The browser" },
  { keys: ["Super", "W"], does: "Close a window" },
  { keys: ["Super", "K"], does: "Every key" }
]
