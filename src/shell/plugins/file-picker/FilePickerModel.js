.pragma library

// The rules of Nova's file picker, apart from its window so that a test can
// ask them: the request nova-sessiond sends, the answer the window gives,
// paths and their addresses, what a name may be, and how a file is shown.
// Picker.qml is the window, FilePicker.qml the service that listens.

var MODES = ["open", "save", "folder", "save-files"]
var LIMIT = 64

// ---------------------------------------------------------------- the words

var TITLES = { "open": "Open", "save": "Save", "folder": "Choose a Folder", "save-files": "Save Files" }
var ACCEPTS = { "open": "Open", "save": "Save", "folder": "Choose", "save-files": "Save" }

function title(request) {
  return request.title !== "" ? request.title : TITLES[request.mode]
}

function acceptWords(request) {
  return request.accept !== "" ? request.accept : ACCEPTS[request.mode]
}

// "Saves 2 files: a.txt, b.txt"
function savesLine(files) {
  var n = files.length
  return "Saves " + n + (n === 1 ? " file" : " files") + (n > 0 ? ": " + files.join(", ") : "")
}

// ---------------------------------------------------------------- the request

function text(value) {
  return typeof value === "string" ? value : ""
}

function absolute(path) {
  return typeof path === "string" && path.charAt(0) === "/" && path.indexOf("\0") < 0
}

function list(value) {
  return Array.isArray(value) ? value.slice(0, LIMIT) : []
}

// The first line of a pick as the window uses it, or null for a line that
// is not one: not JSON, not a pick, a mode it does not know, or a folder
// that is not an absolute path.
function parse(line) {
  var said
  try {
    said = JSON.parse(line)
  } catch (e) {
    return null
  }
  if (said === null || typeof said !== "object" || said.type !== "pick") return null
  if (MODES.indexOf(said.mode) < 0 || !absolute(said.folder)) return null

  var filters = []
  list(said.filters).forEach(function (f) {
    if (f === null || typeof f !== "object" || typeof f.name !== "string") return
    var globs = list(f.globs).filter(function (g) { return typeof g === "string" && g !== "" })
    filters.push({ name: f.name, globs: globs })
  })

  var choices = []
  list(said.choices).forEach(function (c) {
    if (c === null || typeof c !== "object" || typeof c.id !== "string" || c.id === "") return
    var options = []
    list(c.options).forEach(function (o) {
      if (o !== null && typeof o === "object" && typeof o.id === "string") options.push({ id: o.id, label: text(o.label) || o.id })
    })
    var value = text(c.value)
    if (options.length === 0) value = value === "true" ? "true" : "false"
    else if (!options.some(function (o) { return o.id === value })) value = options[0].id
    choices.push({ id: c.id, label: text(c.label) || c.id, options: options, value: value })
  })

  var places = []
  list(said.places).forEach(function (p) {
    if (p === null || typeof p !== "object" || !absolute(p.path)) return
    places.push({ label: text(p.label) || baseName(p.path) || "/", path: normalize(p.path), glyph: text(p.glyph) })
  })

  var files = list(said.files).filter(function (f) { return typeof f === "string" && f !== "" })
  var filter = Number.isInteger(said.filter) && said.filter >= 0 && said.filter < filters.length ? said.filter : 0

  return {
    mode: said.mode,
    multiple: said.multiple === true && (said.mode === "open" || said.mode === "folder"),
    title: text(said.title),
    app: text(said.app),
    accept: text(said.accept),
    folder: normalize(said.folder),
    name: said.mode === "save" ? text(said.name) : "",
    select: absolute(said.select) ? normalize(said.select) : "",
    files: said.mode === "save-files" ? files : [],
    filters: filters,
    filter: filter,
    choices: choices,
    places: places,
    hidden: said.hidden === true
  }
}

function answerLine(paths, filter, choices, hidden) {
  return JSON.stringify({ type: "answer", paths: paths, filter: filter, choices: choices, hidden: hidden === true }) + "\n"
}

function cancelLine() {
  return JSON.stringify({ type: "cancel" }) + "\n"
}

// The choices as the answer has them: every id with its value.
function choiceValues(choices, values) {
  var all = {}
  choices.forEach(function (c) { all[c.id] = values.hasOwnProperty(c.id) ? values[c.id] : c.value })
  return all
}

// What the answer's `paths` hold: <selected> are the paths chosen in the
// list (files and folders), <dirs> the ones of them that are folders.
function answerPaths(request, folder, name, selected, dirs) {
  var isDir = function (p) { return dirs.indexOf(p) >= 0 }
  if (request.mode === "open") return selected.filter(function (p) { return !isDir(p) })
  if (request.mode === "save") return [join(folder, name)]
  var chosen = selected.filter(isDir)
  if (request.mode === "save-files") return [chosen.length > 0 ? chosen[0] : folder]
  return chosen.length > 0 ? chosen : [folder]
}

