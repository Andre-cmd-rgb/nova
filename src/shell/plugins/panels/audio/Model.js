.pragma library

// The audio panel's rules, apart from its items: which of PipeWire's nodes
// are outputs, inputs and applications' streams, what each is called and
// shown as, which media player a stream is, the volume in words, and where
// the keys' cursor goes.

// ---------------------------------------------------------------- nodes

function propsOf(node) {
  return node.ready && node.properties ? node.properties : {}
}

// A stream an application plays into, told without its properties, which
// are not valid until PipeWire has bound the node: reading them while
// capture streams come and go (as dictation starts recording) can upset
// Quickshell's PipeWire service. Quickshell gives a node's type as its
// media class, an enum's name or a number, depending on the version, but a
// playback stream takes audio in, and says so with isSink; a capture stream
// is a source.
function isPlayback(node) {
  if (node.isSink === true) return true
  return /Output|AudioOutStream/.test(String(node.type || ""))
}

function isSource(node) {
  if (node.audio) return true
  return String(node.type || "").indexOf("Source") !== -1
}

// The outputs: sinks that are not streams.
function sinks(nodes) {
  var found = []
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i]
    if (n && n.isSink && !n.isStream) found.push(n)
  }
  return found
}

// The inputs: sources that are not streams, but for the shell's own.
function sources(nodes) {
  var found = []
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i]
    if (n && !n.isSink && !n.isStream && isSource(n) && (n.name || "") !== "quickshell") found.push(n)
  }
  return found
}

// The applications' streams with a volume to set. A speaker tuning's output
// plays too, but it is the tuning at work rather than an application.
function streams(nodes) {
  var found = []
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i]
    if (!n || !n.isStream || !isPlayback(n)) continue
    if (String(n.name || "").indexOf("nova_speaker_tuning") === 0) continue
    if (n.audio) found.push(n)
  }
  return found
}

// <list> with <node>, the default, first when it is not in it already.
function withDefault(list, node) {
  if (node && list.indexOf(node) < 0) list.unshift(node)
  return list
}

// ---------------------------------------------------------------- devices

// A device's name without what every device on the machine says.
function tidy(text) {
  return String(text || "").trim()
    .replace(/^sof-soundwire\s+/i, "")
    .replace(/^built-?in audio\s+/i, "")
    .replace(/\s+Output$/i, "")
    .replace(/\s+Input$/i, "")
    .replace(/\bMicrophones\b/g, "Microphone")
}

// A device's nickname if it has one, else its description or name.
function deviceName(node) {
  if (!node) return "Unknown"
  var p = propsOf(node)
  var nick = tidy(node.nickname || node.nick || p["node.nick"] || p["device.profile.description"] || "")
  return nick || tidy(node.description || p["node.description"] || node.name || "Unknown")
}

// What a node says of itself, lower-cased, from its names and the
// properties <keys>.
function aboutNode(node, keys) {
  var p = propsOf(node)
  var parts = [node.name, node.description, node.nickname]
  keys.forEach(function(k) { parts.push(p[k] || "") })
  return String(parts.join(" ")).toLowerCase()
}

function headphones(node) {
  var about = aboutNode(node, ["device.icon-name", "device.product.name", "node.description", "node.nick"])
  return /headphone|headset|earbud|earphone|airpod/.test(about)
}

function sinkIcon(node) {
  if (!node) return "󰓃"
  if (headphones(node)) return "󰋋"
  var about = aboutNode(node, ["device.icon-name", "device.product.name"])
  if (about.indexOf("bluetooth") !== -1) return "󰂯"
  if (about.indexOf("hdmi") !== -1 || about.indexOf("display") !== -1) return "󰍹"
  return "󰓃"
}

function sourceIcon(node) {
  if (!node) return "󰍬"
  var about = aboutNode(node, ["device.icon-name"])
  if (about.indexOf("headset") !== -1) return "󰋋"
  if (about.indexOf("bluetooth") !== -1) return "󰂯"
  if (about.indexOf("webcam") !== -1 || about.indexOf("camera") !== -1) return "󰄀"
  return "󰍬"
}

// The bar's and the hero's icon: Waybar's speaker glyphs, by the volume,
// which read larger in JetBrainsMono Nerd Font than the Material ones;
// headphones for headphones; none without an output.
function speakerIcon(sink, muted, volume) {
  if (!sink || !sink.audio) return ""
  if (headphones(sink)) return "󰋋"
  if (muted) return ""
  if (volume >= 0.67) return ""
  if (volume >= 0.34) return ""
  if (volume > 0) return ""
  return ""
}

// The volume in words, a band wide enough that a nudge keeps the word.
var moods = [[100, "Concert hall"], [85, "Party mode"], [70, "Cranked up"], [50, "Steady groove"],
  [30, "Easy listening"], [15, "Murmur"]]

function mood(volume, muted) {
  if (muted) return "Muted"
  var p = Math.round(volume * 100)
  if (p === 0) return "Silenced"
  for (var i = 0; i < moods.length; i++) {
    if (p >= moods[i][0]) return moods[i][1]
  }
  return "Whisper"
}

// ---------------------------------------------------------------- streams

// Names written the way their makers write them.
var appNames = { "spotify": "Spotify" }

function appName(label) {
  label = String(label || "").trim()
  if (!label) return ""
  var key = label.toLowerCase()
  // Its own names only: "constructor" or "__proto__" would find what every
  // object inherits, and the stream would show no name at all.
  return Object.prototype.hasOwnProperty.call(appNames, key) ? appNames[key] : label
}

