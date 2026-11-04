.pragma library

// The media service's reading of MPRIS players and Pipewire streams, and
// what it does to a player, apart from Qt.

// Whether the player has any of the properties named, set.
function any(player, names) {
  return !!player && names.some(name => !!player[name])
}

var NAME = ["trackTitle", "trackArtist", "identity", "desktopEntry"]
var TRACK = ["trackTitle", "trackArtist", "trackAlbum", "trackArtUrl"]

// What each action needs the player to say it can do.
var ABLE = {
  next: ["canGoNext"],
  previous: ["canGoPrevious"],
  playPause: ["canTogglePlaying", "canPlay", "canPause"]
}

// Something to show for it: a track, or at least its name.
function isNamed(player) {
  return any(player, NAME)
}

function hasTrack(player) {
  return any(player, TRACK)
}

function isControllable(player) {
  return any(player, ABLE.next.concat(ABLE.previous, ABLE.playPause))
}

function can(player, action) {
  return any(player, ABLE[action] || [])
}

// playerctld, which stands in for whichever player played last.
function isProxy(player) {
  return /playerctld/.test(String(player && player.dbusName || "").toLowerCase())
    || String(player && player.desktopEntry || "").toLowerCase() === "playerctld"
}

// A step of the source keys: named, and playing or able to.
function isSource(player) {
  return isNamed(player) && any(player, ["isPlaying", "canPlay"])
}

// A Pipewire stream that plays, as against one that records.
function isPlaybackStream(node) {
  return !!node && !!node.isStream && (node.isSink === true || /Output|AudioOutStream/.test(String(node.type || "")))
}

// A name in lower-case letters and digits, ALSA's wrapping gone, for a
// stream and a player to be matched: "PipeWire ALSA [Spotify]" and
// "spotify" are both "spotify".
function nameKey(name) {
  return String(name || "").toLowerCase()
    .replace(/^(?:pipewire alsa \[)?(?:alsa playback \[)?/, "")
    .replace(/[^a-z0-9]+/g, "")
}

// A stream's: its program's name, or its own.
function streamKey(node) {
  if (!node) return ""
  var props = node.ready && node.properties ? node.properties : {}
  return nameKey([props["application.name"], node.description, props["media.name"], props["node.name"]].find(Boolean) || node.name)
}

// Whether a stream, by its streamKey, is the player's, by its desktop entry,
// its name, or its bus name less the MPRIS prefix and the instance: the one
// name holding the other.
function heardIn(player, streamKeys) {
  if (!player) return false
  var bus = String(player.dbusName || "").replace(/^org\.mpris\.MediaPlayer2\.|\.instance\d+$/g, "")
  var own = nameKey(player.desktopEntry || player.identity || bus)
  return own !== "" && streamKeys.some(stream => !!stream && (stream.includes(own) || own.includes(stream)))
}

// What the service knows a player by.
function playerKey(player) {
  return player ? String(player.dbusName || player.desktopEntry || player.identity || "") : ""
}

// The track, to tell when a skip has brought the next one.
function trackSignature(player) {
  return player ? JSON.stringify(TRACK.map(name => player[name] || "")) : ""
}

// Its track's title, or its own name.
function label(player) {
  return player ? player.trackTitle || player.identity || player.desktopEntry || "" : ""
}

// The on-screen display's words for it, "Title - Artist" or the label, and
// failing both, what was done.
function osdMessage(player, done) {
  var name = label(player)
  if (!name) return done
  return player.trackArtist ? name + " - " + player.trackArtist : name
}

// What the display says an action did, the player playing or not before it.
function feedback(action, wasPlaying) {
  if (action !== "playPause") return { words: action === "next" ? "Next" : "Previous", icon: "media-" + action }
  return wasPlaying ? { words: "Pause", icon: "media-pause" } : { words: "Play", icon: "media-play" }
}

// Does the action to the player: true if it could. Play and pause go by
// what it says it is doing; a player that only toggles is toggled.
function apply(player, action) {
  if (!player) return false
  if (action !== "playPause") {
    if (!can(player, action)) return false
    player[action]()
  } else if (player.isPlaying && player.canPause) {
    player.pause()
  } else if (!player.isPlaying && player.canPlay) {
    player.play()
  } else if (player.canTogglePlaying) {
    player.togglePlaying()
  } else {
    return false
  }
  return true
}

// Stops a player playing, by a pause or else a toggle.
function halt(player) {
  if (player.canPause) player.pause()
  else if (player.canTogglePlaying && player.isPlaying) player.togglePlaying()
}

// A sort by rank, a list each thing is ranked by in turn: numbers lower
// first, strings in their language's order.
function ranked(rank) {
  return (a, b) => {
    var x = rank(a), y = rank(b)
    for (var i = 0; i < x.length; i++) {
      if (x[i] === y[i]) continue
      return typeof x[i] === "string" ? x[i].localeCompare(y[i]) : x[i] < y[i] ? -1 : 1
    }
    return 0
  }
}
