.pragma library

// What the media service reads from an MPRIS player and from Pipewire, kept
// apart from Qt.

// playerctld stands in for whichever player played last. A player of its own
// is chosen over it.
function isProxy(player) {
  var bus = String(player && player.dbusName || "").toLowerCase()
  var entry = String(player && player.desktopEntry || "").toLowerCase()
  return bus.indexOf("playerctld") !== -1 || entry === "playerctld"
}

// Something to show: a track, or at least the player's name.
function isNamed(player) {
  return !!(player && (player.trackTitle || player.trackArtist || player.identity || player.desktopEntry))
}

function hasTrack(player) {
  return !!(player && (player.trackTitle || player.trackArtist || player.trackAlbum || player.trackArtUrl))
}

function isControllable(player) {
  return !!(player && (player.canTogglePlaying || player.canPlay || player.canPause || player.canGoNext || player.canGoPrevious))
}

// Whether the player can do the action: playPause, play, pause, next or
// previous.
function can(player, action) {
  if (!player) return false
  switch (action) {
  case "next": return !!player.canGoNext
  case "previous": return !!player.canGoPrevious
  case "play": return !!(player.canPlay || player.canTogglePlaying)
  case "pause": return !!(player.canPause || player.canTogglePlaying)
  case "playPause": return !!(player.canTogglePlaying || player.canPlay || player.canPause)
  }
  return false
}

// One the source keys step through: named, and playing or able to play.
function isSource(player) {
  return !!(player && isNamed(player) && (player.isPlaying || player.canPlay))
}

// A stream that plays sound, rather than one that records it.
function isPlaybackStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === true) return true
  var kind = String(node.type || "")
  return kind.indexOf("Output") !== -1 || kind.indexOf("AudioOutStream") !== -1
}

// A name as letters and digits only, in lower case, to match a stream to
// its player: "PipeWire ALSA [Spotify]" and "spotify" are both "spotify".
function nameKey(name) {
  return String(name || "").toLowerCase()
    .replace(/^pipewire alsa \[/, "")
    .replace(/^alsa playback \[/, "")
    .replace(/[^a-z0-9]+/g, "")
}

// The name a stream goes by: its program's, else its own.
function streamName(node) {
  if (!node) return ""
  var props = node.ready && node.properties ? node.properties : {}
  return props["application.name"] || node.description || props["media.name"] || props["node.name"] || node.name
}

// The name a player goes by: its desktop entry, its own name, or its bus name
// without the MPRIS prefix and the instance number.
function playerName(player) {
  if (!player) return ""
  var bus = String(player.dbusName || "")
    .replace(/^org\.mpris\.MediaPlayer2\./, "")
    .replace(/\.instance[0-9]+$/, "")
  return player.desktopEntry || player.identity || bus
}

// Whether one of the streams, by their nameKey, is the player's: the one name
// holds the other.
function isHeard(player, streamKeys) {
  var key = nameKey(playerName(player))
  if (!key) return false
  for (var i = 0; i < streamKeys.length; i++) {
    var stream = streamKeys[i]
    if (stream && (stream.indexOf(key) !== -1 || key.indexOf(stream) !== -1)) return true
  }
  return false
}

// What the service knows a player by.
function playerKey(player) {
  if (!player) return ""
  return String(player.dbusName || player.desktopEntry || player.identity || "")
}

// The track as one string, to tell when it changes.
function trackSignature(player) {
  if (!player) return ""
  return [player.trackTitle || "", player.trackArtist || "", player.trackAlbum || "", player.trackArtUrl || ""].join("\u001f")
}

// A player in a list: its track's title, else its own name.
function label(player) {
  if (!player) return ""
  return player.trackTitle || player.identity || player.desktopEntry || ""
}

// What the on-screen display says: "Title - Artist", the label alone, or
// failing both, what was done.
function osdMessage(player, fallback) {
  if (!player) return fallback
  var name = label(player)
  if (name && player.trackArtist) return name + " - " + player.trackArtist
  return name || fallback
}
