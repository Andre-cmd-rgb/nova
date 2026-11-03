.pragma library

// The Bluetooth panel's rules, apart from its items: which of BlueZ's
// devices are shown and in which list, what a row says, which PipeWire sink
// is a device's, the radio switches `rfkill event` reports, and where the
// keys' cursor goes.

// ---------------------------------------------------------------- devices

// The name a device goes by: BlueZ's name for it, else its alias.
function label(device) {
  if (!device) return ""
  return String(device.deviceName || device.name || "").trim()
}

// <values> as an array, from an array or a QML list.
function listOf(values) {
  if (!values) return []
  if (Array.isArray(values)) return values.slice()
  var n = Number(values.length || 0)
  if (!isFinite(n) || n <= 0) return []
  var list = []
  for (var i = 0; i < n; i++) list.push(values[i])
  return list
}

// Names BlueZ makes up for a device that gave none: a service UUID, in any
// of its forms, or the address.
var madeUpNames = [
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
  /^[0-9a-f]{32}$/i,
  /^0x[0-9a-f]{4,32}$/i,
  /^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i
]

// A device worth a row: one with a name a person would know it by.
function named(device) {
  var name = label(device)
  return name !== "" && !madeUpNames.some(function(re) { return re.test(name) })
}

// Paired, bonded or trusted: a device BlueZ remembers.
function paired(device) {
  return !!(device.paired || device.bonded || device.trusted)
}

function byLabel(list) {
  return list.sort(function(a, b) { return label(a).localeCompare(label(b)) })
}

// The named devices in three lists, each by name: those connected, those
// paired (or bonded, or trusted), and the rest, which a scan turned up.
function lists(devices) {
  var connected = []
  var known = []
  var discovered = []
  listOf(devices).forEach(function(d) {
    if (!d || !named(d)) return
    if (d.connected) connected.push(d)
    else if (paired(d)) known.push(d)
    else discovered.push(d)
  })
  return { connected: byLabel(connected), known: byLabel(known), discovered: byLabel(discovered) }
}

// What a row shows of a device, copied out of it. A row that held the
// device itself could outlive it: BlueZ drops devices as a scan times out
// or one is forgotten, sometimes while the row is still being made, and
// Quickshell crashes. The panel looks the device up by its address when a
// row is acted on.
function rowOf(d) {
  if (!d) return null
  return {
    address: d.address || "",
    name: d.name || "",
    deviceName: d.deviceName || "",
    connected: !!d.connected,
    state: d.state !== undefined ? d.state : -1,
    batteryAvailable: !!d.batteryAvailable,
    battery: d.battery !== undefined ? d.battery : 0,
    pairing: !!d.pairing
  }
}

// The lists shown, top to bottom: the scan's only while it runs.
function sections(groups, discovering) {
  var shown = []
  if (groups && groups.connected && groups.connected.length > 0) shown.push("connected")
  if (groups && groups.known && groups.known.length > 0) shown.push("known")
  if (discovering && groups && groups.discovered && groups.discovered.length > 0) shown.push("discovered")
  return shown
}

function devicesIn(groups, section) {
  if (!groups) return []
  if (section === "connected") return groups.connected || []
  if (section === "known") return groups.known || []
  if (section === "discovered") return groups.discovered || []
  return []
}

// The rows of <section>'s devices, each a copy of its device with the list
// and its place in it.
function rowsOf(devices, section) {
  return (devices || []).map(function(d, i) { return { dev: rowOf(d), section: section, indexInSection: i } })
}

// The scrolling list's rows: the paired devices, then the scan's while its
// list is among those <shown>.
function scrollRows(groups, shown) {
  var rows = rowsOf(groups.known, "known")
  return shown.indexOf("discovered") < 0 ? rows : rows.concat(rowsOf(groups.discovered, "discovered"))
}

// Where <section>'s row <index> is among <rows>; -1 when it is not there.
function rowIndex(rows, section, index) {
  if (section !== "known" && section !== "discovered") return -1
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].section === section && rows[i].indexInSection === index) return i
  }
  return -1
}

