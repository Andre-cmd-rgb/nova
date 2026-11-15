.pragma library

// The Bluetooth panel's rules, apart from its items: which of BlueZ's
// devices are shown and in which list, what a row says, which PipeWire sink
// is a device's, the radio switches `rfkill event` reports, and where the
// keys' cursor goes.

// ---------------------------------------------------------------- devices

// The name a device goes by: BlueZ's name for it, else its alias.
function label(device) {
  const given = device ? [device.deviceName, device.name].find(name => !!name) : ""
  return String(given || "").trim()
}

// <values> as an array of its own, from an array or a QML list.
function listOf(values) {
  return values ? Array.from(values) : []
}

// The device at <address> among <devices>, or null.
function deviceAt(devices, address) {
  return listOf(devices).find(device => !!device && (device.address || "") === address) || null
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
  const shown = listOf(devices).filter(device => !!device && named(device))
  const those = test => byLabel(shown.filter(test))
  return {
    connected: those(device => device.connected),
    known: those(device => !device.connected && paired(device)),
    discovered: those(device => !device.connected && !paired(device))
  }
}

// What a row shows of a device, copied out of it, and what it shows where
// the device says nothing. A row that held the device itself could outlive
// it: BlueZ drops devices as a scan times out or one is forgotten,
// sometimes while the row is still being made, and Quickshell crashes. The
// panel looks the device up by its address when a row is acted on.
var ROW = { address: "", name: "", deviceName: "", connected: false, state: -1, batteryAvailable: false, battery: 0, pairing: false }

function rowOf(device) {
  const row = {}
  for (const key in ROW) {
    const none = ROW[key]
    const value = device[key]
    if (typeof none === "boolean") row[key] = !!value
    else if (typeof none === "string") row[key] = value || none
    else row[key] = value === undefined ? none : value
  }
  return row
}

// The lists shown, top to bottom: the scan's only while it runs.
function sections(groups, discovering) {
  var shown = []
  if (groups.connected.length > 0) shown.push("connected")
  if (groups.known.length > 0) shown.push("known")
  if (discovering && groups.discovered.length > 0) shown.push("discovered")
  return shown
}

function devicesIn(groups, section) {
  if (section === "connected") return groups.connected
  if (section === "known") return groups.known
  if (section === "discovered") return groups.discovered
  return []
}

// The rows of <section>'s devices, each a copy of its device with the list
// and its place in it.
function rowsOf(devices, section) {
  return devices.map(function(d, i) { return { dev: rowOf(d), section: section, indexInSection: i } })
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
  const row = index >= 0 ? rows[index] : undefined
  const first = !!row && (index === 0 || rows[index - 1].section !== row.section)
  if (!first) return ""
  return row.section === "known" ? "PAIRED" : "AVAILABLE"
}

// ---------------------------------------------------------------- a row

function stateOf(row) {
  return row.state !== undefined ? row.state : -1
}

// The line under a device's name: what is being done to it (BlueZ's state
// 2 is disconnecting, 3 connecting), or, connected, its battery. A row in
// the paired list that is connected says so.
function status(row, action, section) {
  const state = stateOf(row)
  const leaving = { forgetting: "Forgetting…", disconnecting: "Disconnecting…" }[action] || (state === 2 ? "Disconnecting…" : "")
  if (leaving) return leaving
  if (row.connected) return row.batteryAvailable ? Math.round(row.battery * 100) + "%" : section === "connected" ? "" : "Connected"
  return action === "connecting" || state === 3 || row.pairing === true ? "Connecting…" : ""
}

// Shown at full strength: connected, or with something under way.
function lively(row, action) {
  if (row.connected) return true
  return action !== "" || stateOf(row) === 3 || row.pairing === true
}

// The lists whose rows have a forget button: a device the scan found is
// not paired, and has nothing to forget.
function forgettable(section) {
  return section === "connected" || section === "known"
}

// What a click on the row does.
function clickHint(row, discovered) {
  if (row.connected) return "Disconnect"
  return discovered ? "Pair" : "Connect"
}

// ---------------------------------------------------------------- actions

// The action under way for <address>, "" for none.
function actionFor(actions, address) {
  return actions[address] || ""
}

// <actions> with <address>'s set to <action>.
function withAction(actions, address, action) {
  var next = Object.assign({}, actions)
  next[address] = action
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

// Whether BlueZ has done <action> to <device> (null once it is gone): a
// connect once the device is connected, a disconnect once it is not, a
// forget once it is gone or no longer paired.
function done(action, device) {
  if (action === "forgetting") return !device || !paired(device)
  if (!device) return false
  if (action === "connecting") return !!device.connected
  return action === "disconnecting" && !device.connected
}

// The actions BlueZ has caught up with, taken off. <connected> lists the
// devices that have just connected, <changed> says whether any came off.
function settle(actions, devices) {
  const next = Object.assign({}, actions)
  const connected = []
  for (const address in actions) {
    const device = deviceAt(devices, address)
    if (!done(actions[address], device)) continue
    if (actions[address] === "connecting") connected.push(device)
    delete next[address]
  }
  return { actions: next, changed: Object.keys(next).length < Object.keys(actions).length, connected: connected }
}

// ---------------------------------------------------------------- audio

// The hex digits in <value>, lower-cased: an address in any of its forms.
function digits(value) {
  return String(value || "").toLowerCase().replace(/[^0-9a-f]/g, "")
}

// The properties of a node that may name a device, beside its own names.
var NODE_KEYS = ["node.name", "node.description", "node.nick", "device.name", "device.description",
  "device.product.name", "device.alias", "device.string", "api.bluez5.address", "bluez5.address", "media.name"]

// All a PipeWire node says of itself, its properties once it is ready,
// lower-cased, to find a device in.
function nodeText(node) {
  const properties = node.ready && node.properties ? node.properties : {}
  const own = ["name", "description", "nickname", "nick"].map(key => node[key])
  return own.concat(NODE_KEYS.map(key => properties[key])).join(" ").toLowerCase()
}

// A sink (not a stream) that names <device>: by its address, its digits
// alone, else by its name.
function isSinkOf(node, device) {
  if (!device || !node || !node.isSink || node.isStream) return false
  const text = nodeText(node)
  const address = digits(device.address)
  const name = label(device).toLowerCase()
  return (address !== "" && digits(text).includes(address)) || (name !== "" && text.includes(name))
}

function sinkFor(nodes, device) {
  return listOf(nodes).find(node => isSinkOf(node, device)) || null
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
  if (c.section === "header") return delta > 0 && shown.length > 0 ? cursor(shown[0], 0, false) : c
  if (shown.length === 0) return cursor("header", c.index, false)
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
  if (!shown.length) return cursor(c.section, 0, c.onForget)
  var here = shown.indexOf(c.section)
  if (here < 0) return cursor(shown[0], 0, c.onForget)
  return cursor(c.section, Math.max(0, Math.min(rowsIn(groups, c.section) - 1, c.index)), c.onForget)
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