function keyOf(label) {
  return String(label || "").trim().toLowerCase()
}

// Spotify's stream, and some others', is called just "audio-src".
function generic(label) {
  return keyOf(label) === "audio-src"
}

function rawName(node) {
  if (!node) return ""
  var p = propsOf(node)
  return p["application.name"] || node.description || p["media.name"] || p["node.name"] || node.name
}

function playerName(player) {
  return appName(player.identity || player.desktopEntry || "")
}

// playerctld, which stands in for whichever player was last active.
function isProxy(player) {
  var bus = String(player.dbusName || "").toLowerCase()
  var entry = String(player.desktopEntry || "").toLowerCase()
  return bus.indexOf("playerctld") !== -1 || entry === "playerctld"
}

// A stream's name and a player's are the same application when either
// holds the other.
function sameApp(streamLabel, playerLabel) {
  var a = keyOf(appName(streamLabel))
  var b = keyOf(playerLabel)
  if (!a || !b) return false
  return a === b || a.indexOf(b) !== -1 || b.indexOf(a) !== -1
}

// The name of the one player (that plays, or can) that <wanted> accepts:
// the one playing, else the only one; playerctld only when no real player
// is left. Empty when that does not leave exactly one.
function onlyPlayer(players, wanted) {
  var playing = []
  var any = []
  var proxyPlaying = []
  var proxyAny = []
  ;(Array.isArray(players) ? players : []).forEach(function(player) {
    if (!player || (!player.isPlaying && !player.canPlay)) return
    var name = playerName(player)
    if (!name || !wanted(name)) return
    if (isProxy(player)) {
      if (player.isPlaying) proxyPlaying.push(name)
      proxyAny.push(name)
    } else {
      if (player.isPlaying) playing.push(name)
      any.push(name)
    }
  })
  if (playing.length === 1) return playing[0]
  if (playing.length === 0 && proxyPlaying.length === 1) return proxyPlaying[0]
  if (any.length === 1) return any[0]
  if (any.length === 0 && proxyAny.length === 1) return proxyAny[0]
  return ""
}

// The player a stream with a name of its own is.
function matchingPlayer(label, players) {
  if (generic(label)) return ""
  return onlyPlayer(players, function(name) { return sameApp(label, name) })
}

// For a stream called just "audio-src": the one player no other stream is.
function unmatchedPlayer(label, players, all) {
  if (!generic(label)) return ""
  return onlyPlayer(players, function(name) {
    return !all.some(function(stream) {
      var other = rawName(stream)
      return !generic(other) && sameApp(other, name)
    })
  })
}

// A stream's name in the list: its player's, when that can be told, else
// its own.
function streamName(node, players, all) {
  if (!node) return "Stream"
  var label = rawName(node)
  return appName(matchingPlayer(label, players) || unmatchedPlayer(label, players, all) || label) || "Stream"
}

// Whether a stream is <player>'s, to mark the one the media widget shows.
function playsFor(node, player, players, all) {
  if (!node || !player) return false
  var name = playerName(player)
  if (!name) return false
  var label = rawName(node)
  return sameApp(generic(label) ? streamName(node, players, all) : label, name)
}

// ---------------------------------------------------------------- cursor

// The keys' cursor: a section and a row in it. The output and the input
// have a slider above their devices, at index -1; the streams carry their
// sliders in their rows. "header" is the switch at the top; its index is
// kept as it was. <shape> counts the rows of each section, and says
// whether there is an input to have a slider.

function sections(shape) {
  var list = ["output"]
  if (shape.sources > 0 || shape.hasSource) list.push("input")
  if (shape.streams > 0) list.push("streams")
  return list
}

function hasSlider(section, shape) {
  return section === "output" || (section === "input" && !!shape.hasSource)
}

function entry(section, shape) {
  return hasSlider(section, shape) ? -1 : 0
}

function rows(section, shape) {
  if (section === "output") return shape.sinks
  if (section === "input") return shape.sources
  return shape.streams
}

function at(section, index) {
  return { section: section, index: index }
}

// j (<delta> 1) or k (-1): the next row down or up, into the next section
// at a section's end, onto the switch above the output's slider.
function move(c, delta, shape) {
  var list = sections(shape)
  if (c.section === "header") return delta > 0 ? at(list[0], entry(list[0], shape)) : c
  var here = list.indexOf(c.section)
  if (here < 0) return at(list[0], entry(list[0], shape))
  if (delta > 0) {
    if (c.index < rows(c.section, shape) - 1) return at(c.section, c.index + 1)
    if (here < list.length - 1) return at(list[here + 1], entry(list[here + 1], shape))
    return c
  }
  if (c.index > entry(c.section, shape)) return at(c.section, c.index - 1)
  if (here === 0) return at("header", c.index)
  var above = list[here - 1]
  var last = rows(above, shape) - 1
  return at(above, last >= 0 ? last : entry(above, shape))
}

// The cursor kept on something shown once the lists are read again. The
// switch stays as it is: muting makes PipeWire publish its nodes anew.
function clamp(c, shape) {
  var list = sections(shape)
  if (c.section === "header") return c
  if (list.indexOf(c.section) < 0) return at(list[0], entry(list[0], shape))
  var floor = entry(c.section, shape)
  var count = rows(c.section, shape)
  var index = c.index > count - 1 ? Math.max(floor, count - 1) : c.index
  return at(c.section, Math.max(floor, index))
}
