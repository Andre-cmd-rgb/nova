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
  if (typeof value === "string") return value.trim() ? { type: "text", text: value } : null
  if (!value || typeof value !== "object") return null
  var type = String(value.type || value.kind || "")
  if (type === "text") {
    var text = String(value.text || "")
    return text.trim() ? { type: "text", text: text } : null
  }
  if (type !== "image" || !value.path) return null
  var image = { type: "image", path: String(value.path), mime: String(value.mime || "image/png") }
  if (value.capturedAt !== undefined && value.capturedAt !== null) image.capturedAt = String(value.capturedAt)
  return image
}

// What makes two entries the same one: the text, or the image's path.
function entryKey(item) {
  if (!item) return ""
  return item.type === "image" ? "image:" + String(item.path || "") : "text:" + String(item.text || "")
}

// The history in clipboard-history.json's <text>; [] for a file that does not
// parse.
function parse(text) {
  var list
  try {
    list = JSON.parse(String(text || "[]"))
  } catch (e) {
    return []
  }
  if (!Array.isArray(list)) return []
  var history = []
  for (var i = 0; i < list.length; i++) {
    var item = entry(list[i])
    if (item) history.push(item)
  }
  return history
}

// An entry from a line capture.sh printed, or null.
function parseLine(line) {
  var text = String(line || "").trim()
  if (!text) return null
  try {
    return entry(JSON.parse(text))
  } catch (e) {
    return null
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
  var paths = []
  var lines = text.split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line.indexOf("file://") !== 0) continue
    var path = line.substring(7)
    if (path.indexOf("localhost/") === 0) path = path.substring(9)
    if (path.charAt(0) !== "/") continue
    try {
      path = decodeURIComponent(path)
    } catch (e) {
      // A stray % stays as it is.
    }
    if (path) paths.push(path)
  }
  return paths
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
function views(history) {
  var shown = []
  for (var i = 0; i < history.length; i++) {
    var item = history[i]
    if (item.type === "image") {
      var when = String(item.capturedAt || "")
      shown.push({
        entryType: "image",
        fullText: "",
        previewText: when ? (item.mime === "image/png" ? "Screenshot" : "Image") + " from " + when : "Image",
        previewImage: item.path,
        path: item.path,
        mime: item.mime,
        index: i,
        search: ("image screenshot " + item.mime + " " + when).toLowerCase()
      })
      continue
    }
    var text = shownText(item.text)
    var paths = filePaths(text)
    var one = paths.length === 1 ? paths[0] : ""
    var files = paths.length === 0 ? "" : one ? one.split("/").pop() : paths.length + " files"
    shown.push({
      entryType: paths.length > 0 ? "file" : "text",
      fullText: paths.length > 0 ? paths.join("\n") : text,
      previewText: files || text.replace(/\s+/g, " "),
      previewImage: /\.(png|jpe?g|webp|gif|bmp|tiff?)$/i.test(one) ? one : "",
      path: one,
      mime: "text/plain",
      index: i,
      search: (text + " " + files).toLowerCase()
    })
  }
  return shown
}

// The rows a search shows, at most <limit>: those whose words hold what is
// typed, trimmed, whatever its case; all of them with nothing typed.
function rows(shown, query, limit) {
  var needle = String(query || "").trim().toLowerCase()
  var found = []
  for (var i = 0; i < shown.length && found.length < limit; i++)
    if (!needle || shown[i].search.indexOf(needle) !== -1) found.push(shown[i])
  return found
}
