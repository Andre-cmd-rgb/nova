.pragma library

// The network panel's rules, kept apart from its windows and from
// NetworkManager: the glyphs, what nova-network-status and nova-network-band
// print, the traffic and ping worked out from their readings, and the words
// for the rows of networks.

// ---- Glyphs

// Wi-Fi bars for a signal out of 100, one more for each fifth of the way.
var SIGNAL_GLYPHS = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]

function signalGlyph(strength) {
  return SIGNAL_GLYPHS[Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))]
}

// The bar's glyph for the link the computer is on: "wifi", "ethernet", or
// none.
function linkGlyph(kind, strength) {
  if (kind === "wifi") return signalGlyph(strength)
  return kind === "ethernet" ? "󰈀" : "󰤮"
}

// ---- nova-network-status --verbose: a "key<TAB>value" line each

// iw writes the bytes of an SSID that are not plain ASCII as \xHH. Those
// that make UTF-8 are read back as the text they spell; a control byte stays
// written out, and a name that is not UTF-8 at all is left as iw wrote it.
function ssidText(written) {
  var raw = String(written || "")
  try {
    return decodeURIComponent(raw.replace(/\\x([0-9A-Fa-f]{2})|[\s\S]/g, function(token, hex) {
      if (hex === undefined) return encodeURIComponent(token)
      var byte = parseInt(hex, 16)
      return byte < 32 || byte === 127 ? encodeURIComponent(token) : "%" + hex
    }))
  } catch (notText) {
    return raw
  }
}

// The fields of a reading, by key. Values are trimmed, but for the SSID,
// whose spaces are its own.
function readFields(text) {
  var fields = {}
  String(text || "").split("\n").forEach(function(line) {
    var tab = line.indexOf("\t")
    if (tab === -1) return
    var key = line.substring(0, tab)
    var value = line.substring(tab + 1)
    fields[key] = key === "ssid" ? ssidText(value) : value.trim()
  })
  return fields
}

// The link speed beside "Ethernet" in the panel's title: "2.5gbit",
// "100mbit", or nothing. Wi-Fi has its band section for that instead.
function linkSpeed(fields) {
  if (!fields || fields.type !== "ethernet") return ""
  var mbps = parseInt(fields.speed || "", 10)
  if (!mbps || mbps < 0) return ""
  if (mbps < 1000) return mbps + "mbit"
  return (mbps / 1000).toFixed(mbps % 1000 === 0 ? 0 : 1) + "gbit"
}

// ---- Traffic

// Bytes a second each way, from the counters of two readings `now` seconds
// apart. A first reading, or the first on another interface, has nothing to
// measure from and reads 0; one no later than the last keeps the rates.
function traffic(last, fields, now) {
  var iface = fields.iface || ""
  var next = {
    iface: iface,
    rx: parseFloat(fields.rx_bytes || "0"),
    tx: parseFloat(fields.tx_bytes || "0"),
    time: now,
    down: 0,
    up: 0
  }
  if (!last || !last.time || iface !== (last.iface || "")) return next

  var seconds = now - last.time
  next.down = seconds > 0 ? Math.max(0, (next.rx - (last.rx || 0)) / seconds) : last.down || 0
  next.up = seconds > 0 ? Math.max(0, (next.tx - (last.tx || 0)) / seconds) : last.up || 0
  return next
}

// "512 B", "1.5 KB", "700.0 MB", "1.00 GB"; anything not a count is 0.
function bytesText(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n < 1024) return Math.round(n) + " B"
  var kb = n / 1024
  var mb = kb / 1024
  if (kb < 1024) return kb.toFixed(1) + " KB"
  if (mb < 1024) return mb.toFixed(1) + " MB"
  return (mb / 1024).toFixed(2) + " GB"
}

function rateText(bytesPerSecond) {
  return bytesText(bytesPerSecond) + "/s"
}

// ---- Ping

// Each reading carries one ping of the outside world, in milliseconds, or a
// word for one that got no answer. The last 24 on the interface are kept,
// null for those lost: the loss is the share of them lost, the time the mean
// of the answers among the last 5. A reading without a ping starts over.
var PING_KEPT = 24
var PING_MEAN = 5

function pings(last, fields) {
  var iface = fields.iface || ""
  if (fields.internet_ping_ms === undefined) return { iface: iface, samples: [] }
  var kept = iface !== "" && last && last.iface === iface && Array.isArray(last.samples) ? last.samples : []
  var ms = parseFloat(fields.internet_ping_ms)
  var samples = kept.concat([isFinite(ms) && ms >= 0 ? ms : null])
  return { iface: iface, samples: samples.slice(-PING_KEPT) }
}

// The mean of the answers among the last five, or -1 for none.
function pingTime(samples) {
  var answers = samples.slice(-PING_MEAN).filter(function(ms) {
    return typeof ms === "number" && isFinite(ms) && ms >= 0
  })
  if (answers.length === 0) return -1
  return answers.reduce(function(sum, ms) { return sum + ms }, 0) / answers.length
}