// ---------------------------------------------------------------- paths

// A path with no empty, "." or ".." parts and no trailing slash.
function normalize(path) {
  var out = []
  String(path).split("/").forEach(function (part) {
    if (part === "" || part === ".") return
    if (part === "..") out.pop()
    else out.push(part)
  })
  return "/" + out.join("/")
}

function split(path) {
  return normalize(path).split("/").filter(function (p) { return p !== "" })
}

function join(folder, name) {
  return folder === "/" ? "/" + name : folder + "/" + name
}

function parent(path) {
  var parts = split(path)
  parts.pop()
  return "/" + parts.join("/")
}

function baseName(path) {
  var parts = split(path)
  return parts.length > 0 ? parts[parts.length - 1] : ""
}

// The parts of a path to click: the root, then each folder down to the last.
function breadcrumbs(path, home) {
  var parts = split(path)
  var crumbs = [{ label: "/", path: "/" }]
  var at = ""
  parts.forEach(function (part) {
    at += "/" + part
    crumbs.push({ label: part, path: at })
  })
  if (home && home !== "/" && (path === home || path.indexOf(home + "/") === 0)) {
    var skip = split(home).length
    crumbs = crumbs.slice(skip)
    crumbs[0] = { label: "Home", path: home }
  }
  return crumbs
}

// A long trail with its middle gone: the first part, an ellipsis that goes
// to the last part it hides, and the last <tail> parts.
function collapse(crumbs, most, tail) {
  if (crumbs.length <= most) return crumbs
  var keep = crumbs.length - tail
  return [crumbs[0], { label: "…", path: crumbs[keep - 1].path }].concat(crumbs.slice(keep))
}

// The address of a path, each part percent-encoded so that "#", "?" and "%"
// in a name stay in it.
function fileUrl(path) {
  var parts = split(path)
  return parts.length === 0 ? "file:///" : "file://" + parts.map(function (part) { return "/" + encodeURIComponent(part) }).join("")
}

// What the location field's words mean: "~" is home, a relative path starts
// in the folder shown.
function resolveLocation(typed, home, folder) {
  var t = String(typed).trim()
  if (t === "~") return normalize(home)
  if (t.indexOf("~/") === 0) return normalize(home + "/" + t.slice(2))
  if (t.charAt(0) === "/") return normalize(t)
  return t === "" ? folder : normalize(folder + "/" + t)
}

// The place that holds <path>, the longest of them; -1 for none.
function placeFor(places, path) {
  var best = -1
  var length = -1
  places.forEach(function (p, i) {
    var inside = p.path === "/" || path === p.path || path.indexOf(p.path + "/") === 0
    if (inside && p.path.length > length) {
      best = i
      length = p.path.length
    }
  })
  return best
}

// ---------------------------------------------------------------- history

function history(path) {
  return { stack: [path], at: 0 }
}

function visit(h, path) {
  if (h.stack[h.at] === path) return h
  return { stack: h.stack.slice(0, h.at + 1).concat([path]), at: h.at + 1 }
}

function canBack(h) { return h.at > 0 }
function canForward(h) { return h.at < h.stack.length - 1 }
function stepped(h, by) {
  var at = Math.max(0, Math.min(h.stack.length - 1, h.at + by))
  return { stack: h.stack, at: at }
}

// ---------------------------------------------------------------- names

// Why a name to save under will not do: "" when it will.
function nameProblem(name) {
  if (name === "") return "empty"
  if (name.indexOf("/") >= 0) return "slash"
  if (name === "." || name === "..") return "dots"
  if (name.indexOf("\0") >= 0) return "null"
  return ""
}

function nameMessage(problem) {
  switch (problem) {
  case "slash": return "A name can’t contain “/”."
  case "dots": return "“.” and “..” are not names a file can have."
  case "null": return "A name can’t contain that character."
  default: return "Type a name first."
  }
}

function overwriteQuestion(name, folder) {
  return "“" + name + "” already exists in “" + (baseName(folder) || "/") + "”. Replace it?"
}

// How much of a name is its stem, for selecting it without its extension.
function stemLength(name) {
  var dot = name.lastIndexOf(".")
  return dot > 0 ? dot : name.length
}

// A glob as a test of a name, case-insensitive: * any run, ? any one.
function globMatches(glob, name) {
  var re = ""
  for (var i = 0; i < glob.length; i++) {
    var c = glob.charAt(i)
    if (c === "*") re += ".*"
    else if (c === "?") re += "."
    else re += c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }
  return new RegExp("^" + re + "$", "i").test(name)
}

// The extension a glob such as "*.png" names, or "" for any other glob.
function simpleExtension(glob) {
  var m = /^\*\.([A-Za-z0-9_+-]+)$/.exec(glob)
  return m ? m[1] : ""
}

