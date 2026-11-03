pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "BorderGeometry.js" as Geometry

// The shell's colours. The palette, foreground, background, accent, urgent and
// muted, is the theme's colors.toml. Each surface's colours are its section in
// the theme's shell.toml (rendered from theme/templates/shell.toml.tpl unless
// the theme brings its own) with ~/.config/nova/shell.toml over it; what
// neither sets is the palette's.
//
// The theme's files are read once, at start: `nova theme` sends a new theme's
// over IPC (shell.qml's applyTheme). The user's file is watched.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  // The greeter runs as another user and reads the theme mirror instead.
  readonly property string currentThemePath: Quickshell.env("NOVA_THEME_DIR") || stateHome + "/nova/current/theme"

  property color foreground: "#cacccc"
  property color background: "#101315"
  property color accent: "#cacccc"
  property color urgent: "#a55555"
  property color muted: "#707880"

  // shell.toml as "section.key" -> the value's text, the user's over the
  // theme's. It is replaced, never changed in place, so that every colour
  // read from it is worked out again.
  property var shellValues: ({})
  property var themeShellValues: ({})
  property var userShellValues: ({})

  // The value of <key>, or <fallback> when it is not set.
  function pick(key, fallback) {
    var raw = shellValues[key]
    return typeof raw === "string" && raw.length > 0 ? raw : fallback
  }

  // The opacity at <key>, 0 to 1, or <fallback> when it is not a number.
  function pickAlpha(key, fallback) {
    var raw = shellValues[key]
    if (typeof raw !== "string" || raw.length === 0) return fallback
    var n = Number(raw)
    return isFinite(n) ? Util.clampAlpha(n) : fallback
  }

  // The first colour of a value that may be a gradient: its first word that
  // is not an angle.
  function firstColorToken(value) {
    var words = String(value || "").trim().split(/\s+/)
    for (var i = 0; i < words.length; i++) {
      if (!/^-?\d+(?:\.\d+)?deg$/.test(words[i])) return words[i]
    }
    return value
  }

  // One colour for a value: the first of a gradient's, another key's for its
  // name, a palette colour for its role, or a colour as Geometry reads them.
  // Anything else, a colour name or names that come round again included,
  // is <fallback>.
  function flatColor(value, fallback) {
    var token = firstColorToken(value)
    var role = String(token || "").trim().toLowerCase()
    var followed = {}
    while (shellValues[role] && shellValues[role] !== token && !followed[role]) {
      followed[role] = true
      token = firstColorToken(shellValues[role])
      role = String(token || "").trim().toLowerCase()
    }
    switch (role) {
    case "foreground":
    case "text":
      return foreground
    case "accent":
      return accent
    case "urgent":
      return urgent
    case "muted":
      return muted
    case "background":
      return background
    case "transparent":
      return Qt.rgba(0, 0, 0, 0)
    }
    var color = Geometry.canonicalColor(token, 1)
    if (typeof color === "string" && color === token && token.charAt(0) !== "#") return fallback
    return color
  }

  // <colorKey>'s colour at <alphaKey>'s opacity, each with its fallback.
  function composed(colorKey, alphaKey, colorFallback, alphaFallback) {
    return Util.alpha(flatColor(pick(colorKey, colorFallback), colorFallback), pickAlpha(alphaKey, alphaFallback))
  }

  // <section>.<key> at <section>.<key>-alpha, or at the opacity key given.
  function surfaceColor(section, key, fallback, alpha, alphaKey) {
    return composed(section + "." + key, section + "." + (alphaKey || key + "-alpha"), fallback, alpha)
  }

  readonly property QtObject bar: QtObject {
    property color background: root.surfaceColor("bar", "background", root.background, 1.0)
    property color text: root.pick("bar.text", root.foreground)
    property color active: root.pick("bar.active", root.urgent)
  }

  readonly property QtObject popups: QtObject {
    property color background: root.surfaceColor("popups", "background", root.background, 1.0)
    property color text: root.pick("popups.text", root.foreground)
    property color border: root.surfaceColor("popups", "border", root.accent, 1.0)
  }

  readonly property QtObject tooltip: QtObject {
    property color background: root.surfaceColor("tooltip", "background", root.background, 1.0)
    property color text: root.pick("tooltip.text", root.foreground)
    property color border: root.surfaceColor("tooltip", "border", root.foreground, 1.0)
  }

  readonly property QtObject notifications: QtObject {
    property color background: root.surfaceColor("notifications", "background", root.background, 1.0)
    property color text: root.pick("notifications.text", root.foreground)
    property color border: root.surfaceColor("notifications", "border", root.accent, 1.0)
  }

  readonly property QtObject menu: QtObject {
    property color background: root.surfaceColor("menu", "background", root.background, 1.0)
    property color text: root.pick("menu.text", root.foreground)
    property color border: root.surfaceColor("menu", "border", root.foreground, 1.0)
    property color scrim: root.surfaceColor("menu", "scrim", root.background, 0.5)
    property color selectedBackground: root.surfaceColor("menu", "selected-background", root.foreground, 0.08)
    property color selectedText: root.pick("menu.selected-text", root.accent)
    property color selectedBorder: root.surfaceColor("menu", "selected-border", root.foreground, 0.0)
  }

  // The polkit dialog's and the lock's borders share one border-alpha: only
  // one of them shows at a time.
  readonly property QtObject polkit: QtObject {
    property color background: root.surfaceColor("polkit", "background", root.background, 1.0)
    property color text: root.pick("polkit.text", root.foreground)
    property color textError: root.pick("polkit.text-error", root.urgent)
    property color border: root.surfaceColor("polkit", "border", root.accent, 1.0)
    property color borderError: root.surfaceColor("polkit", "border-error", root.urgent, 1.0, "border-alpha")
    property color accent: root.pick("polkit.accent", root.accent)
    property color scrim: root.surfaceColor("polkit", "scrim", root.background, 0.5)
  }

  readonly property QtObject lock: QtObject {
    property color background: root.surfaceColor("lock", "background", root.background, 0.8)
    property color text: root.pick("lock.text", root.foreground)
    property color placeholder: root.flatColor(root.shellValues["lock.placeholder"] || "", Util.alpha(root.foreground, 0.66))
    property color textError: root.pick("lock.text-error", root.urgent)
    property color border: root.surfaceColor("lock", "border", root.foreground, 1.0)
    property color borderActive: root.surfaceColor("lock", "border-active", root.accent, 1.0, "border-alpha")
    property color borderError: root.surfaceColor("lock", "border-error", root.urgent, 1.0, "border-alpha")
    property color selection: root.surfaceColor("lock", "selection", root.accent, 0.45)
  }

  // The image picker has no card: its scrim is the wash over the whole screen.
  readonly property QtObject imagePicker: QtObject {
    property color scrim: root.surfaceColor("image-picker", "scrim", root.background, 0.5)
    property color text: root.pick("image-picker.text", root.foreground)
    property color selectedBorder: root.surfaceColor("image-picker", "selected-border", root.accent, 1.0)
    property color unselectedBorder: root.surfaceColor("image-picker", "unselected-border", root.foreground, 0.28)
  }

  // colors.toml's "#rrggbb" values. A theme with only the sixteen terminal
  // colours gets its background from color0, foreground from color7, accent
  // from color4 and muted from color8; urgent is red, or color1, whichever
  // comes last. Muted with neither is the foreground; any other colour the
  // file leaves out keeps the one it had.
  function loadColors(raw) {
    var found = {}
    var red = ""
    String(raw || "").split("\n").forEach(function(line) {
      var m = line.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (!m) return
      if (m[1] === "red" || m[1] === "color1") red = m[2]
      else found[m[1]] = m[2]
    })
    if (found.background || found.color0) background = found.background || found.color0
    if (found.foreground || found.color7) foreground = found.foreground || found.color7
    if (found.accent || found.color4) accent = found.accent || found.color4
    if (red) urgent = red
    muted = found.muted || found.color8 || foreground
  }

  // shell.toml as "section.key" -> text: quoted strings, numbers, lists of up
  // to four numbers, and bare words, each with an optional comment after it.
  // Readers make numbers of what they need as numbers. A key before the first
  // section, and a line of any other shape, is passed over.
  function parseShell(raw) {
    var parsed = {}
    var section = ""
    String(raw || "").split("\n").forEach(function(line) {
      line = line.trim()
      if (!line || line.charAt(0) === "#") return
      var header = line.match(/^\[([A-Za-z0-9_-]+)\]\s*(#.*)?$/)
      if (header) {
        section = header[1]
        return
      }
      var entry = line.match(/^([A-Za-z0-9_-]+)\s*=\s*(?:["']([^"']+)["']|(-?\d+(?:\.\d+)?(?:\s+-?\d+(?:\.\d+)?){0,3})|([A-Za-z][A-Za-z0-9_-]*))\s*(#.*)?$/)
      if (entry && section) parsed[section + "." + entry[1]] = entry[2] || entry[3] || entry[4]
    })
    return parsed
  }

  // The user's values over the theme's, handed to Style too, which reads its
  // sizes and control states from the same file.
  function mergeShell() {
    var merged = {}
    for (var themeKey in themeShellValues) merged[themeKey] = themeShellValues[themeKey]
    for (var userKey in userShellValues) merged[userKey] = userShellValues[userKey]
    shellValues = merged
    Style.applyShellValues(merged)
  }

  function loadShell(raw) {
    themeShellValues = parseShell(raw)
    mergeShell()
  }

  function loadUserShell(raw) {
    userShellValues = parseShell(raw)
    mergeShell()
  }

  property FileView colorsFile: FileView {
    path: root.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.loadColors(text())
  }

  property FileView shellFile: FileView {
    path: root.currentThemePath + "/shell.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.loadShell(text())
    onLoadFailed: root.loadShell("")
  }

  // Where `nova display text size` writes [font] base-size, so it takes
  // effect at once. On a change, text() still holds what was read before:
  // the file is read again, and loaded hands it over.
  property FileView userShellFile: FileView {
    path: root.home + "/.config/nova/shell.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadUserShell(text())
    onFileChanged: reload()
    onLoadFailed: root.loadUserShell("")
  }
}
