.pragma library

// AirDrop's rules: what `nova airdrop watch` says, and the notifications
// made of it. The states are the daemon's (waiting, asked, receiving,
// received, links, declined, failed, off). The notifications are as on a
// Mac: an offer, with Decline and Accept; a transfer under way, with its
// bar; what came in, which a click opens; a failure, in a sentence. A send's
// are at the end.
//
// Everything a sender says of itself (its name, its files' names, a link) is
// text to show and nothing else: a notification's body is markup to the
// notifications, so it goes in escaped, and the whole is sent with busctl,
// where each word is one value and none can pass for an option.

// Quickshell's NotificationUrgency, as the notifications have it.
var NORMAL = 1
var CRITICAL = 2

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

// Text as the body's markup shows it, word for word.
function escaped(value) {
  return text(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// A size as people say it.
function size(bytes) {
  var n = count(bytes)
  if (n < 1000) return Math.round(n) + (Math.round(n) === 1 ? " byte" : " bytes")
  if (n < 1e6) return Math.round(n / 1e3) + " kB"
  if (n < 1e9) return (n / 1e6).toFixed(1) + " MB"
  return (n / 1e9).toFixed(2) + " GB"
}

// The wait before a watch that ended is started again: the one it had, which
// grows each time it ends at once, or five seconds if it had run for a
// minute, as then it was well and the daemon only restarted.
function waitAfter(wait, ranFor) {
  return ranFor >= 60000 ? 5000 : wait
}

// The sender by its name for itself, in quotes as a Mac has it.
function sender(state) {
  var name = text(state.sender)
  return name !== "" ? "“" + name + "”" : "Someone"
}

// The last part of a path, and the folder it is in by its own name.
function name(path) {
  return text(path).replace(/\/+$/, "").split("/").pop()
}

function folder(path) {
  var parts = text(path).replace(/\/+$/, "").split("/")
  return parts.length > 1 ? parts[parts.length - 2] : ""
}

// A photo, a video, or any other file, by the end of its name.
function kind(file) {
  if (/\.(heic|heif|jpe?g|png|gif|webp|avif|dng|tiff?)$/i.test(file)) return "photo"
  if (/\.(mov|mp4|m4v)$/i.test(file)) return "video"
  return "file"
}

// What is offered, in a few words: "a photo", "3 videos", "2 files", "a link".
function what(state) {
  var files = list(state.files).map(function (file) { return text(file && file.name) })
  if (files.length === 0) return list(state.links).length > 1 ? list(state.links).length + " links" : "a link"
  var kinds = files.map(kind)
  var all = kinds.every(function (k) { return k === kinds[0] }) ? kinds[0] : "file"
  return files.length === 1 ? "a " + all : files.length + " " + all + "s"
}

// A picture Qt reads as it is, should no smaller copy be made of it.
function readable(path) {
  return /\.(png|jpe?g|gif)$/i.test(text(path))
}

// The offer: who wants to send what, its picture (made from the sender's
// own, "" for none), and its two answers, the commands that give them. It
// stays until answered: the daemon says no for itself before the iPhone stops
// waiting.
function offer(state, command, picture) {
  var files = list(state.files), links = list(state.links)
  var detail = files.length === 1 ? text(files[0] && files[0].name) + ", " + size(state.bytes)
    : files.length > 1 ? size(state.bytes)
    : links.length > 0 ? text(links[0]) : ""
  var id = text(state.id)
  return {
    summary: sender(state) + " wants to send you " + what(state),
    body: escaped(detail),
    urgency: CRITICAL,
    picture: text(picture),
    buttons: [
      { says: "Decline", argv: [command, "decline", id] },
      { says: "Accept", argv: [command, "accept", id], main: true }
    ]
  }
}

// The command that makes the offer's picture, `copy` in `folder`, from the
// sender's own (`icon`, the daemon's copy of it: JPEG 2000 from an iPhone).
// That is a stranger's file, and a kind vips trusts less, so it is read in a
// sandbox: no network, nothing of the user's but that file and the folder,
// the system read-only; with 512 MB at most, which a picture that claims a
// huge size runs out of at once rather than taking the computer's memory, on
// one thread; for five seconds, and killed a second after if it will not stop.
function peek(icon, folder, copy) {
  return ["sh", "-c",
    'mkdir -p -m 700 -- "$1" && find "$1" -maxdepth 1 -name "*.jpg" -mmin +10 -delete; ulimit -v 524288;'
    + ' exec bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL --clearenv --setenv PATH /usr/bin'
    + ' --setenv VIPS_CONCURRENCY 1 --setenv MALLOC_ARENA_MAX 2'
    + ' --ro-bind /usr /usr --symlink usr/lib /lib64 --symlink usr/lib /lib --symlink usr/bin /bin'
    + ' --proc /proc --dev /dev --tmpfs /tmp --ro-bind "$2" "$2" --bind "$1" "$1"'
    + ' timeout -k 1 5 vipsthumbnail "$2" --size 256x256 -o "$3[Q=85]" 2>/dev/null',
    "sh", text(folder), text(icon), text(copy)]
}

// A transfer under way: from whom, what, and how far along, in steps of 5 %,
// so that it is not drawn anew for every few bytes.
function receiving(state) {
  var all = count(state.bytes)
  var share = all > 0 ? Math.min(1, count(state.received) / all) : 0
  var files = list(state.files)
  return {
    summary: "Receiving from " + sender(state),
    body: escaped(files.length === 1 ? text(files[0] && files[0].name) : what(state)),
    urgency: CRITICAL,
    progress: Math.floor(share * 20) * 5
  }
}

// What came in: who sent it, where it is, and what a click opens (a file, the
// folder of several, a web address in the browser); `picture` is the photo
// it is, if one, for a smaller copy to be made of. Null for nothing.
function arrival(state) {
  var from = "AirDrop from " + sender(state)
  if (state.state === "links") {
    var links = list(state.links).map(text).filter(function (link) { return link !== "" })
    if (links.length === 0) return null
    // Only a web address opens at a click; anything else is shown.
    var web = /^https?:\/\/[^\s]+$/.test(links[0]) ? links[0] : ""
    return { summary: from, body: escaped(links.join(" ")), urgency: NORMAL, picture: "", opens: web ? ["nova-launch-browser", web] : null }
  }
  var paths = list(state.paths).map(text).filter(function (path) { return path.charAt(0) === "/" })
  if (paths.length === 0) return null
  var where = folder(paths[0]) || "your files"
  if (paths.length === 1) {
    return {
      summary: from,
      body: escaped("Saved " + name(paths[0]) + " in " + where),
      urgency: NORMAL,
      picture: kind(paths[0]) === "photo" ? paths[0] : "",
      opens: ["xdg-open", paths[0]]
    }
  }
  return {
    summary: from,
    body: escaped("Saved " + paths.length + " things in " + where),
    urgency: NORMAL,
    picture: "",
    opens: ["xdg-open", paths[0].replace(/\/[^\/]*$/, "") || "/"]
  }
}

// A transfer that did not finish, in the daemon's sentence.
function failure(state) {
  return { summary: "AirDrop didn’t finish", body: escaped(text(state.why) || "Nothing was saved."), urgency: NORMAL }
}

// AirDrop that would not come on, in the words of `nova airdrop on`.
function refusal(why) {
  return { summary: "AirDrop couldn’t start", body: escaped(text(why) || "It would not say why."), urgency: NORMAL }
}

// The notifications' service on the session bus.
var BUS = ["busctl", "--user", "--", "call", "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications"]

// The command that shows a notification, in place of the one of id
// `replaces` (0 for none), with `glyph` where it has no picture. busctl
// answers "u <id>". Nova's own, "nova-action": it is let through
// do-not-disturb, as what was just asked for.
function notify(notice, replaces, glyph) {
  var hints = [["urgency", "y", String(notice.urgency === CRITICAL ? CRITICAL : NORMAL)], ["nova-glyph", "s", text(glyph)]]
  if (text(notice.picture) !== "") hints.push(["image-path", "s", notice.picture])
  if (notice.opens) hints.push(["nova-exec-argv", "s", JSON.stringify(notice.opens)])
  if (notice.buttons) hints.push(["nova-buttons", "s", JSON.stringify(notice.buttons)])
  if (typeof notice.progress === "number" && notice.progress >= 0) hints.push(["value", "i", String(notice.progress)])
  var argv = BUS.concat(["Notify", "susssasa{sv}i", "nova-action", String(Math.max(0, replaces | 0)), "", text(notice.summary), text(notice.body), "0", String(hints.length)])
  hints.forEach(function (hint) { argv.push(hint[0], hint[1], hint[2]) })
  argv.push("-1")
  return argv
}

// The command that takes notification `id` away.
function closing(id) {
  return BUS.concat(["CloseNotification", "u", String(id)])
}

// The id in busctl's answer to Notify, "u 42"; 0 for none.
function answered(output) {
  var match = /^u (\d+)\s*$/.exec(text(output).trim())
  return match ? Number(match[1]) : 0
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

// ---- sending ---------------------------------------------------------------
//
// `nova airdrop send --json` says a send's lines (the daemon's, src/airdrop
// send.rs): starting, while it switches AirDrop on; looking, with the
// receivers nearby; asking, sending; and its end: sent, declined, failed,
// nobody or cancelled. The window lists the receivers; the rest is said in
// notifications, as a Mac's share sheet says it under the iPhone.

// The one setting of an iPhone's that takes AirDrop from this computer, which
// is nobody's contact.
var EVERYONE = "On the iPhone, choose Everyone for 10 Minutes (Settings, General, AirDrop)."

// The IPC's send: a JSON list, percent-encoded. Null for anything else.
function sendable(words) {
  try {
    var paths = JSON.parse(decodeURIComponent(text(words)))
    return Array.isArray(paths) ? paths : null
  } catch (e) {
    return null
  }
}

// What can be sent: paths, whole ones.
function files(paths) {
  return list(paths).filter(function (path) { return typeof path === "string" && path.charAt(0) === "/" })
}

// What is sent, in a few words: a file by its name, more as "3 photos".
function sending(paths) {
  var names = list(paths).map(name).filter(function (file) { return file !== "" })
  if (names.length === 1) return names[0]
  return what({ files: names.map(function (file) { return { name: file } }) })
}

// A receiver by its name, in quotes as a Mac has it.
function receiver(to) {
  var name = text(to)
  return name !== "" ? "“" + name + "”" : "the iPhone"
}

// The receivers of a looking line, for the window: each its id, its name, and
// whether it takes AirDrop from this computer (one that takes it from its
// contacts only does not).
function receivers(state) {
  return list(state && state.receivers).filter(function (r) {
    return r && typeof r === "object" && /^[0-9]+$/.test(text(r.id))
  }).map(function (r) {
    return { id: text(r.id), name: text(r.name) || "iPhone", accepts: r.accepts === true }
  })
}

// What the window says when the one picked went before it could be asked:
// `receivers` as the window listed them, `id` the one picked.
function went(receivers, id) {
  var gone = list(receivers).filter(function (r) { return r && r.id === id })[0]
  var name = gone ? text(gone.name) : ""
  return (name !== "" ? "“" + name + "”" : "The iPhone") + " is not nearby any more."
}

// The send under way, a notification with Cancel (`cancel`, the command that
// stops it): waiting for the person there to accept, then sending, with its
// bar in steps of 5 %. Null for anything else.
function sendLive(state, files, cancel) {
  var buttons = [{ says: "Cancel", argv: cancel }]
  var body = escaped(sending(files))
  if (state.state === "asking") {
    return { summary: "Waiting for " + receiver(state.to) + " to accept", body: body, urgency: CRITICAL, buttons: buttons }
  }
  if (state.state === "sending") {
    var all = count(state.bytes)
    var share = all > 0 ? Math.min(1, count(state.sent) / all) : 0
    return { summary: "Sending to " + receiver(state.to), body: body, urgency: CRITICAL, buttons: buttons, progress: Math.floor(share * 20) * 5 }
  }
  return null
}

// How a send ended, a notification that stands on its own (`sends`: it takes
// the place of the send's live one); null for a send the user stopped.
function sendEnd(state, files) {
  var body = escaped(sending(files))
  switch (state.state) {
  case "sent":
    return { summary: "Sent to " + receiver(state.to), body: body, urgency: NORMAL, sends: true }
  case "declined":
    var who = receiver(state.to)
    return { summary: who.charAt(0).toUpperCase() + who.slice(1) + " declined", body: body, urgency: NORMAL, sends: true }
  case "nobody":
    var refused = list(state.refused).map(text).filter(function (name) { return name !== "" })
    var why = refused.length > 0 ? receiver(refused[0]) + " takes AirDrop from its contacts only. " + EVERYONE : EVERYONE
    return { summary: "No one nearby", body: escaped(why.charAt(0).toUpperCase() + why.slice(1)), urgency: NORMAL, sends: true }
  case "cancelled":
    return null
  default:
    return { summary: "AirDrop couldn’t send", body: escaped(text(state.why) || "It would not say why."), urgency: NORMAL, sends: true }
  }
}
