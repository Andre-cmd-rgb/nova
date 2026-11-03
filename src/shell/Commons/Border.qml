pragma Singleton
import QtQuick
import qs.Commons as Commons
import "BorderGeometry.js" as Geometry

// Borders as the theme describes them, handed out as specs: { color, widths,
// gradient }. BorderSurface draws a spec with Rectangle.border where it can
// (one colour, one width) and with BorderOverlay where it cannot.
//
// A surface's border comes from its shell.toml section: <token> is the colour
// or Hyprland-style gradient, or the name of another key ("hyprland.active-
// border") to take it from, <token>-alpha its opacity, and <token>-width a
// CSS-style width list with -top, -right, -bottom and -left to set one side.
// A token other than "border" falls back on the section's border-width keys.
// A control's border comes from [controls] the same way, per state.
QtObject {
  id: root

  function none() {
    return flat("transparent", 0)
  }

  function flat(color, width) {
    return {
      color: color || "transparent",
      widths: Geometry.parseWidthSpec(width, 0),
      gradient: { colors: [], angle: 0, enabled: false },
    }
  }

  // <section>.<key> from shell.toml, "" when it is not there.
  function value(section, key) {
    var found = Commons.Color.shellValues[section + "." + key]
    return found === undefined || found === null ? "" : found
  }

  // The first of <keys> the section sets.
  function valueOr(section, keys) {
    for (var i = 0; i < keys.length; i++) {
      var found = value(section, keys[i])
      if (String(found).length > 0) return found
    }
    return ""
  }

  // A value that names another key ("hyprland.active-border") is that key's
  // value, followed until it is not a name, names one that is not set, or
  // comes round again.
  function resolveValueRef(raw) {
    var current = String(raw || "").trim()
    var visited = {}
    while (/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(current) && !visited[current]) {
      visited[current] = true
      var next = Commons.Color.shellValues[current]
      if (next === undefined || next === null || String(next).length === 0) break
      current = String(next).trim()
    }
    return current
  }

  function alpha(section, key, fallback) {
    var raw = value(section, key)
    if (String(raw).length === 0) return fallback
    var n = Number(raw)
    return isFinite(n) ? Geometry.clampAlpha(n) : fallback
  }

  // A colour at <opacity> times its own alpha: a colour value, a palette role
  // (foreground or text, accent, urgent, background), "transparent", or any
  // form Geometry.canonicalColor reads. Anything else comes back as text.
  function cssColor(color, opacity) {
    var scale = opacity === undefined || opacity === null ? 1 : Geometry.clampAlpha(opacity)
    if (color && typeof color === "object" && color.r !== undefined)
      return Qt.rgba(color.r, color.g, color.b, (color.a === undefined ? 1 : color.a) * scale)

    var text = String(color || "").trim()
    switch (text.toLowerCase()) {
    case "foreground":
    case "text":
      return cssColor(Commons.Color.foreground, scale)
    case "accent":
      return cssColor(Commons.Color.accent, scale)
    case "urgent":
      return cssColor(Commons.Color.urgent, scale)
    case "background":
      return cssColor(Commons.Color.background, scale)
    case "transparent":
      return "transparent"
    }
    return Geometry.canonicalColor(text, scale)
  }

  // A border value, read as a gradient: the colours at <opacity>, the last
  // "<n>deg" its angle. With no colour in it, <fallbackColor>. Empty is no
  // gradient at all.
  function resolvedGradient(raw, fallbackColor, opacity) {
    var text = String(raw || "").trim()
    if (text.length === 0) return { colors: [], angle: 0, enabled: false }

    var colors = []
    var angle = 0
    text.split(/\s+/).forEach(function(part) {
      if (/^-?\d+(?:\.\d+)?deg$/.test(part)) angle = Number(part.replace(/deg$/, ""))
      else colors.push(cssColor(part, opacity))
    })
    if (colors.length === 0) colors.push(cssColor(fallbackColor, opacity))
    return { colors: colors, angle: angle, enabled: colors.length > 1 }
  }

  // Whether two colours, as values or text, are the same to the byte.
  function sameColor(a, b) {
    var first = typeof a === "string" ? Qt.color(a) : a
    var second = typeof b === "string" ? Qt.color(b) : b
    if (!first || !second || first.r === undefined || second.r === undefined) return String(a) === String(b)
    var bytes = function(c) {
      return [c.r, c.g, c.b, c.a === undefined ? 1 : c.a].map(function(channel) { return Math.round(channel * 255) }).join()
    }
    return bytes(first) === bytes(second)
  }

  // A control given a colour of its own draws a plain border in it; one left
  // at the theme's <defaultColor> draws the section's border.
  function localOrSurfaceSpec(section, token, localColor, defaultColor, fallbackWidth, alphaKey) {
    if (!sameColor(localColor, defaultColor)) return flat(localColor, fallbackWidth)
    return surfaceSpec(section, token, localColor, fallbackWidth, alphaKey)
  }

  // The keys a token's widths come from: its own, then the section's border's.
  function widthKeys(token, suffix) {
    var names = token === "border" ? ["border"] : [token, "border"]
    return names.map(function(name) { return name + "-width" + suffix })
  }

  function surfaceWidths(section, token, fallbackWidth) {
    return Geometry.withSideOverrides(
      Geometry.parseWidthSpec(valueOr(section, widthKeys(token, "")), fallbackWidth),
      valueOr(section, widthKeys(token, "-top")),
      valueOr(section, widthKeys(token, "-right")),
      valueOr(section, widthKeys(token, "-bottom")),
      valueOr(section, widthKeys(token, "-left")))
  }

  // A colour as a border value would write it. Qt writes a colour that is not
  // opaque as #aarrggbb, and a border value's eight digits are #rrggbbaa, so
  // the alpha moves to the end; text is left as it is.
  function colorText(color) {
    var text = String(color || "")
    if (!color || typeof color !== "object" || color.r === undefined || !/^#[0-9A-Fa-f]{8}$/.test(text)) return text
    return "#" + text.slice(3) + text.slice(1, 3)
  }

  // The colour and gradient of a border value, <fallbackColor> where it is
  // empty. A one-colour value can still take its gradient from
  // <legacyGradientRaw>, the separate *-gradient key of older configs.
  function borderValue(raw, fallbackColor, opacity, legacyGradientRaw) {
    var fallback = cssColor(fallbackColor, opacity)
    var given = String(raw || "").trim()
    var read = resolvedGradient(given.length > 0 ? given : colorText(fallbackColor), fallbackColor, opacity)
    var color = read.colors.length > 0 ? read.colors[0] : fallback
    var gradient = read.enabled ? read : { colors: [], angle: 0, enabled: false }

    if (!gradient.enabled && String(legacyGradientRaw || "").trim().length > 0) {
      var legacy = resolvedGradient(legacyGradientRaw, color, opacity)
      if (legacy.enabled) gradient = legacy
    }
    return { color: color, gradient: gradient }
  }

  function surfaceSpec(section, token, fallbackColor, fallbackWidth, alphaKey) {
    var opacity = alpha(section, alphaKey || token + "-alpha", 1.0)
    var legacyGradient = valueOr(section, token === "border" ? ["border-gradient"] : [token + "-gradient", "border-gradient"])
    var read = borderValue(resolveValueRef(value(section, token)), fallbackColor, opacity, legacyGradient)
    return { color: read.color, widths: surfaceWidths(section, token, fallbackWidth), gradient: read.gradient }
  }

  // ------------------------------------------------------------ controls
  //
  // A control's state is normal, hover-cursor (also "hover" and "hot"),
  // focus or selected; its keys in [controls] are <state>-border,
  // <state>-border-gradient and <state>-border-width with its sides, and
  // Style holds the colour, alpha and width each falls back on.

  function controlPrefix(state) {
    if (state === "hover" || state === "hot") return "hover-cursor"
    return state || "normal"
  }

  function controlColor(prefix, foreground, accent, urgent) {
    switch (prefix) {
    case "focus":
      return Style.focusStateColor(foreground, accent, urgent)
    case "hover-cursor":
      return Style.hoverStateColor(foreground, accent, urgent)
    case "selected":
      return Style.selectedStateColor(foreground, accent, urgent)
    }
    return Style.normalStateColor(foreground, accent, urgent)
  }

  function controlAlpha(prefix) {
    switch (prefix) {
    case "focus":
      return Style.focusBorderAlpha
    case "hover-cursor":
      return Style.hoverBorderAlpha
    case "selected":
      return Style.selectedBorderAlpha
    }
    return Style.normalBorderAlpha
  }

  function controlFallbackWidth(prefix) {
    switch (prefix) {
    case "focus":
      return Style.focusBorderWidth
    case "hover-cursor":
      return Style.hoverBorderWidth
    case "selected":
      return Style.selectedBorderWidth
    }
    return Style.normalBorderWidth
  }

  function controlWidths(state) {
    var prefix = controlPrefix(state)
    var keys = Style.styleOverrides
    var key = prefix + "-border-width"
    return Geometry.withSideOverrides(
      Geometry.parseWidthSpec(keys[key], controlFallbackWidth(prefix)),
      keys[key + "-top"], keys[key + "-right"], keys[key + "-bottom"], keys[key + "-left"])
  }

  function controlHasWidth(state) {
    return Geometry.maxWidth(controlWidths(state)) > 0
  }

  function controlSpec(state, foreground, accent, urgent) {
    var prefix = controlPrefix(state)
    var read = borderValue(Style.styleOverrides[prefix + "-border"], controlColor(prefix, foreground, accent, urgent),
      controlAlpha(prefix), Style.styleOverrides[prefix + "-border-gradient"])
    return { color: read.color, widths: controlWidths(prefix), gradient: read.gradient }
  }

  // ------------------------------------------------------------ reading specs

  function needsOverlay(spec) { return Geometry.needsOverlay(spec) }
  function canUseNative(spec) { return Geometry.canUseNative(spec) }
  function top(spec) { return spec && spec.widths ? spec.widths.top : 0 }
  function right(spec) { return spec && spec.widths ? spec.widths.right : 0 }
  function bottom(spec) { return spec && spec.widths ? spec.widths.bottom : 0 }
  function left(spec) { return spec && spec.widths ? spec.widths.left : 0 }
  function uniformWidth(spec) { return top(spec) }
  function color(spec) { return spec ? spec.color : "transparent" }
}