// The heading over row <index>, when it is the first of its list.
function titleAt(rows, index) {
  if (index < 0 || index >= rows.length) return ""
  if (index > 0 && rows[index - 1].section === rows[index].section) return ""
  return rows[index].section === "known" ? "PAIRED" : "AVAILABLE"
}

// ---------------------------------------------------------------- a row

function stateOf(row) {
  return row && row.state !== undefined ? row.state : -1
}

// The line under a device's name: what is being done to it (BlueZ's state
// 2 is disconnecting, 3 connecting), or, connected, its battery. A row in
// the paired list that is connected says so.
function status(row, action, section) {
  if (!row) return ""
  if (action === "forgetting") return "Forgetting…"
  if (action === "disconnecting" || stateOf(row) === 2) return "Disconnecting…"
  if (row.connected) {
    if (row.batteryAvailable) return Math.round(row.battery * 100) + "%"
    return section === "connected" ? "" : "Connected"
  }
  if (action === "connecting" || stateOf(row) === 3 || row.pairing === true) return "Connecting…"
  return ""
}

// Shown at full strength: connected, or with something under way.
function lively(row, action) {
  if (row && row.connected) return true
  return action !== "" || stateOf(row) === 3 || row.pairing === true
}

// The lists whose rows have a forget button: a device the scan found is
// not paired, and has nothing to forget.
function forgettable(section) {
  return section === "connected" || section === "known"
}

// What a click on the row does.
function clickHint(row, discovered) {
  if (!row) return ""
  if (row.connected) return "Disconnect"
  return discovered ? "Pair" : "Connect"
}

// ---------------------------------------------------------------- actions

// The action under way for <address>, "" for none.
function actionFor(actions, address) {
  return address && actions && actions[address] ? actions[address] : ""
}

// <actions> with <address>'s set to <action>, or cleared with none.
function withAction(actions, address, action) {
  var next = Object.assign({}, actions || {})
  if (!address) return next
  if (action) next[address] = action
  else delete next[address]
  return next
}

// What nova-bluetooth-device is asked to do to <device> for <verb>
// ("connect", "disconnect" or "forget"), and the word its row shows until
// BlueZ catches up; null for nothing to do. A device not paired yet is
// paired, which connects it too.
function request(device, verb) {
  if (!device || !device.address) return null
  if (verb === "connect" && device.connected) return null
  if (verb === "disconnect" && !device.connected) return null
  if (verb === "connect" && !paired(device)) verb = "pair"
  return { verb: verb, word: verb === "forget" ? "forgetting" : verb === "disconnect" ? "disconnecting" : "connecting" }
}

// The actions BlueZ has caught up with, taken off: a connect once the device
// is connected, a disconnect once it is not, a forget once it is gone or no
// longer paired. <connected> lists the devices that have just connected.
function settle(actions, devices) {
  var next = Object.assign({}, actions || {})
  var connected = []
  var changed = false
  Object.keys(next).forEach(function(address) {
    var action = next[address]
    var found = null
    for (var i = 0; i < devices.length; i++) {
      if (devices[i] && devices[i].address === address) {
        found = devices[i]
        break
      }
    }
    var joined = action === "connecting" && found && found.connected
    if (joined
        || (action === "disconnecting" && found && !found.connected)
        || (action === "forgetting" && (!found || !paired(found)))) {
      if (joined) connected.push(found)
      delete next[address]
      changed = true
    }
  })
  return { actions: next, changed: changed, connected: connected }
}

// ---------------------------------------------------------------- audio

function hexOf(value) {
  return String(value || "").trim().toLowerCase().replace(/[^0-9a-f]/g, "")
}