// The name with the extension of the filter chosen now, when the old one's
// globs matched it and the new filter's first glob is a plain "*.ext".
function swapExtension(name, oldGlobs, newGlobs) {
  if (name === "" || newGlobs.length === 0) return name
  var ext = simpleExtension(newGlobs[0])
  if (ext === "") return name
  var dot = name.lastIndexOf(".")
  if (dot <= 0) return name
  if (!oldGlobs.some(function (g) { return globMatches(g, name) })) return name
  if (name.slice(dot + 1) === ext) return name
  return name.slice(0, dot + 1) + ext
}

// A name not taken: "New Folder", then "New Folder 2", "New Folder 3".
function freeName(base, taken) {
  if (!taken(base)) return base
  for (var n = 2; n < 10000; n++)
    if (!taken(base + " " + n)) return base + " " + n
  return base
}

// ---------------------------------------------------------------- the list

// The first row, from <start> on and round again, whose name begins with
// what was typed, ignoring case; -1 for none.
function typeAhead(count, nameAt, typed, start) {
  var wanted = typed.toLowerCase()
  if (wanted === "" || count <= 0) return -1
  for (var k = 0; k < count; k++) {
    var i = (start + k) % count
    if (nameAt(i).toLowerCase().indexOf(wanted) === 0) return i
  }
  return -1
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function two(n) { return (n < 10 ? "0" : "") + n }

// "Today 14:02", "Yesterday 09:10", "12 Mar", "12 Mar 2025".
function dateLabel(when, now) {
  var d = new Date(when)
  if (isNaN(d.getTime())) return ""
  var n = new Date(now)
  var day = function (x) { return new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime() }
  var days = Math.round((day(n) - day(d)) / 86400000)
  var clock = two(d.getHours()) + ":" + two(d.getMinutes())
  if (days === 0) return "Today " + clock
  if (days === 1) return "Yesterday " + clock
  var words = d.getDate() + " " + MONTHS[d.getMonth()]
  return d.getFullYear() === n.getFullYear() ? words : words + " " + d.getFullYear()
}

// "812 B", "4 KB", "1.2 MB": thousands, as the rest of Nova.
function sizeLabel(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) return ""
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1000 && i < units.length - 1) {
    n /= 1000
    i++
  }
  if (i === 0) return Math.round(n) + " B"
  var shown = n >= 9.95 ? String(Math.round(n)) : n.toFixed(1).replace(/\.0$/, "")
  return shown + " " + units[i]
}

var IMAGES = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "avif"]

function isImage(suffix) {
  return IMAGES.indexOf(String(suffix).toLowerCase()) >= 0
}

var KINDS = {
  image: IMAGES.concat(["tif", "tiff", "ico", "heic", "xcf", "psd"]),
  audio: ["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac", "oga", "mid"],
  video: ["mp4", "mkv", "webm", "mov", "avi", "m4v", "ogv"],
  archive: ["zip", "tar", "gz", "xz", "bz2", "zst", "7z", "rar", "tgz", "iso"],
  pdf: ["pdf"],
  document: ["doc", "docx", "odt", "rtf", "xls", "xlsx", "ods", "ppt", "pptx", "odp", "epub"],
  text: ["txt", "md", "log", "csv", "json", "toml", "yaml", "yml", "ini", "conf", "xml"],
  code: ["c", "h", "cc", "cpp", "hpp", "rs", "go", "py", "js", "ts", "qml", "lua", "sh", "java", "rb", "php", "html", "css", "nix"]
}

// The kind of file a suffix says: image, audio, video, archive, pdf,
// document, text, code, or file.
function kindOf(suffix) {
  var s = String(suffix).toLowerCase()
  for (var kind in KINDS) if (KINDS[kind].indexOf(s) >= 0) return kind
  return "file"
}

var GLYPHS = {
  folder: 0xF024B, image: 0xF02E9, audio: 0xF0386, video: 0xF022B, archive: 0xF05C4,
  pdf: 0xF0226, document: 0xF0219, text: 0xF0219, code: 0xF0169, file: 0xF0214,
  home: 0xF02DC, desktop: 0xF0379, documents: 0xF0219, downloads: 0xF01DA, music: 0xF0388,
  pictures: 0xF02E9, videos: 0xF0567, bookmark: 0xF00C0, drive: 0xF02CA, computer: 0xF0322,
  back: 0xF004D, forward: 0xF0054, up: 0xF0143, down: 0xF0140, plus: 0xF0415
}

// A glyph of Nova's icon font by name: a place's, a kind of file's, or a
// button's.
function glyph(name) {
  return String.fromCodePoint(GLYPHS.hasOwnProperty(name) ? GLYPHS[name] : GLYPHS.folder)
}

function fileGlyph(isDir, suffix) {
  return glyph(isDir ? "folder" : kindOf(suffix))
}
