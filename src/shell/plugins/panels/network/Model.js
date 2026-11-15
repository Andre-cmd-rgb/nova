.pragma library

// The network panel's rules, kept apart from its windows and from
// NetworkManager: the glyphs, the words of its header, the words for the
// rows of networks, and the stops of the keys' cursor.

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

// ---- The header

// The panel's title: Ethernet while a cable carries the link, else Wi-Fi,
// or Network on a computer with neither.
function linkName(medium, hasRadio) {
  return medium === "ethernet" ? "Ethernet" : hasRadio ? "Wi-Fi" : "Network"
}

// The line under it, in a few plain words: the radio off, the link up (a
// network with a sign-in page is up, but not yet through), or neither.
function linkNote(medium, wifiOn, hasRadio, portal) {
  if (medium === "ethernet") return "Connected"
  if (hasRadio && !wifiOn) return "Turned Off"
  if (medium === "wifi") return portal ? "Sign in required" : "Connected"
  return "Not connected"
}

// ---- The rows of networks

// A network's signal, out of 100.
function signalOf(network) {
  return Math.round((network.signalStrength || 0) * 100)
}

// A row is plain values, never the WifiNetwork itself: rows are a list
// view's model, and a network NetworkManager drops while a row is being made
// would leave the row holding a dead object, which crashes Quickshell. The
// panel finds the network again by its name when it acts on a row.
function networkRow(network) {
  if (!network) return null
  return { connected: !!network.connected, known: !!network.known, ssid: network.name || "", signal: signalOf(network), security: network.security }
}

// The one connected first, then those known, each strongest first.
function sortRows(rows) {
  const rank = row => (row.connected ? 0 : 2) + (row.known ? 0 : 1)
  return rows.slice().sort((a, b) => rank(a) - rank(b) || b.signal - a.signal)
}

// The heading above a row: one over the known networks, one over the rest.
function rowHeading(rows, index) {
  const row = rows[index]
  const before = index > 0 ? rows[index - 1] : null
  if (!row) return ""
  if (row.known) return before ? "" : "KNOWN NETWORKS"
  return !before || before.known ? "OTHER NETWORKS" : ""
}

// Only an open network, or an Enhanced Open one (encrypted, with nothing to
// sign in with), connects without asking; a security this does not know
// asks, to be safe.
function asksForSecret(security, open, enhancedOpen) {
  return security !== open && security !== enhancedOpen
}

function canForget(network) {
  return !!network?.known && !network.connected
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
  const words = new Map([
    [reasons.WifiNetworkLost, "Network lost"],
    [reasons.WifiClientDisconnected, "Disconnected"],
    [reasons.WifiClientFailed, "Connection failed"]
  ])
  if (asks) {
    words.set(reasons.NoSecrets, "Passphrase required")
    words.set(reasons.WifiAuthTimeout, "Wrong password")
  }
  return words.get(reason) || "Failed to connect"
}

// Whether a failed connect opens the passphrase again: the secret was
// missing, or it timed out, which on a network that takes one is a wrong
// passphrase saved (as a first failed try leaves one). A passphrase given
// then replaces the saved one.
function asksAgain(reason, asks, reasons) {
  return asks && (reason === reasons.NoSecrets || reason === reasons.WifiAuthTimeout)
}

// What a row says while its network is joined, left or forgotten, and once
// that has gone on too long.
var UNDERWAY = { connect: "Connecting…", disconnect: "Disconnecting…", forget: "Forgetting…" }
var TIMED_OUT = { connect: "Timed out connecting", disconnect: "Timed out disconnecting", forget: "Timed out forgetting" }

// ---- The cursor

// Its stops, top to bottom: the Wi-Fi switch, the networks and the way to
// Settings. `there` says which the panel shows, and a step up or down passes
// over the rest. The stop a step away, or the same one at either end.
var STOPS = ["radio", "rows", "more"]

function beyond(stop, step, there) {
  for (var i = STOPS.indexOf(stop) + step; i >= 0 && i < STOPS.length; i += step)
    if (there[STOPS[i]]) return STOPS[i]
  return stop
}
