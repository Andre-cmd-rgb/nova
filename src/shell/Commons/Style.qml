pragma Singleton
import QtQuick
import qs.Commons as Commons
import Quickshell
import Quickshell.Io

// Everything about the shell's look but its colours: corners and the gap to
// the screen's edge, which follow Hyprland, and from shell.toml the controls'
// states, the spacing, the type sizes and the bar's size.
//
// cornerRadius is Hyprland's decoration:rounding. gapsOut is half its
// general:gaps_out: the full gap, right between windows, leaves a panel or a
// notification too far from the screen's edge. Both are asked of hyprctl at
// start, after a theme is applied, and when the window-gaps toggle changes.
//
// [font] base-size is the root of the type scale: every Style.font size is a
// multiple of it unless shell.toml sets that size itself. [spacing] scale
// multiplies every margin, gap, padding and control size, and by default
// grows with base-size too, as do the bar's sizes ([bar] size-horizontal and
// size-vertical, given for a 12px base).
QtObject {
  id: root

  property int cornerRadius: 0
  property int gapsOut: 5

  // ---------------------------------------------------------- control states
  //
  // How a control looks in each state, from [controls] in shell.toml ([style]
  // in older ones):
  //   normal        at rest
  //   hover-cursor  under the mouse, or under a panel's keyboard cursor
  //   selected      chosen, or current
  //   focus         holding Qt's keyboard focus; as hover-cursor unless set
  // and pressed and selection, which are fills only. A state has a colour
  // (<state>-color: a palette role or a hex colour), a fill alpha, and a
  // border's alpha and width; a width of 0 draws no border.
  property var styleOverrides: ({})

  function styleRawNum(key) {
    var n = Number(styleOverrides[key])
    return isFinite(n) ? n : null
  }

  function styleNum(key, fallback) {
    var n = styleRawNum(key)
    return n === null ? fallback : n
  }

  function styleAlpha(key, fallback) {
    return Util.clampAlpha(styleNum(key, fallback))
  }

  function styleString(key, fallback) {
    var raw = styleOverrides[key]
    if (typeof raw !== "string") return fallback
    raw = raw.trim()
    return raw.length > 0 ? raw : fallback
  }

  function styleWidth(key, fallback) {
    return Math.max(0, Math.round(styleNum(key, fallback)))
  }

  readonly property string normalColorToken: styleString("normal-color", "foreground")
  readonly property string hoverColorToken: styleString("hover-cursor-color", "foreground")
  readonly property string selectedColorToken: styleString("selected-color", "foreground")
  readonly property string pressedColorToken: styleString("pressed-color", hoverColorToken)
  readonly property string focusColorToken: styleString("focus-color", hoverColorToken)
  readonly property string selectionColorToken: styleString("selection-color", "foreground")

  readonly property int normalBorderWidth: styleWidth("normal-border-width", 1)
  readonly property int hoverBorderWidth: styleWidth("hover-cursor-border-width", normalBorderWidth)
  readonly property int selectedBorderWidth: styleWidth("selected-border-width", 0)
  readonly property int focusBorderWidth: styleWidth("focus-border-width", hoverBorderWidth)

  readonly property real normalFillAlpha: styleAlpha("normal-fill-alpha", 0.04)
  readonly property real hoverFillAlpha: styleAlpha("hover-cursor-fill-alpha", 0.08)
  readonly property real selectedFillAlpha: styleAlpha("selected-fill-alpha", 0.18)
  readonly property real pressedFillAlpha: styleAlpha("pressed-fill-alpha", 0.22)
  readonly property real focusFillAlpha: styleAlpha("focus-fill-alpha", hoverFillAlpha)
  readonly property real selectionFillAlpha: styleAlpha("selection-fill-alpha", 0.35)

  readonly property real normalBorderAlpha: styleAlpha("normal-border-alpha", 0.4)
  readonly property real hoverBorderAlpha: styleAlpha("hover-cursor-border-alpha", 0.25)
  readonly property real selectedBorderAlpha: styleAlpha("selected-border-alpha", 1.0)
  readonly property real focusBorderAlpha: styleAlpha("focus-border-alpha", hoverBorderAlpha)

  // "#rgb", "#rrggbb" or "#rrggbbaa" as a colour; anything else is <fallback>.
  function colorFromHex(value, fallback) {
    var text = String(value || "").trim()
    var three = text.match(/^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$/)
    var channel = function(digits) { return parseInt(digits, 16) / 255 }
    if (three) return Qt.rgba(channel(three[1] + three[1]), channel(three[2] + three[2]), channel(three[3] + three[3]), 1)
    var full = text.match(/^#([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})?$/)
    if (!full) return fallback
    return Qt.rgba(channel(full[1]), channel(full[2]), channel(full[3]), full[4] ? channel(full[4]) : 1)
  }

  // A state's colour token against a control's own colours: a role picks one
  // of them (the palette's where the control has none), a hex colour is
  // itself, and anything else is <fallback>.
  function resolveStateColor(token, foreground, accent, urgent, fallback) {
    var text = String(token || "").trim()
    switch (text.toLowerCase()) {
    case "foreground":
    case "text":
      return foreground || Commons.Color.foreground
    case "accent":
      return accent || Commons.Color.accent
    case "urgent":
      return urgent || Commons.Color.urgent
    case "background":
      return Commons.Color.background
    case "transparent":
      return Qt.rgba(0, 0, 0, 0)
    }
    return colorFromHex(text, fallback || foreground || Commons.Color.foreground)
  }

  // A state's colour for a control drawn in <foreground>, <accent> and
  // <urgent>. Where the state's token is neither a role nor a hex colour, it
  // is the control's foreground; for pressed and focus, hover-cursor's
  // colour, which focus also takes when its token is "hover", "hover-cursor"
  // or "inherit".
  function stateColor(state, foreground, accent, urgent) {
    var resolve = function(token, fallback) { return resolveStateColor(token, foreground, accent, urgent, fallback) }
    var own = foreground || Commons.Color.foreground
    switch (state) {
    case "hover-cursor":
      return resolve(hoverColorToken, own)
    case "selected":
      return resolve(selectedColorToken, own)
    case "selection":
      return resolve(selectionColorToken, own)
    case "pressed":
      return resolve(pressedColorToken, stateColor("hover-cursor", foreground, accent, urgent))
    case "focus":
      var hover = stateColor("hover-cursor", foreground, accent, urgent)
      if (["hover", "hover-cursor", "inherit"].indexOf(focusColorToken.trim().toLowerCase()) !== -1) return hover
      return resolve(focusColorToken, hover)
    }
    return resolve(normalColorToken, own)
  }

  function normalStateColor(foreground, accent, urgent) { return stateColor("normal", foreground, accent, urgent) }
  function hoverStateColor(foreground, accent, urgent) { return stateColor("hover-cursor", foreground, accent, urgent) }
  function selectedStateColor(foreground, accent, urgent) { return stateColor("selected", foreground, accent, urgent) }
  function pressedStateColor(foreground, accent, urgent) { return stateColor("pressed", foreground, accent, urgent) }
  function focusStateColor(foreground, accent, urgent) { return stateColor("focus", foreground, accent, urgent) }
  function selectionStateColor(foreground, accent, urgent) { return stateColor("selection", foreground, accent, urgent) }

  // The fills and borders of the states, each the state's colour at its alpha.
  function normalFillFor(foreground, accent, urgent) { return Util.alpha(stateColor("normal", foreground, accent, urgent), normalFillAlpha) }
  function hoverFillFor(foreground, accent, urgent) { return Util.alpha(stateColor("hover-cursor", foreground, accent, urgent), hoverFillAlpha) }
  function selectedFillFor(foreground, accent, urgent) { return Util.alpha(stateColor("selected", foreground, accent, urgent), selectedFillAlpha) }
  function pressedFillFor(foreground, accent, urgent) { return Util.alpha(stateColor("pressed", foreground, accent, urgent), pressedFillAlpha) }
  function focusFillFor(foreground, accent, urgent) { return Util.alpha(stateColor("focus", foreground, accent, urgent), focusFillAlpha) }
  function selectionFillFor(foreground, accent, urgent) { return Util.alpha(stateColor("selection", foreground, accent, urgent), selectionFillAlpha) }

  function normalBorderFor(foreground, accent, urgent) { return Util.alpha(stateColor("normal", foreground, accent, urgent), normalBorderAlpha) }
  function hoverBorderFor(foreground, accent, urgent) { return Util.alpha(stateColor("hover-cursor", foreground, accent, urgent), hoverBorderAlpha) }
  function selectedBorderFor(foreground, accent, urgent) { return Util.alpha(stateColor("selected", foreground, accent, urgent), selectedBorderAlpha) }
  function focusBorderFor(foreground, accent, urgent) { return Util.alpha(stateColor("focus", foreground, accent, urgent), focusBorderAlpha) }

  // A form control's fill, border and border width: focus first, then the
  // pointer or the panel's cursor, then at rest.
  function controlFill(focused, hot, foreground, accent) {
    return focused ? focusFillFor(foreground, accent) : hot ? hoverFillFor(foreground, accent) : normalFillFor(foreground, accent)
  }

  function controlBorder(focused, hot, foreground, accent) {
    return focused ? focusBorderFor(foreground, accent) : hot ? hoverBorderFor(foreground, accent) : normalBorderFor(foreground, accent)
  }

  function controlBorderWidth(focused, hot) {
    return focused ? focusBorderWidth : hot ? hoverBorderWidth : normalBorderWidth
  }

  // The states' colours for a control in the palette's own colours.
  readonly property color normalFill: normalFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
  readonly property color hoverFill: hoverFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
  readonly property color selectedFill: selectedFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
  readonly property color pressedFill: pressedFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
  readonly property color focusFillColor: focusFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
  readonly property color normalBorderColor: normalBorderFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
  readonly property color hoverBorderColor: hoverBorderFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
  readonly property color selectedBorderColor: selectedBorderFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
  readonly property color focusBorderColor: focusBorderFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)
  readonly property color selectedAccentFill: Util.alpha(Commons.Color.accent, selectedFillAlpha)
  readonly property color selectionFill: selectionFillFor(Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent)

  // ---------------------------------------------------------------- spacing
  //
  // A component asks for the pixels it was drawn with at the default scale,
  // space(px), and gets them scaled (spaceReal for fractions). Spacing tokens
  // can each be pinned in shell.toml, in pixels, unscaled.
  property real spacingScale: 1.0
  property bool spacingScaleWithFont: true
  property var spacingOverrides: ({})
  readonly property real effectiveSpacingScale: spacingScale * (spacingScaleWithFont ? fontScale : 1)

  function spaceReal(px) {
    var n = Number(px)
    return isFinite(n) && n > 0 ? n * effectiveSpacingScale : 0
  }

  // Never rounded down to nothing: what asks for space gets at least a pixel.
  function space(px) {
    var n = spaceReal(px)
    return n > 0 ? Math.max(1, Math.round(n)) : 0
  }

  function spacingToken(key, fallback) {
    var n = Number(spacingOverrides[key])
    return isFinite(n) && n >= 0 ? Math.round(n) : space(fallback)
  }

  readonly property QtObject spacing: QtObject {
    readonly property real scale: root.effectiveSpacingScale

    readonly property int hairline: root.space(1)
    readonly property int xxs: root.spacingToken("xxs", 2)
    readonly property int xs: root.spacingToken("xs", 3)
    readonly property int sm: root.spacingToken("sm", 4)
    readonly property int md: root.spacingToken("md", 6)
    readonly property int lg: root.spacingToken("lg", 8)
    readonly property int xl: root.spacingToken("xl", 10)
    readonly property int xxl: root.spacingToken("xxl", 12)
    readonly property int xxxl: root.spacingToken("xxxl", 14)
    readonly property int huge: root.spacingToken("huge", 18)

    readonly property int controlGap: root.spacingToken("control-gap", 8)
    readonly property int controlPaddingX: root.spacingToken("control-padding-x", 10)
    readonly property int controlPaddingY: root.spacingToken("control-padding-y", 6)
    readonly property int inputPaddingY: root.spacingToken("input-padding-y", 7)
    readonly property int controlHeight: root.spacingToken("control-height", 28)
    readonly property int popupRowHeight: root.spacingToken("popup-row-height", 28)
    readonly property int dropdownWidth: root.spacingToken("dropdown-width", 240)
    readonly property int searchableDropdownWidth: root.spacingToken("searchable-dropdown-width", 260)
    readonly property int numberFieldWidth: root.spacingToken("number-field-width", 120)
    readonly property int searchablePopupMinHeight: root.spacingToken("searchable-popup-min-height", 220)
    readonly property int rowGap: root.spacingToken("row-gap", 8)
    readonly property int rowPaddingX: root.spacingToken("row-padding-x", 12)
    readonly property int labelGap: root.spacingToken("label-gap", 4)
    readonly property int panelGap: root.spacingToken("panel-gap", 14)
    readonly property int panelPadding: root.spacingToken("panel-padding", 18)
    readonly property int popupPadding: root.spacingToken("popup-padding", 14)
  }

  // ------------------------------------------------------------- typography
  //
  // The family is "monospace", the fontconfig alias `nova font set` points at
  // the font chosen, so the shell follows it; a theme sets sizes, not the
  // family. resolvedFontFamily is the family that alias stands for now, to
  // show by name: bind font.family to fontFamily.
  property string fontFamily: "monospace"
  property string resolvedFontFamily: "monospace"

  // At least 1px; past that, as large as a theme or its user likes.
  property int fontBaseSize: 12

  property var fontOverrides: ({})
  property var barOverrides: ({})
  property bool barScaleWithFont: true
  readonly property real fontScale: Math.max(1 / 12, fontBaseSize / 12)

  function fontPx(mult) {
    return Math.max(1, Math.round(fontBaseSize * mult))
  }

  function fontToken(key, fallback) {
    var n = Number(fontOverrides[key])
    return isFinite(n) && n > 0 ? Math.round(n) : fallback
  }

  function barToken(key, fallback) {
    var n = Number(barOverrides[key])
    var size = isFinite(n) && n > 0 ? n : fallback
    return Math.max(1, Math.round(barScaleWithFont ? size * fontScale : size))
  }

  // true/1/yes/on, false/0/no/off, in any case; anything else is <fallback>.
  function boolToken(value, fallback) {
    if (value === undefined || value === null) return fallback
    var word = String(value).trim().toLowerCase()
    if (["true", "1", "yes", "on"].indexOf(word) !== -1) return true
    if (["false", "0", "no", "off"].indexOf(word) !== -1) return false
    return fallback
  }

  // NOVA_MENU_FONT, read at start, gives the summoned surfaces (the menu,
  // polkit, emojis, the clipboard) a family of their own.
  readonly property string menuFontFamily: Quickshell.env("NOVA_MENU_FONT") || fontFamily

  readonly property QtObject font: QtObject {
    readonly property string family: root.fontFamily
    readonly property string resolvedFamily: root.resolvedFontFamily
    readonly property string menuFamily: root.menuFontFamily
    readonly property int baseSize: root.fontBaseSize

    // The sizes at the default base of 12 are in the comments.
    readonly property int caption: root.fontToken("caption", root.fontPx(0.833)) // 10
    readonly property int bodySmall: root.fontToken("body-small", root.fontPx(0.917)) // 11
    readonly property int body: root.fontToken("body", root.fontPx(1.0)) // 12
    readonly property int subtitle: root.fontToken("subtitle", root.fontPx(1.083)) // 13
    readonly property int title: root.fontToken("title", root.fontPx(1.167)) // 14
    readonly property int heading: root.fontToken("heading", root.fontPx(1.333)) // 16
    readonly property int display: root.fontToken("display", root.fontPx(2.0)) // 24
    readonly property int displayLarge: root.fontToken("display-large", root.fontPx(2.333)) // 28

    readonly property int iconSmall: root.fontToken("icon-small", bodySmall)
    readonly property int icon: root.fontToken("icon", title)
    readonly property int iconLarge: root.fontToken("icon-large", root.fontPx(1.5)) // 18
  }

  readonly property QtObject bar: QtObject {
    readonly property int sizeHorizontal: root.barToken("size-horizontal", 26)
    readonly property int sizeVertical: root.barToken("size-vertical", 28)
    readonly property int iconSlot: root.barToken("icon-slot", 27)
    readonly property int iconCanvas: root.barToken("icon-canvas", 16)
    readonly property int iconFont: root.barToken("icon-font", 13)
    readonly property int statusSlot: root.barToken("status-slot", 21)
  }

  // Takes the [font], [bar], [spacing] and [controls] keys out of the
  // shell.toml values Color has read; Color calls it on every load. A key
  // that is not a number where one is wanted is left out.
  function applyShellValues(values) {
    var fontSizes = {}
    var barSizes = {}
    var controlKeys = {}
    var pinnedSpacing = {}
    var baseSize = 12
    var scale = 1.0
    var scaleWithFont = true
    var barWithFont = true
    var all = values || {}
    for (var name in all) {
      var dot = name.indexOf(".")
      if (dot < 0) continue
      var section = name.substr(0, dot)
      var key = name.substr(dot + 1)
      var raw = all[name]
      if (section === "font") {
        var px = parseInt(raw, 10)
        if (!isFinite(px)) continue
        if (key === "base-size") baseSize = px
        else fontSizes[key] = px
      } else if (section === "bar") {
        if (key === "scale-with-font") {
          barWithFont = boolToken(raw, barWithFont)
        } else if (key === "size-horizontal" || key === "size-vertical") {
          var size = parseInt(raw, 10)
          if (isFinite(size)) barSizes[key] = size
        }
      } else if (section === "spacing") {
        if (key === "scale-with-font") {
          scaleWithFont = boolToken(raw, scaleWithFont)
        } else {
          var amount = parseFloat(raw)
          if (!isFinite(amount)) continue
          if (key === "scale") scale = amount
          else pinnedSpacing[key] = amount
        }
      } else if (section === "controls" || section === "style") {
        // Kept as text: styleNum and styleString read it as they need.
        controlKeys[key] = raw
      }
    }
    spacingScale = scale < 0 ? 1.0 : scale
    spacingScaleWithFont = scaleWithFont
    fontBaseSize = Math.max(1, baseSize)
    fontOverrides = fontSizes
    barOverrides = barSizes
    barScaleWithFont = barWithFont
    spacingOverrides = pinnedSpacing
    styleOverrides = controlKeys
  }

  // ---------------------------------------------------------------- Hyprland

  function refresh() {
    hyprctlProc.running = true
    gapsOutProc.running = true
  }

  function scheduleRefresh() {
    refreshTimer.restart()
  }

  // Without Hyprland, or with an answer that is not one, what was there stays.
  function applyRoundingJson(raw) {
    try {
      var n = Number(JSON.parse(raw || "{}").int)
      if (isFinite(n) && n >= 0) cornerRadius = n
    } catch (e) {}
  }

  // gaps_out is CSS-style, "top right bottom left"; the top is the gap.
  function applyGapsOutJson(raw) {
    try {
      var option = JSON.parse(raw || "{}")
      var numbers = String(option.css || "").match(/-?\d+(?:\.\d+)?/g) || []
      var n = numbers.length > 0 ? Number(numbers[0]) : Number(option.int)
      if (isFinite(n) && n >= 0) gapsOut = Math.max(0, Math.round(n / 2))
    } catch (e) {}
  }

  property Process hyprctlProc: Process {
    command: ["hyprctl", "-j", "getoption", "decoration:rounding"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyRoundingJson(text)
    }
  }

  property Process gapsOutProc: Process {
    command: ["hyprctl", "-j", "getoption", "general:gaps_out"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyGapsOutJson(text)
    }
  }

  // Hyprland reloads its config by itself when a file it read changes, and a
  // moment later: asked at once, it still answers with the old value.
  property Timer refreshTimer: Timer {
    interval: 200
    repeat: false
    onTriggered: root.refresh()
  }

  // `nova toggle window-gaps` writes and removes this file, one Hyprland reads.
  property FileView windowNoGapsToggle: FileView {
    path: Commons.Color.stateHome + "/nova/toggles/hypr/window-no-gaps.lua"
    watchChanges: true
    printErrors: false
    onFileChanged: root.scheduleRefresh()
    onLoaded: root.scheduleRefresh()
    onLoadFailed: root.scheduleRefresh()
  }

  // ------------------------------------------------------------- fontconfig

  function resolveFontFamily() {
    fcMatchProc.running = true
  }

  property Process fcMatchProc: Process {
    command: ["fc-match", "-f", "%{family[0]}", "monospace"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var name = String(text || "").trim()
        if (name.length > 0) root.resolvedFontFamily = name
      }
    }
  }

  // `nova font set` rewrites this and restarts the shell; an edit by hand is
  // picked up too.
  property FileView fontconfigFile: FileView {
    path: Quickshell.env("HOME") + "/.config/fontconfig/fonts.conf"
    watchChanges: true
    printErrors: false
    onFileChanged: root.resolveFontFamily()
    onLoaded: root.resolveFontFamily()
    onLoadFailed: root.resolveFontFamily()
  }

  Component.onCompleted: {
    refresh()
    resolveFontFamily()
  }
}
