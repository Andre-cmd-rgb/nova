pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "BorderGeometry.js" as Geometry

// The shell's look but for its colours. The corners and the gap to the
// screen's edge follow Hyprland; the type scale, the spacing, the bar's size
// and how a control looks in each state follow the [font], [spacing], [bar]
// and [controls] sections of the shell.toml Color reads.
QtObject {
  id: style

  // "section.key" -> text, the user's shell.toml over the theme's.
  readonly property var toml: Commons.Color.shellValues

  // A whole number of pixels shell.toml gives for <key>, or <otherwise>.
  function pixels(key, otherwise) {
    var px = parseInt(toml[key], 10)
    return px > 0 ? px : otherwise
  }

  // true, 1, yes or on; false, 0, no or off; in any case. Anything else, or
  // nothing, is <otherwise>.
  function flag(value, otherwise) {
    if (value === undefined || value === null) return otherwise
    var word = String(value).trim().toLowerCase()
    if (["true", "1", "yes", "on"].indexOf(word) >= 0) return true
    if (["false", "0", "no", "off"].indexOf(word) >= 0) return false
    return otherwise
  }

  // ---------------------------------------------------------------- Hyprland
  //
  // cornerRadius is decoration:rounding. gapsOut is half of general:gaps_out:
  // the full gap, right between windows, leaves a panel or a notification
  // too far from the screen's edge. Both are asked of hyprctl at start, after
  // a theme is applied, and when the window-gaps toggle changes; without
  // Hyprland, or with an answer that is not one, what was there stays.

  property int cornerRadius: 0
  property int gapsOut: 5

  function refresh() {
    roundingQuery.running = true
    gapsQuery.running = true
  }

  // Hyprland reloads its config by itself when a file it read changes, a
  // moment later: asked at once, it would still give the old value.
  function scheduleRefresh() {
    settling.restart()
  }

  function hyprOption(text) {
    try {
      return JSON.parse(text || "{}") || {}
    } catch (e) {
      return {}
    }
  }

  function takeRounding(text) {
    var n = Number(hyprOption(text).int)
    if (isFinite(n) && n >= 0) cornerRadius = n
  }

  // gaps_out is CSS-style, "top right bottom left": the top is the gap.
  function takeGaps(text) {
    var option = hyprOption(text)
    var css = String(option.css || "").match(/-?\d+(?:\.\d+)?/g)
    var n = Number(css ? css[0] : option.int)
    if (isFinite(n) && n >= 0) gapsOut = Math.round(n / 2)
  }

  property Process roundingQuery: Process {
    command: ["hyprctl", "-j", "getoption", "decoration:rounding"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: style.takeRounding(text)
    }
  }

  property Process gapsQuery: Process {
    command: ["hyprctl", "-j", "getoption", "general:gaps_out"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: style.takeGaps(text)
    }
  }

  property Timer settling: Timer {
    interval: 200
    onTriggered: style.refresh()
  }

  // `nova toggle window-gaps` writes and removes this file, which Hyprland
  // reads.
  property FileView noGapsToggle: FileView {
    path: Commons.Color.stateHome + "/nova/toggles/hypr/window-no-gaps.lua"
    watchChanges: true
    printErrors: false
    onFileChanged: style.scheduleRefresh()
    onLoaded: style.scheduleRefresh()
    onLoadFailed: style.scheduleRefresh()
  }

  Component.onCompleted: refresh()

  // ---------------------------------------------------------------- type
  //
  // [font] base-size is the root of the type scale: every size is a multiple
  // of it, the default's at a base of 12 in the comments, unless [font] sets
  // that size in pixels itself. The family is "monospace", the fontconfig
  // alias `nova font set` points at the font chosen; a theme sets sizes, not
  // the family. NOVA_MENU_FONT, read at start, gives the summoned surfaces
  // (the menu, polkit, emojis, the clipboard) a family of their own.

  // At least 1 px; past that, as large as a theme or its user likes.
  readonly property int fontBaseSize: {
    var px = parseInt(toml["font.base-size"], 10)
    return isFinite(px) ? Math.max(1, px) : 12
  }
  readonly property real fontScale: fontBaseSize / 12

  function typeSize(key, times) {
    return pixels("font." + key, Math.max(1, Math.round(fontBaseSize * times)))
  }

  readonly property QtObject font: QtObject {
    readonly property string family: "monospace"
    readonly property string menuFamily: Quickshell.env("NOVA_MENU_FONT") || "monospace"
    readonly property int baseSize: style.fontBaseSize

    readonly property int caption: style.typeSize("caption", 0.833) // 10
    readonly property int bodySmall: style.typeSize("body-small", 0.917) // 11
    readonly property int body: style.typeSize("body", 1.0) // 12
    readonly property int subtitle: style.typeSize("subtitle", 1.083) // 13
    readonly property int title: style.typeSize("title", 1.167) // 14
    readonly property int heading: style.typeSize("heading", 1.333) // 16
    readonly property int display: style.typeSize("display", 2.0) // 24
    readonly property int displayLarge: style.typeSize("display-large", 2.333) // 28

    readonly property int icon: style.pixels("font.icon", title)
    readonly property int iconLarge: style.typeSize("icon-large", 1.5) // 18
  }

  // ---------------------------------------------------------------- bar
  //
  // The bar's sizes as at a 12 px base, which grow with the type unless
  // [bar] scale-with-font is off. [bar] size-horizontal and size-vertical set
  // its thickness on a top or bottom bar and on a side bar.

  readonly property bool barFollowsType: flag(toml["bar.scale-with-font"], true)

  function barSize(px) {
    return Math.max(1, Math.round(barFollowsType ? px * fontScale : px))
  }

  readonly property QtObject bar: QtObject {
    readonly property int sizeHorizontal: style.barSize(style.pixels("bar.size-horizontal", 26))
    readonly property int sizeVertical: style.barSize(style.pixels("bar.size-vertical", 28))
    readonly property int iconSlot: style.barSize(27)
    readonly property int iconCanvas: style.barSize(16)
    readonly property int iconFont: style.barSize(13)
    readonly property int statusSlot: style.barSize(21)
  }

  // ---------------------------------------------------------------- spacing
  //
  // A component asks for the pixels it was drawn with at the default scale,
  // space(px), and gets them scaled (spaceReal for fractions). [spacing]
  // scale sets the scale, which also grows with the type unless [spacing]
  // scale-with-font is off. A token named in [spacing] is pinned there, in
  // pixels, unscaled.

  readonly property real spacingScale: {
    var n = parseFloat(toml["spacing.scale"])
    return isFinite(n) && n >= 0 ? n : 1.0
  }
  readonly property real spaceScale: spacingScale * (flag(toml["spacing.scale-with-font"], true) ? fontScale : 1)

  function spaceReal(px) {
    var n = Number(px)
    return isFinite(n) && n > 0 ? n * spaceScale : 0
  }

  // Never rounded down to nothing: what asks for room gets a pixel at least.
  function space(px) {
    var n = spaceReal(px)
    return n > 0 ? Math.max(1, Math.round(n)) : 0
  }

  function spacingToken(key, px) {
    var n = parseFloat(toml["spacing." + key])
    return isFinite(n) && n >= 0 ? Math.round(n) : space(px)
  }

  readonly property QtObject spacing: QtObject {
    readonly property int hairline: style.space(1)
    readonly property int xxs: style.spacingToken("xxs", 2)
    readonly property int xs: style.spacingToken("xs", 3)
    readonly property int sm: style.spacingToken("sm", 4)
    readonly property int md: style.spacingToken("md", 6)
    readonly property int xl: style.spacingToken("xl", 10)
    readonly property int huge: style.spacingToken("huge", 18)

    readonly property int controlGap: style.spacingToken("control-gap", 8)
    readonly property int controlPaddingX: style.spacingToken("control-padding-x", 10)
    readonly property int controlPaddingY: style.spacingToken("control-padding-y", 6)
    readonly property int inputPaddingY: style.spacingToken("input-padding-y", 7)
    readonly property int controlHeight: style.spacingToken("control-height", 28)
    readonly property int popupRowHeight: style.spacingToken("popup-row-height", 28)
    readonly property int dropdownWidth: style.spacingToken("dropdown-width", 240)
    readonly property int rowGap: style.spacingToken("row-gap", 8)
    readonly property int rowPaddingX: style.spacingToken("row-padding-x", 12)
    readonly property int labelGap: style.spacingToken("label-gap", 4)
    readonly property int panelGap: style.spacingToken("panel-gap", 14)
    readonly property int panelPadding: style.spacingToken("panel-padding", 18)
    readonly property int popupPadding: style.spacingToken("popup-padding", 14)
  }

  // ---------------------------------------------------------------- controls
  //
  // How a control looks in each state:
  //   normal        at rest
  //   hover-cursor  under the mouse, or under a panel's keyboard cursor
  //   selected      chosen, or current
  //   focus         holding Qt's keyboard focus; as hover-cursor unless set
  //   pressed       held down, a fill only
  //   selection     selected text, a fill only
  // [controls] ([style] in older files) gives a state a colour,
  // <state>-color, a palette role or a hex colour; a fill's opacity,
  // <state>-fill-alpha; and a border's, <state>-border-alpha, and width,
  // <state>-border-width, where 0 draws none. Border reads the rest of a
  // control's border from there too.

  // [controls] as key -> text; a key in both sections is the later one's.
  readonly property var controls: {
    var found = {}
    for (var name in toml) {
      var at = name.indexOf(".")
      var section = name.substr(0, at)
      if (at > 0 && (section === "controls" || section === "style")) found[name.substr(at + 1)] = toml[name]
    }
    return found
  }

  // The states as [controls] sets them: { color, fill, border, width }, the
  // colour a token, the rest numbers; pressed and selection have no border.
  readonly property var states: {
    var given = controls
    function number(key, otherwise) {
      var n = Number(given[key])
      return isFinite(n) ? n : otherwise
    }
    function token(key, otherwise) {
      var text = typeof given[key] === "string" ? given[key].trim() : ""
      return text.length > 0 ? text : otherwise
    }
    function state(name, color, fill, border, width) {
      return {
        color: token(name + "-color", color),
        fill: Util.clampAlpha(number(name + "-fill-alpha", fill)),
        border: Util.clampAlpha(number(name + "-border-alpha", border)),
        width: Math.max(0, Math.round(number(name + "-border-width", width)))
      }
    }
    var normal = state("normal", "foreground", 0.04, 0.4, 1)
    var hover = state("hover-cursor", "foreground", 0.08, 0.25, normal.width)
    return {
      "normal": normal,
      "hover-cursor": hover,
      "selected": state("selected", "foreground", 0.18, 1.0, 0),
      "focus": state("focus", hover.color, hover.fill, hover.border, hover.width),
      "pressed": state("pressed", hover.color, 0.22, 0, 0),
      "selection": state("selection", "foreground", 0.35, 0, 0)
    }
  }

  readonly property int normalBorderWidth: states.normal.width

  // A state's colour for a control drawn in <foreground> and <accent>: its
  // token's role among those (the palette's where the control has none), the
  // palette's urgent or background, nothing at all for "transparent", or the
  // hex colour it is. Any other token is the control's foreground; pressed's
  // and focus's are hover-cursor's colour, which focus also takes for
  // "hover", "hover-cursor" and "inherit". An unknown state is normal.
  function stateColor(name, foreground, accent) {
    var leans = name === "pressed" || name === "focus"
    var otherwise = leans ? stateColor("hover-cursor", foreground, accent) : foreground || Commons.Color.foreground
    var token = (states[name] || states.normal).color
    switch (token.toLowerCase()) {
    case "hover":
    case "hover-cursor":
    case "inherit":
      if (name === "focus") return otherwise
      break
    case "foreground":
    case "text":
      return foreground || Commons.Color.foreground
    case "accent":
      return accent || Commons.Color.accent
    case "urgent":
      return Commons.Color.urgent
    case "background":
      return Commons.Color.background
    case "transparent":
      return Qt.rgba(0, 0, 0, 0)
    }
    var hex = token.charAt(0) === "#" ? Geometry.canonicalColor(token, 1) : ""
    return typeof hex === "string" ? otherwise : hex
  }

  function fill(name, foreground, accent) {
    return Util.alpha(stateColor(name, foreground, accent), states[name].fill)
  }

  function hoverStateColor(foreground, accent) { return stateColor("hover-cursor", foreground, accent) }
  function selectedStateColor(foreground, accent) { return stateColor("selected", foreground, accent) }

  function normalFillFor(foreground, accent) { return fill("normal", foreground, accent) }
  function hoverFillFor(foreground, accent) { return fill("hover-cursor", foreground, accent) }
  function selectedFillFor(foreground, accent) { return fill("selected", foreground, accent) }
  function pressedFillFor(foreground, accent) { return fill("pressed", foreground, accent) }
  function focusFillFor(foreground, accent) { return fill("focus", foreground, accent) }
  function selectionFillFor(foreground, accent) { return fill("selection", foreground, accent) }

  function normalBorderFor(foreground, accent) {
    return Util.alpha(stateColor("normal", foreground, accent), states.normal.border)
  }

  // A form control's fill: focused, then under the pointer or the panel's
  // cursor, then at rest.
  function controlFill(focused, hot, foreground, accent) {
    return fill(focused ? "focus" : hot ? "hover-cursor" : "normal", foreground, accent)
  }

  // The fills of the states in the palette's own colours.
  readonly property color hoverFill: hoverFillFor(Commons.Color.foreground, Commons.Color.accent)
  readonly property color selectedFill: selectedFillFor(Commons.Color.foreground, Commons.Color.accent)
  readonly property color selectionFill: selectionFillFor(Commons.Color.foreground, Commons.Color.accent)
}
