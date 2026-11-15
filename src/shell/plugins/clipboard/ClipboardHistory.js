// The clipboard's history, newest first, as clipboard-history.json keeps it,
// and the rows the picker shows for it. An entry is text,
//   { "type": "text", "text": ... }
// or an image capture.sh saved,
//   { "type": "image", "path": ..., "mime": ..., "capturedAt": "Monday 14:05" }
// nova-clipboard-paste-text and nova-clipboard-open read the same file, and
// check they have the entry picked by the md5 of its entryKey.

// <value> as an entry, or null: text that is only whitespace, an image with
// no path, and anything else are none. A bare string is text, and "kind"
// stands for "type".
function entry(value) {
  const given = typeof value === "string" ? { type: "text", text: value } : value
  const type = given && typeof given === "object" ? String(given.type || given.kind || "") : ""
  if (type === "text") return String(given.text || "").trim() ? { type, text: String(given.text) } : null
  if (type !== "image" || !given.path) return null
  const image = { type, path: String(given.path), mime: String(given.mime || "image/png") }
  return given.capturedAt == null ? image : Object.assign(image, { capturedAt: String(given.capturedAt) })
}

// What makes two entries the same one: the text, or the image's path.
function entryKey(item) {
  if (!item) return ""
  return item.type === "image" ? "image:" + String(item.path || "") : "text:" + String(item.text || "")
}

// The history in clipboard-history.json's <text>; [] for a file that does not
// parse.
function parse(text) {
  const list = json(String(text || "[]"))
  return Array.isArray(list) ? list.map(item => entry(item)).filter(Boolean) : []
}

// An entry from a line capture.sh printed, or null.
function parseLine(line) {
  const text = String(line || "").trim()
  return text ? entry(json(text)) : null
}

// <text> read as JSON; undefined for text that is not.
function json(text) {
  try {
    return JSON.parse(text)
  } catch (unreadable) {
    return undefined
  }
}

// <history> with <item> first, the same entry further down dropped, at most
// <limit> long.
function added(history, item, limit) {
  var key = entryKey(item)
  var next = [item]
  for (var i = 0; i < history.length && next.length < limit; i++)
    if (entryKey(history[i]) !== key) next.push(history[i])
  return next
}

function removed(history, index) {
  var next = history.slice()
  if (!(index >= 0 && index < history.length)) return next
  next.splice(index, 1)
  return next
}

// A text entry made of file:// URIs, a line each, is a copy of files: those
// are their paths. Lines that are not are left out.
function filePaths(text) {
  const uris = text.split(/\r?\n/).map(line => line.trim()).filter(line => line.startsWith("file://"))
  const local = uris.map(uri => uri.slice("file://".length).replace(/^localhost(?=\/)/, "")).filter(path => path.startsWith("/"))
  return local.map(path => decodedOr(path))
}

// A path's %XX decoded; a stray % leaves it as it is.
function decodedOr(path) {
  try {
    return decodeURIComponent(path)
  } catch (stray) {
    return path
  }
}

// The picker reads and draws no more of an entry than its first 8 KiB, cut
// at a line's end so no file:// URI is cut short. A single huge paste would
// otherwise cost hundreds of megabytes of string work and stall the shell.
// Pasting reads the whole entry back from the file, by its place.
var shownLength = 8192

function shownText(text) {
  if (text.length <= shownLength) return text
  var cut = text.lastIndexOf("\n", shownLength)
  return text.slice(0, cut > 0 ? cut : shownLength)
}

// What the picker shows for each entry, worked out once when the history
// changes, not at every key: the row's words, what a search looks in, the
// text or image in the pane beside the list, and what a paste is given.
//   kind     "text", "file" (a copy of files) or "image"
//   whole    what the pane shows of text and files, and is pasted
//   label    the row's words
//   picture  the image's path, or a lone file's that is a picture
//   path     the image's or the lone file's path
//   place    its place in the history
function views(history) {
  return history.map((item, place) => item.type === "image" ? imageView(item, place) : textView(item, place))
}

function imageView(item, place) {
  const when = String(item.capturedAt || "")
  const label = when ? (item.mime === "image/png" ? "Screenshot" : "Image") + " from " + when : "Image"
  return {
    kind: "image", whole: "", label, picture: item.path, path: item.path, mime: item.mime, place,
    search: ("image screenshot " + item.mime + " " + when).toLowerCase()
  }
}

function textView(item, place) {
  const text = shownText(item.text)
  const paths = filePaths(text)
  const lone = paths.length === 1 ? paths[0] : ""
  const files = lone ? lone.split("/").pop() : paths.length > 1 ? paths.length + " files" : ""
  return {
    kind: paths.length > 0 ? "file" : "text",
    whole: paths.length > 0 ? paths.join("\n") : text,
    label: files || text.replace(/\s+/g, " "),
    picture: /\.(png|jpe?g|webp|gif|bmp|tiff?)$/i.test(lone) ? lone : "",
    path: lone, mime: "text/plain", place,
    search: (text + " " + files).toLowerCase()
  }
}

// The rows a search shows, at most <limit>: those whose words hold what is
// typed, trimmed, whatever its case; all of them with nothing typed.
function rows(shown, query, limit) {
  const typed = String(query || "").trim().toLowerCase()
  return shown.filter(view => view.search.includes(typed)).slice(0, limit)
}
