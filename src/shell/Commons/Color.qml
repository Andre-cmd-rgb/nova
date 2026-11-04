pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "BorderGeometry.js" as Geometry

// The shell's colours. The palette (foreground, background, accent, urgent
// and muted) is the theme's colors.toml. A surface's colours are its section
// of the theme's shell.toml, rendered from theme/templates/shell.toml.tpl
// unless the theme brings its own, with ~/.config/nova/shell.toml over it;
// what neither sets is the palette's.
//
// The theme's files are read once, at start: `nova theme` sends a new theme's
// over IPC (the background's themeTransition). The user's file is watched.
// Style reads its own sections of the same shell.toml from shellValues.
QtObject {
  id: colors

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  // The greeter runs as another user and reads the theme's mirror instead.
  readonly property string themeDir: Quickshell.env("NOVA_THEME_DIR") || stateHome + "/nova/current/theme"

  property color foreground: "#cacccc"
  property color background: "#101315"
  property color accent: "#cacccc"
  property color urgent: "#a55555"
  property color muted: "#707880"

  // ---------------------------------------------------------------- colors.toml

  // Its "#rrggbb" values. A theme with only the sixteen terminal colours
  // gets its background from color0, foreground from color7, accent from
  // color4 and muted from color8; urgent is red or color1, whichever comes
  // last. Muted with neither is the foreground; any other colour the file
  // leaves out keeps the one it had.
  function loadColors(raw) {
    var named = {}
    String(raw || "").split("\n").forEach(function(line) {
      var m = /^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/.exec(line)
      if (m) named[m[1] === "color1" ? "red" : m[1]] = m[2]
    })
    var terminal = { background: "color0", foreground: "color7", accent: "color4" }
    for (var role in terminal) {
      var value = named[role] || named[terminal[role]]
      if (value) colors[role] = value
    }
    if (named.red) urgent = named.red
    muted = named.muted || named.color8 || foreground
  }

  // ---------------------------------------------------------------- shell.toml

  // "section.key" -> the value's text, the user's over the theme's. It is
  // replaced, never changed in place, so that all that is read from it is
  // worked out again.
  property var shellValues: ({})
  property var themeShell: ({})
  property var userShell: ({})

  // shell.toml as "section.key" -> text. Readers make numbers of what they
  // need as numbers. A key before the first section, and a line of any other
  // shape, is passed over.
  function parseShell(raw) {
    var table = {}
    var section = ""
    String(raw || "").split("\n").forEach(function(line) {
      var text = line.trim()
      if (text === "" || text.charAt(0) === "#") return
      var header = /^\[([A-Za-z0-9_-]+)\]\s*(#.*)?$/.exec(text)
      // A value is a quoted string, a list of up to four numbers, or a bare
      // word; a comment may follow it.
      var m = header ? null : /^([A-Za-z0-9_-]+)\s*=\s*(?:["']([^"']+)["']|(-?\d+(?:\.\d+)?(?:\s+-?\d+(?:\.\d+)?){0,3})|([A-Za-z][A-Za-z0-9_-]*))\s*(#.*)?$/.exec(text)
      if (header) section = header[1]
      else if (m && section) table[section + "." + m[1]] = m[2] || m[3] || m[4]
    })
    return table
  }

  function loadShell(raw) {
    themeShell = parseShell(raw)
    shellValues = Object.assign({}, themeShell, userShell)
  }

  function loadUserShell(raw) {
    userShell = parseShell(raw)
    shellValues = Object.assign({}, themeShell, userShell)
  }

  // ---------------------------------------------------------------- reading

  // The palette colour each role names.
  readonly property var roles: ({ foreground: "foreground", text: "foreground", accent: "accent", urgent: "urgent",
    muted: "muted", background: "background" })

  // The first word of a value that is not an angle: a gradient's first
  // colour. With none, the value as it is.
  function firstColor(value) {
    var words = String(value || "").trim().split(/\s+/)
    for (var i = 0; i < words.length; i++) {
      if (!/^-?\d+(?:\.\d+)?deg$/.test(words[i])) return words[i]
    }
    return value
  }

  // One colour for a value: the first of a gradient's, another key's for its
  // name, followed until it is no name or names one come round again, a
  // palette colour for its role, or a colour as Geometry reads them. Any
  // other word (a colour's name) is <fallback>.
  function flatColor(value, fallback) {
    var word = firstColor(value)
    var key = String(word || "").trim().toLowerCase()
    var followed = {}
    while (shellValues[key] && shellValues[key] !== word && !followed[key]) {
      followed[key] = true
      word = firstColor(shellValues[key])
      key = String(word || "").trim().toLowerCase()
    }
    if (roles.hasOwnProperty(key)) return colors[roles[key]]
    if (key === "transparent") return Qt.rgba(0, 0, 0, 0)
    var read = Geometry.canonicalColor(word, 1)
    return read === word && word.charAt(0) !== "#" ? fallback : read
  }

  // The opacity <key> sets, 0 to 1, or <otherwise> when it sets none.
  function opacity(key, otherwise) {
    var n = Number(shellValues[key])
    return shellValues[key] && isFinite(n) ? Util.clampAlpha(n) : otherwise
  }

  // <section>.<key> as a colour, <fallback> where it is not set, at the
  // opacity of <section>.<key>-alpha, or of <section>.<alphaKey>.
  function paint(section, key, fallback, alpha, alphaKey) {
    var value = shellValues[section + "." + key]
    return Util.alpha(value ? flatColor(value, fallback) : fallback, opacity(section + "." + (alphaKey || key + "-alpha"), alpha))
  }

  // A text colour, as shell.toml writes it, or <fallback>.
  function ink(section, key, fallback) {
    return shellValues[section + "." + key] || fallback
  }

  // ---------------------------------------------------------------- surfaces

  readonly property QtObject bar: QtObject {
    property color background: colors.paint("bar", "background", colors.background, 1.0)
    property color text: colors.ink("bar", "text", colors.foreground)
    property color active: colors.ink("bar", "active", colors.urgent)
  }

  readonly property QtObject popups: QtObject {
    property color background: colors.paint("popups", "background", colors.background, 1.0)
    property color text: colors.ink("popups", "text", colors.foreground)
    property color border: colors.paint("popups", "border", colors.accent, 1.0)
  }

  readonly property QtObject tooltip: QtObject {
    property color background: colors.paint("tooltip", "background", colors.background, 1.0)
    property color text: colors.ink("tooltip", "text", colors.foreground)
    property color border: colors.paint("tooltip", "border", colors.foreground, 1.0)
  }

  readonly property QtObject notifications: QtObject {
    property color background: colors.paint("notifications", "background", colors.background, 1.0)
    property color text: colors.ink("notifications", "text", colors.foreground)
    property color border: colors.paint("notifications", "border", colors.accent, 1.0)
  }

  readonly property QtObject menu: QtObject {
    property color background: colors.paint("menu", "background", colors.background, 1.0)
    property color text: colors.ink("menu", "text", colors.foreground)
    property color border: colors.paint("menu", "border", colors.foreground, 1.0)
    property color scrim: colors.paint("menu", "scrim", colors.background, 0.5)
    property color selectedBackground: colors.paint("menu", "selected-background", colors.foreground, 0.08)
    property color selectedText: colors.ink("menu", "selected-text", colors.accent)
    property color selectedBorder: colors.paint("menu", "selected-border", colors.foreground, 0.0)
  }

  // The polkit card's borders, and the lock's, share one border-alpha: only
  // one of them shows at a time.
  readonly property QtObject polkit: QtObject {
    property color background: colors.paint("polkit", "background", colors.background, 1.0)
    property color text: colors.ink("polkit", "text", colors.foreground)
    property color textError: colors.ink("polkit", "text-error", colors.urgent)
    property color border: colors.paint("polkit", "border", colors.accent, 1.0)
    property color borderError: colors.paint("polkit", "border-error", colors.urgent, 1.0, "border-alpha")
    property color accent: colors.ink("polkit", "accent", colors.accent)
    property color scrim: colors.paint("polkit", "scrim", colors.background, 0.5)
  }

  readonly property QtObject lock: QtObject {
    property color background: colors.paint("lock", "background", colors.background, 0.8)
    property color text: colors.ink("lock", "text", colors.foreground)
    property color placeholder: colors.flatColor(colors.shellValues["lock.placeholder"] || "", Util.alpha(colors.foreground, 0.66))
    property color textError: colors.ink("lock", "text-error", colors.urgent)
    property color borderActive: colors.paint("lock", "border-active", colors.accent, 1.0, "border-alpha")
    property color borderError: colors.paint("lock", "border-error", colors.urgent, 1.0, "border-alpha")
    property color selection: colors.paint("lock", "selection", colors.accent, 0.45)
  }

  // The image picker has no card: its scrim is the wash over the whole screen.
  readonly property QtObject imagePicker: QtObject {
    property color scrim: colors.paint("image-picker", "scrim", colors.background, 0.5)
    property color text: colors.ink("image-picker", "text", colors.foreground)
    property color selectedBorder: colors.paint("image-picker", "selected-border", colors.accent, 1.0)
    property color unselectedBorder: colors.paint("image-picker", "unselected-border", colors.foreground, 0.28)
  }

  // ---------------------------------------------------------------- files

  property FileView colorsFile: FileView {
    path: colors.themeDir + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: colors.loadColors(text())
  }

  property FileView shellFile: FileView {
    path: colors.themeDir + "/shell.toml"
    watchChanges: false
    printErrors: false
    onLoaded: colors.loadShell(text())
    onLoadFailed: colors.loadShell("")
  }

  // Where `nova display text size` writes [font] base-size, so it takes
  // effect at once. On a change, text() still holds what was read before:
  // the file is read again, and loaded hands it over.
  property FileView userShellFile: FileView {
    path: colors.home + "/.config/nova/shell.toml"
    watchChanges: true
    printErrors: false
    onLoaded: colors.loadUserShell(text())
    onFileChanged: reload()
    onLoadFailed: colors.loadUserShell("")
  }
}
