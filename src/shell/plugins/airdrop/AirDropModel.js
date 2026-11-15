.pragma library

// AirDrop's card: what `nova airdrop watch` says, and what the card shows for
// it. The states are the daemon's (waiting, asked, receiving, received,
// links, declined, failed, off) and three of the card's own: starting, while
// `nova airdrop on` is at work; error, when that failed, with its words; and
// ended, when the daemon gave up with nobody having sent anything.
//
// Everything a sender says of itself (its name, its files' names, a link) is
// text to show and nothing else.

// A line of the watch: the state it says, or null for anything else.
function parse(line) {
  var state
  try {
    state = JSON.parse(String(line))
  } catch (e) {
    return null
  }
  if (!state || typeof state !== "object" || Array.isArray(state) || typeof state.state !== "string") return null
  return state
}

function text(value) {
  return typeof value === "string" ? value : ""
}

function count(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? n : 0
}

function list(value) {
  return Array.isArray(value) ? value : []
}

// A size as people say it.
function size(bytes) {
  var n = count(bytes)
  if (n < 1000) return Math.round(n) + " bytes"
  if (n < 1e6) return Math.round(n / 1e3) + " kB"
  if (n < 1e9) return (n / 1e6).toFixed(1) + " MB"
  return (n / 1e9).toFixed(2) + " GB"
}

// What is offered, in a few words: a file by its name, more by their number.
function offered(state) {
  var files = list(state.files), links = list(state.links)
  if (files.length === 1) return text(files[0] && files[0].name) + " (" + size(state.bytes) + ")"
  if (files.length > 1) return files.length + " files (" + size(state.bytes) + ")"
  return links.length === 1 ? "a link" : links.length + " links"
}

function sender(state) {
  return text(state.sender) || "Somebody"
}

// Minutes and seconds left.
function clock(seconds) {
  var left = Math.max(0, Math.ceil(count(seconds)))
  return Math.floor(left / 60) + ":" + String(left % 60).padStart(2, "0")
}

// The last part of a path, and the folder it is in by its own name.
function name(path) {
  return text(path).replace(/\/+$/, "").split("/").pop()
}

function folder(path) {
  var parts = text(path).replace(/\/+$/, "").split("/")
  return parts.length > 1 ? parts[parts.length - 2] : ""
}

// A state after which nothing more comes of this transfer.
function over(state) {
  return !!state && ["received", "links", "declined", "failed", "error", "ended"].indexOf(state.state) >= 0
}

// Whether a daemon that was waiting and is gone gave up by itself: its time had run out.
function gaveUp(state, now) {
  return !!state && state.state === "waiting" && count(state.ends) > 0 && now >= count(state.ends) - 2
}

// What the card shows for a state: null when it shows nothing. `now` is in
// Unix seconds. A face has a title, words under it, a dimmer note, a share
// done (-1 for no bar), answers to give (each what it `does`, what it `says`,
// and whether it is the `main` one), and how long it `stays` (0: until the
// state changes). `rung`: AirDrop was switched on for an iPhone's share
// sheet, and goes off when it closes.
function face(state, now, rung) {
  if (!state) return null
  var plain = { title: "AirDrop", words: "", note: "", share: -1, answers: [], stays: 0 }
  function with_(more) {
    for (var key in more) plain[key] = more[key]
    return plain
  }
  var stop = { does: "stop", says: "Stop", main: false }
  switch (state.state) {
  case "starting":
    return with_({ words: "Getting the Wi-Fi card ready" })
  case "waiting":
    var left = count(state.ends) > 0 ? count(state.ends) - now : 0
    return with_({
      words: state.seen === true ? "An iPhone has " + (text(state.name) || "this computer") + " in its AirDrop list"
        : "Send from an iPhone to " + (text(state.name) || "this computer"),
      note: rung === true ? "Wi-Fi is off until the iPhone's share sheet closes."
        : "Wi-Fi is off meanwhile." + (left > 0 ? " Ends in " + clock(left) + "." : ""),
      answers: [stop]
    })
  case "asked":
    return with_({
      title: sender(state) + " wants to send",
      words: offered(state),
      answers: [{ does: "decline", says: "Decline", main: false }, { does: "accept", says: "Accept", main: true }]
    })
  case "receiving":
    var all = count(state.bytes)
    return with_({
      title: "Receiving from " + sender(state),
      words: offered(state),
      note: size(Math.min(count(state.received), all || count(state.received))) + (all > 0 ? " of " + size(all) : ""),
      share: all > 0 ? Math.min(1, count(state.received) / all) : 0,
      answers: [stop]
    })
  case "declined":
    return with_({ words: "Declined", stays: 2500 })
  case "failed":
    return with_({ title: "AirDrop did not finish", words: text(state.why) || "The transfer stopped", stays: 8000 })
  case "error":
    return with_({ title: "AirDrop could not start", words: text(state.why) || "It would not say why", stays: 9000 })
  case "ended":
    return with_({ words: "Off again: nobody sent anything", stays: 4000 })
  }
  return null
}

// The notification for what came in: its headline, its words, the picture to
// show and what a click opens (a file, or the folder of several). Its words
// begin with words of the card's own, so that no name of a sender's is ever
// the first thing an option could be read from.
function arrival(state) {
  var from = "AirDrop from " + sender(state)
  if (state.state === "links") {
    var links = list(state.links).map(text).filter(function (link) { return link !== "" })
    if (links.length === 0) return null
    // Only a web address opens at a click; anything else is shown.
    var web = /^https?:\/\/[^\s]+$/.test(links[0]) ? links[0] : ""
    return { headline: from, words: "Link: " + links.join(" "), picture: "", opens: web, browser: true }
  }
  var paths = list(state.paths).map(text).filter(function (path) { return path.charAt(0) === "/" })
  if (paths.length === 0) return null
  var where = folder(paths[0]) || "your files"
  if (paths.length === 1) {
    return {
      headline: from,
      words: "Saved " + name(paths[0]) + " in " + where + ". Click to open.",
      picture: /\.(png|jpe?g|gif|webp|bmp|heic|heif|avif)$/i.test(paths[0]) ? paths[0] : "",
      opens: paths[0],
      browser: false
    }
  }
  return {
    headline: from,
    words: "Saved " + paths.length + " things in " + where + ". Click to see them.",
    picture: "",
    opens: paths[0].replace(/\/[^\/]*$/, "") || "/",
    browser: false
  }
}

// What AirDrop's doorbell asks of AirDrop now: "on", "off", or "" for
// nothing. `s` says whether the iPhone the doorbell knows shows AirDrop in its
// share sheet (`near`), whether the computer is `locked`, whether AirDrop is
// `on` (or on its way), whether it was switched on for that sheet (`rung`),
// whether that sheet has had its AirDrop already (`spent`: AirDrop went off
// while it was open, whoever ended it; none again until it closes), and the
// daemon's `state`.
function doorbell(s) {
  if (!s.on) return s.near && !s.locked && !s.spent ? "on" : ""
  // An AirDrop switched on by hand is ended by hand, or by itself.
  if (!s.rung) return ""
  if (s.locked) return "off"
  // The sheet closed: off, but not from under an offer or a transfer, which end by themselves.
  return !s.near && s.state !== "asked" && s.state !== "receiving" ? "off" : ""
}
