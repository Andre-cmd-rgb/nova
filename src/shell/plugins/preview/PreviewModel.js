// Quick Look's rules: the request nova-previewer sends, the window's size for
// each kind of file, what a text shows and the words under a name.

var kinds = ["folder", "image", "pdf", "video", "audio", "text", "other"]

// The file asked for, from the one line of JSON nova-previewer sends, or
// null for anything that is not one. A field that is missing is given its
// plain value, so that the window never has to ask whether it is there.
function parse(json) {
  var raw
  try {
    raw = JSON.parse(String(json || ""))
  } catch (e) {
    return null
  }
  if (!raw || typeof raw !== "object" || typeof raw.uri !== "string" || raw.uri === "") return null
  var text = function (value) { return typeof value === "string" ? value : "" }
  var number = function (value) { return typeof value === "number" && isFinite(value) ? value : -1 }
  return {
    uri: raw.uri,
    path: text(raw.path),
    name: text(raw.name) || raw.uri,
    mime: text(raw.mime),
    kind: kinds.indexOf(raw.kind) >= 0 ? raw.kind : "other",
    type: text(raw.type),
    size: number(raw.size),
    sizeText: text(raw.sizeText),
    items: number(raw.items),
    icon: Array.isArray(raw.icon) ? raw.icon.filter(function (n) { return typeof n === "string" }) : [],
    seq: number(raw.seq)
  }
}

// The line under a name: "12 items" for a folder, else the kind and the
// size, either left out when it is not known.
function facts(info) {
  if (info.kind === "folder") {
    if (info.items < 0) return info.type
    return info.items === 1 ? "1 item" : info.items + " items"
  }
  return [info.type, info.sizeText].filter(function (part) { return part !== "" }).join(" · ")
}

// What a thing of <kind> is shown on: its picture's size when it has one
// (an image's own, a page's, a video's frame), else a size of its own. The
// answer is the content's size in pixels, never more than <room> allows,
// the picture's proportions kept, and never so small that it cannot be
// seen. A picture that is not there yet (zero) is the size of its kind.
function stage(kind, picture, room, scale) {
  var s = scale > 0 ? scale : 1
  var fallback = {
    image: [640, 480], pdf: [560, 720], video: [800, 450], audio: [420, 420],
    text: [720, 520], folder: [420, 300], other: [420, 300]
  }[kind] || [420, 300]
  var width = fallback[0] * s
  var height = fallback[1] * s
  // Only what has a picture takes its size from it, and a text or a folder
  // is a window of its own size at once.
  if (picture.width > 0 && picture.height > 0 && (kind === "image" || kind === "pdf" || kind === "video" || kind === "audio")) {
    width = picture.width
    height = picture.height
    // Too small a picture (an icon) is made bigger, to a floor of its own.
    var floor = 280 * s
    var up = Math.max(1, floor / Math.max(width, height))
    width *= up
    height *= up
  }
  var fit = Math.min(1, room.width / width, room.height / height)
  return { width: Math.max(1, Math.round(width * fit)), height: Math.max(1, Math.round(height * fit)) }
}

// The first part of a text file: at most <lines> lines of at most <columns>
// characters, tabs as four spaces, a line cut short ending in an ellipsis.
// Text with a NUL in it is not text: null.
function head(raw, lines, columns) {
  var text = String(raw || "")
  if (text.indexOf("\u0000") >= 0) return null
  return text.replace(/\r\n?/g, "\n").split("\n").slice(0, lines).map(function (line) {
    line = line.replace(/\t/g, "    ")
    return line.length > columns ? line.slice(0, columns - 1) + "…" : line
  }).join("\n")
}

// The icon to show for a file with none of its own: the first of the names
// <resolved> (a function from name to path, "" for none) knows.
function iconFor(names, resolved) {
  var all = names.concat(["text-x-generic"])
  for (var i = 0; i < all.length; i++) {
    var path = resolved(all[i])
    if (path) return path
  }
  return ""
}
