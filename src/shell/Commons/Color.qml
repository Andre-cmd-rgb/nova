pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "ColorText.js" as ColorText
import "ShellToml.js" as ShellToml

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

  // The palette until colors.toml is read, and whatever it leaves out.
  property color foreground: "#cacccc"
  property color background: "#101315"
  property color accent: "#cacccc"
  property color urgent: "#a55555"
  property color muted: "#707880"

  // The palette colour each role names.
  readonly property var roles: ({ foreground: "foreground", text: "foreground", accent: "accent", urgent: "urgent",
    muted: "muted", background: "background" })

  // The theme's hues by name, for what is told apart by colour (a calendar):
  // red, orange, yellow, green, cyan, blue and magenta, the terminal's
  // colours where the theme names no other. A theme without orange has it
  // between its red and its yellow; these until colors.toml is read, and
  // for what it leaves out.
  readonly property var defaultHues: ({ red: "#c46a6a", orange: "#c98d5e", yellow: "#c9b26a", green: "#86a86e",
    cyan: "#6aaaa8", blue: "#6f93c4", magenta: "#a681bd" })
  property var hues: defaultHues

  // A hue by its name, or the accent ("accent", or one the theme has not).
  function hue(name) {
    return hues[name] || accent
  }

  // "section.key" -> the value's text, the user's shell.toml over the
  // theme's. It is replaced, never changed in place, so that all that is
  // read from it is worked out again.
  property var shellValues: ({})
  property var _themeValues: ({})
  property var _userValues: ({})

  // ---------------------------------------------------------------- loading

  // A theme with only the sixteen terminal colours takes its background
  // from color0, its foreground from color7 and its accent from color4;
  // urgent is red or color1, whichever comes last, and muted is color8, or
  // the foreground with neither.
  function loadColors(raw) {
    const named = ShellToml.paletteNames(raw)
    for (const [role, terminal] of [["background", "color0"], ["foreground", "color7"], ["accent", "color4"]]) {
      const value = named[role] || named[terminal]
      if (value) colors[role] = value
    }
    if (named.red) urgent = named.red
    muted = named.muted || named.color8 || foreground
    const found = {}
    for (const [hueName, terminal] of [["red", "color1"], ["green", "color2"], ["yellow", "color3"], ["blue", "color4"], ["magenta", "color5"], ["cyan", "color6"]]) {
      const value = named[hueName] || named[terminal]
      if (value) found[hueName] = value
    }
    found.orange = named.orange || (found.red && found.yellow ? Qt.tint(found.red, Qt.alpha(found.yellow, 0.5)) : undefined)
    if (!found.orange) delete found.orange
    hues = Object.assign({}, defaultHues, found)
  }

  function loadShell(raw) {
    _themeValues = ShellToml.parse(raw)
    _mergeValues()
  }

  function _loadUserShell(raw) {
    _userValues = ShellToml.parse(raw)
    _mergeValues()
  }

  function _mergeValues() {
    shellValues = Object.assign({}, _themeValues, _userValues)
  }

  // ---------------------------------------------------------------- reading

  // The colour a value ends at: a gradient's first colour, and the value of
  // a key it names, followed until it names none, or a key whose value is
  // its own name, or one come round again.
  function _followed(value) {
    let word = ShellToml.firstColor(value)
    const passed = new Set()
    for (;;) {
      const key = String(word || "").trim().toLowerCase()
      const next = shellValues[key]
      if (!next || next === word || passed.has(key)) return { word, key }
      passed.add(key)
      word = ShellToml.firstColor(next)
    }
  }

  // One colour for a value: a palette colour for its role, nothing for
  // "transparent", or a colour as ColorText reads them. Any other word (a
  // colour's name) is <fallback>.
  function flatColor(value, fallback) {
    const end = _followed(value)
    if (roles.hasOwnProperty(end.key)) return colors[roles[end.key]]
    if (end.key === "transparent") return Qt.rgba(0, 0, 0, 0)
    const read = ColorText.read(end.word, 1)
    return read === end.word && end.word.charAt(0) !== "#" ? fallback : read
  }

  // <section>.<key> as a colour, <fallback> where it is not set, at the
  // opacity <section>.<key>-alpha sets, or <section>.<alphaKey>, else at
  // <alpha>.
  function paint(section, key, fallback, alpha, alphaKey) {
    const value = shellValues[section + "." + key]
    const alphaText = shellValues[section + "." + (alphaKey || key + "-alpha")]
    const opacity = alphaText && isFinite(Number(alphaText)) ? Util.clampAlpha(Number(alphaText)) : alpha
    return Util.alpha(value ? flatColor(value, fallback) : fallback, opacity)
  }

  // Text in <ink> on <behind>, quieter: <alpha> of the way from <behind> to
  // <ink>, as the design asks, but never less legible than 4:1 for text at
  // 0.6 or more, nor 3:1 for fainter text (or <ink>'s own, when lower). A
  // fade loses contrast faster on a light theme than on a dark one: on
  // Rosé Pine a line at 0.5 fell to 2:1. There it fades less.
  function quieter(ink, behind, alpha) {
    const a = Util.clampAlpha(alpha)
    const floor = Math.min(a >= 0.6 ? 4 : 3, Util.contrast(ink, behind))
    let shade = ink
    for (let x = a; x < 1; x += 0.02) {
      shade = Qt.tint(behind, Qt.rgba(ink.r, ink.g, ink.b, x))
      if (Util.contrast(shade, behind) >= floor) return shade
    }
    return Qt.rgba(ink.r, ink.g, ink.b, 1)
  }

  // A text colour, as shell.toml writes it, or <fallback>.
  function ink(section, key, fallback) {
    return shellValues[section + "." + key] || fallback
  }

  // ---------------------------------------------------------------- surfaces

  // A surface's background and text from its section; each adds the rest of
  // its colours.
  component Surface: QtObject {
    required property string section
    property color background: colors.paint(section, "background", colors.background, 1.0)
    property color text: colors.ink(section, "text", colors.foreground)
  }

  readonly property QtObject bar: Surface {
    section: "bar"
    property color active: colors.ink("bar", "active", colors.urgent)
  }

  readonly property QtObject popups: Surface {
    section: "popups"
    property color border: colors.paint("popups", "border", colors.accent, 1.0)
  }

  readonly property QtObject tooltip: Surface {
    section: "tooltip"
    property color border: colors.paint("tooltip", "border", colors.foreground, 1.0)
  }

  readonly property QtObject notifications: Surface {
    section: "notifications"
    property color border: colors.paint("notifications", "border", colors.accent, 1.0)
  }

  readonly property QtObject menu: Surface {
    section: "menu"
    property color border: colors.paint("menu", "border", colors.foreground, 1.0)
    property color scrim: colors.paint("menu", "scrim", colors.background, 0.5)
    property color selectedBackground: colors.paint("menu", "selected-background", colors.foreground, 0.08)
    property color selectedText: colors.ink("menu", "selected-text", colors.accent)
    property color selectedBorder: colors.paint("menu", "selected-border", colors.foreground, 0.0)
  }

  // The polkit card's borders, and the lock's, share one border-alpha: only
  // one of them shows at a time.
  readonly property QtObject polkit: Surface {
    section: "polkit"
    property color textError: colors.ink("polkit", "text-error", colors.urgent)
    property color border: colors.paint("polkit", "border", colors.accent, 1.0)
    property color borderError: colors.paint("polkit", "border-error", colors.urgent, 1.0, "border-alpha")
    property color accent: colors.ink("polkit", "accent", colors.accent)
    property color scrim: colors.paint("polkit", "scrim", colors.background, 0.5)
  }

  readonly property QtObject lock: Surface {
    section: "lock"
    background: colors.paint("lock", "background", colors.background, 0.8)
    property color placeholder: colors.flatColor(colors.shellValues["lock.placeholder"] || "", Util.alpha(colors.foreground, 0.66))
    property color textError: colors.ink("lock", "text-error", colors.urgent)
    property color borderActive: colors.paint("lock", "border-active", colors.accent, 1.0, "border-alpha")
    property color borderError: colors.paint("lock", "border-error", colors.urgent, 1.0, "border-alpha")
    property color selection: colors.paint("lock", "selection", colors.accent, 0.45)
  }

  // The image picker has no card: its scrim is the wash over the whole
  // screen.
  readonly property QtObject imagePicker: Surface {
    section: "image-picker"
    property color scrim: colors.paint("image-picker", "scrim", colors.background, 0.5)
    property color selectedBorder: colors.paint("image-picker", "selected-border", colors.accent, 1.0)
    property color unselectedBorder: colors.paint("image-picker", "unselected-border", colors.foreground, 0.28)
  }

  // ---------------------------------------------------------------- files

  property FileView _colorsFile: FileView {
    path: colors.themeDir + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: colors.loadColors(text())
  }

  property FileView _themeShellFile: FileView {
    path: colors.themeDir + "/shell.toml"
    watchChanges: false
    printErrors: false
    onLoaded: colors.loadShell(text())
    onLoadFailed: colors.loadShell("")
  }

  // Where `nova display text size` writes [font] base-size, so it takes
  // effect at once. On a change, text() still holds what was read before:
  // the file is read again, and loaded hands it over.
  property FileView _userShellFile: FileView {
    path: colors.home + "/.config/nova/shell.toml"
    watchChanges: true
    printErrors: false
    onLoaded: colors._loadUserShell(text())
    onFileChanged: reload()
    onLoadFailed: colors._loadUserShell("")
  }
}