// All a PipeWire node says of itself, lower-cased, to find a device in.
function nodeText(node) {
  var p = node && node.ready && node.properties ? node.properties : {}
  return [
    node ? node.name : "", node ? node.description : "", node ? node.nickname : "", node ? node.nick : "",
    p["node.name"], p["node.description"], p["node.nick"],
    p["device.name"], p["device.description"], p["device.product.name"], p["device.alias"], p["device.string"],
    p["api.bluez5.address"], p["bluez5.address"], p["media.name"]
  ].join(" ").toLowerCase()
}

// A sink (not a stream) that names <device>: by its address, its digits
// alone, else by its name.
function isSinkOf(node, device) {
  if (!node || !node.isSink || node.isStream || !device) return false
  var text = nodeText(node)
  var address = hexOf(device.address)
  if (address !== "" && hexOf(text).indexOf(address) !== -1) return true
  var name = label(device).toLowerCase()
  return name !== "" && text.indexOf(name) !== -1
}

function sinkFor(nodes, device) {
  for (var i = 0; i < nodes.length; i++) {
    if (isSinkOf(nodes[i], device)) return nodes[i]
  }
  return null
}

// ---------------------------------------------------------------- radio

// <switches> (index: blocked) after a line of `rfkill event`, such as
// "… idx 0 type 2 op 2 soft 1 hard 0": type 2 is Bluetooth, op 1 a switch
// gone. Null for a line about anything else.
function radio(switches, line) {
  var e = /idx (\d+) type (\d+) op (\d+) soft (\d+) hard (\d+)/.exec(String(line))
  if (!e || e[2] !== "2") return null
  var next = Object.assign({}, switches)
  if (e[3] === "1") delete next[e[1]]
  else next[e[1]] = e[4] === "1" || e[5] === "1"
  return next
}

// ---------------------------------------------------------------- cursor

// The keys' cursor: a list and a row in it, and whether it is on the row's
// forget button. "header" is the switch at the top; the row index is kept
// while the cursor is there.
function cursor(section, index, onForget) {
  return { section: section, index: index, onForget: onForget }
}

function rowsIn(groups, section) {
  return devicesIn(groups, section).length
}

// j (<delta> 1) or k (-1): the next row down or up, crossing between lists,
// with the switch above the first.
function move(c, delta, shown, groups) {
  if (c.section === "header") return delta > 0 && shown && shown.length > 0 ? cursor(shown[0], 0, false) : c
  if (!shown || shown.length === 0) return cursor("header", c.index, false)
  var here = shown.indexOf(c.section)
  if (here < 0) return cursor(shown[0], 0, false)
  if (delta > 0) {
    if (c.index < rowsIn(groups, c.section) - 1) return cursor(c.section, c.index + 1, false)
    if (here < shown.length - 1) return cursor(shown[here + 1], 0, false)
    return c
  }
  if (c.index > 0) return cursor(c.section, c.index - 1, false)
  if (here > 0) return cursor(shown[here - 1], rowsIn(groups, shown[here - 1]) - 1, false)
  return cursor("header", c.index, false)
}

// The cursor kept on a row shown once lists change. The switch stays as it
// is: turning Bluetooth off and on empties the lists and fills them again.
function clamp(c, shown, groups) {
  if (c.section === "header") return c
  if (!shown || !shown.length) return cursor(c.section, 0, c.onForget)
  var here = shown.indexOf(c.section)
  if (here < 0) return cursor(shown[0], 0, c.onForget)
  var n = rowsIn(groups, c.section)
  if (n === 0) {
    var to = here > 0 ? shown[here - 1] : shown[0]
    return cursor(to, Math.max(0, rowsIn(groups, to) - 1), c.onForget)
  }
  return cursor(c.section, Math.max(0, Math.min(n - 1, c.index)), c.onForget)
}

// Where the device at <address> is now among the lists shown, or null.
function find(address, shown, groups, onForget) {
  var order = ["connected", "known", "discovered"]
  for (var s = 0; s < order.length; s++) {
    if (shown.indexOf(order[s]) < 0) continue
    var list = devicesIn(groups, order[s])
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].address === address) return cursor(order[s], i, onForget)
    }
  }
  return null
}