function pingLoss(samples) {
  if (samples.length === 0) return 0
  var lost = samples.filter(function(ms) { return ms === null }).length
  return Math.round(lost / samples.length * 100)
}

// Before the first ping is back the rows read "--", which is not a probe
// that timed out; they hold their place either way.
function pingText(ms, pinged) {
  if (!pinged) return "--"
  var value = parseFloat(ms)
  if (!isFinite(value) || value < 0) return "Timeout"
  return value.toFixed(value > 0 && value < 10 ? 1 : 0) + " ms"
}

function lossText(percent, pinged) {
  if (!pinged) return "--"
  var value = parseInt(percent, 10)
  return (value > 0 ? value : 0) + "%"
}

// ---- nova-network-band: band, available and selected lines

function readBands(text) {
  var fields = readFields(text)
  return {
    band: fields.band || "",
    selected: fields.selected || "auto",
    available: String(fields.available || "").split(" ").filter(function(band) { return band !== "" })
  }
}

function bandName(band) {
  if (band === "auto") return "Auto"
  return band ? band + "ghz" : ""
}

// The pills say which band is pinned. With none pinned they are put away, and
// the heading names the band the radio is on instead: "WI-FI BAND: 5GHZ".
function bandHeading(selected, current) {
  var live = selected === "auto" ? bandName(current) : ""
  return live === "" ? "WI-FI BAND" : "WI-FI BAND: " + live.toUpperCase()
}

function bandHint(band) {
  if (band === "auto") return "Let Wi-Fi pick the band"
  return band ? "Stay on " + bandName(band) : ""
}

// ---- The rows of networks

// A row is plain values, never the WifiNetwork itself: rows are a list
// view's model, and a network NetworkManager drops while a row is being made
// would leave the row holding a dead object, which crashes Quickshell. The
// panel finds the network again by its name when it acts on a row.
function networkRow(network) {
  if (!network) return null
  return {
    connected: !!network.connected,
    known: !!network.known,
    ssid: network.name || "",
    signal: Math.round((network.signalStrength || 0) * 100),
    security: network.security
  }
}

// The one connected first, then those known, each strongest first.
function sortRows(rows) {
  return rows.slice().sort(function(a, b) {
    if (a.connected !== b.connected) return a.connected ? -1 : 1
    if (a.known !== b.known) return a.known ? -1 : 1
    return b.signal - a.signal
  })
}

// The heading above a row: one over the known networks, one over the rest.
function rowHeading(rows, index) {
  var row = rows[index]
  if (!row) return ""
  if (row.known) return index === 0 ? "KNOWN NETWORKS" : ""
  return index === 0 || (rows[index - 1] && rows[index - 1].known) ? "OTHER NETWORKS" : ""
}

// Only an open network, or an Enhanced Open one (encrypted, with nothing to
// sign in with), connects without asking; a security this does not know
// asks, to be safe.
function asksForSecret(security, open, enhancedOpen) {
  return security !== open && security !== enhancedOpen
}

function canForget(network) {
  return !!(network && network.known && !network.connected)
}

// Joins a WPA Enterprise network: makes its profile, with the identity in
// $2 and the name in $1, sets the password and brings it up, and takes the
// profile away again if any of that fails. The password comes on stdin and
// reaches nmcli through its `connection edit` prompt, as anything on a
// command line can be read by every user in /proc; printf is bash's own, so
// it starts no process with the password either.
var ENTERPRISE_SCRIPT =
  "u=$(uuidgen); IFS= read -r pw;" +
  " nmcli connection add type wifi con-name \"$1\" ssid \"$1\" connection.uuid \"$u\"" +
  " wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2" +
  " 802-1x.identity \"$2\" 802-1x.auth-timeout 8 >/dev/null" +
  " && printf 'set 802-1x.password %s\\nsave\\nquit\\n' \"$pw\" | nmcli connection edit uuid \"$u\" >/dev/null" +
  " && nmcli connection up uuid \"$u\"" +
  " || { nmcli connection delete uuid \"$u\" >/dev/null 2>&1; false; }"

// What a row says when a connect fails, by NetworkManager's reason; `asks`
// is whether the network takes a secret. `reasons` maps the reasons' names
// to Quickshell's values.
function failureText(reason, asks, reasons) {
  if (asks && reason === reasons.NoSecrets) return "Passphrase required"
  if (asks && reason === reasons.WifiAuthTimeout) return "Wrong password"
  if (reason === reasons.WifiNetworkLost) return "Network lost"
  if (reason === reasons.WifiClientDisconnected) return "Disconnected"
  if (reason === reasons.WifiClientFailed) return "Connection failed"
  return "Failed to connect"
}

// Whether a failed connect opens the passphrase again: the secret was
// missing, or it timed out, which on a network that takes one is a wrong
// passphrase saved (as a first failed try leaves one). A passphrase given
// then replaces the saved one.
function asksAgain(reason, asks, reasons) {
  return asks && (reason === reasons.NoSecrets || reason === reasons.WifiAuthTimeout)
}
