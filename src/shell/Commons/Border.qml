pragma Singleton
import QtQuick
import qs.Commons as Commons
import "BorderGeometry.js" as Geometry

// Borders as the theme describes them, handed out as specs:
// { color, widths: { top, right, bottom, left }, gradient: { colors, angle,
// enabled } }. BorderSurface draws one colour at one width with its
// Rectangle's own border, and anything more with a BorderOverlay.
//
// A surface's border is <token> in its shell.toml section: a colour, a
// gradient as Hyprland writes one ("<colour> <colour> ... <n>deg"), or the
// name of another key to take it from ("hyprland.active-border").
// <token>-alpha is its opacity; <token>-width a CSS-style list of widths,
// and <token>-width-top, -right, -bottom and -left one side each, the
// section's border-width keys standing in where a token has none. A
// <token>-gradient key, from older files, can still make a gradient of a
// border with one colour. A control's border comes from [controls] the same
// way, its keys named by its state.
QtObject {
  id: borders

  function noGradient() {
    return { colors: [], angle: 0, enabled: false }
  }

  function none() {
    return flat("transparent", 0)
  }

  // <color> as it is, all round at <width> (a width list).
  function flat(color, width) {
    return { color: color || "transparent", widths: Geometry.parseWidthSpec(width, 0), gradient: noGradient() }
  }

  // ---------------------------------------------------------------- reading

  // A colour at <opacity> times its own: a colour, a palette role
  // (foreground or text, accent, urgent, background, not muted),
  // "transparent", or a form Geometry reads. Anything else comes back as
  // its text.
  function tint(value, opacity) {
    var scale = opacity === undefined || opacity === null ? 1 : Util.clampAlpha(opacity)
    if (value && typeof value === "object" && value.r !== undefined)
      return Qt.rgba(value.r, value.g, value.b, (value.a === undefined ? 1 : value.a) * scale)
    var word = String(value || "").trim()
    var role = word.toLowerCase()
    if (role === "transparent") return "transparent"
    if (role !== "muted" && Commons.Color.roles.hasOwnProperty(role)) return tint(Commons.Color[Commons.Color.roles[role]], scale)
    return Geometry.canonicalColor(word, scale)
  }

  // A value's colours at <opacity> and the angle of its last "<n>deg",
  // <fallback> standing in when it names no colour; empty is no gradient.
  function gradient(value, fallback, opacity) {
    var words = String(value || "").trim().split(/\s+/).filter(function(word) { return word !== "" })
    var read = { colors: [], angle: 0, enabled: false }
    if (words.length === 0) return read
    words.forEach(function(word) {
      if (/^-?\d+(?:\.\d+)?deg$/.test(word)) read.angle = parseFloat(word)
      else read.colors.push(tint(word, opacity))
    })
    if (read.colors.length === 0) read.colors.push(tint(fallback, opacity))
    read.enabled = read.colors.length > 1
    return read
  }

  // A colour as a border value writes it. Qt writes a colour that is not
  // opaque as #aarrggbb, and a border value's eight digits are #rrggbbaa.
  function asValue(color) {
    var text = String(color || "")
    if (!color || typeof color !== "object" || color.r === undefined || !/^#[0-9A-Fa-f]{8}$/.test(text)) return text
    return "#" + text.slice(3) + text.slice(1, 3)
  }

  // The colour and gradient of a border value at <opacity>, <fallback>'s
  // where it is empty; one colour still takes a gradient from <olderGradient>.
  function paint(value, fallback, opacity, olderGradient) {
    var given = String(value || "").trim()
    var read = gradient(given || asValue(fallback), fallback, opacity)
    var spec = {
      color: read.colors.length > 0 ? read.colors[0] : tint(fallback, opacity),
      gradient: read.enabled ? read : noGradient()
    }
    if (!spec.gradient.enabled && String(olderGradient || "").trim() !== "") {
      var older = gradient(olderGradient, spec.color, opacity)
      if (older.enabled) spec.gradient = older
    }
    return spec
  }

  // A value that names another key ("hyprland.active-border") is that key's
  // value, followed until it names no key that is set, or one come round
  // again.
  function follow(value) {
    var text = String(value || "").trim()
    var seen = {}
    while (/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(text) && !seen[text]) {
      seen[text] = true
      var next = Commons.Color.shellValues[text]
      if (next === undefined || next === null || String(next) === "") break
      text = String(next).trim()
    }
    return text
  }

  // Widths from a list, a side then set by its own key where there is one.
  // <read>(suffix) is the value of the width key ending in <suffix>.
  function measure(read, fallbackWidth) {
    var widths = Geometry.parseWidthSpec(read(""), fallbackWidth)
    ;["top", "right", "bottom", "left"].forEach(function(side) {
      var own = read("-" + side)
      if (own !== undefined && own !== null && own !== "") widths[side] = Math.max(0, Number(own) || 0)
    })
    return widths
  }

  // ---------------------------------------------------------------- surfaces

  // The first of <keys> that <section> sets, or "".
  function sectionValue(section, keys) {
    for (var i = 0; i < keys.length; i++) {
      var found = Commons.Color.shellValues[section + "." + keys[i]]
      if (found !== undefined && found !== null && String(found) !== "") return found
    }
    return ""
  }

  function surfaceSpec(section, token, fallbackColor, fallbackWidth, alphaKey) {
    var own = token === "border" ? ["border"] : [token, "border"]
    var alpha = sectionValue(section, [alphaKey || token + "-alpha"])
    var opacity = alpha !== "" && isFinite(Number(alpha)) ? Util.clampAlpha(Number(alpha)) : 1.0
    var value = follow(sectionValue(section, [token]))
    var spec = paint(value, fallbackColor, opacity,
      sectionValue(section, own.map(function(name) { return name + "-gradient" })))
    // A border the section leaves unset is <fallbackColor>, the colour Color
    // gives it, which already has the section's alpha.
    if (value === "") spec.color = tint(asValue(fallbackColor), 1)
    spec.widths = measure(function(suffix) {
      return sectionValue(section, own.map(function(name) { return name + "-width" + suffix }))
    }, fallbackWidth)
    return spec
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

  // ---------------------------------------------------------------- controls
  //
  // A control's border in a state, normal, hover-cursor ("hover" and "hot"
  // too), focus or selected: <state>-border, <state>-border-gradient and
  // <state>-border-width with its sides in [controls], the colour, alpha and
  // width Style gives the state where they are not set. Any other state is
  // read by its own keys with normal's colour, alpha and width.

  function controlState(state) {
    return state === "hover" || state === "hot" ? "hover-cursor" : state || "normal"
  }

  // The state whose colour, alpha and width <name>'s border falls back on.
  function drawnAs(name) {
    return ["hover-cursor", "focus", "selected"].indexOf(name) >= 0 ? name : "normal"
  }

  function controlWidths(name) {
    return measure(function(suffix) { return Style.controls[name + "-border-width" + suffix] }, Style.states[drawnAs(name)].width)
  }

  function controlHasWidth(state) {
    return Geometry.maxWidth(controlWidths(controlState(state))) > 0
  }

  function controlSpec(state, foreground, accent, urgent) {
    var name = controlState(state)
    var drawn = drawnAs(name)
    var spec = paint(Style.controls[name + "-border"], Style.stateColor(drawn, foreground, accent, urgent),
      Style.states[drawn].border, Style.controls[name + "-border-gradient"])
    spec.widths = controlWidths(name)
    return spec
  }

  // ---------------------------------------------------------------- specs

  function needsOverlay(spec) {
    if (!spec || Geometry.maxWidth(spec.widths) <= 0) return false
    var w = spec.widths
    return !!(spec.gradient && spec.gradient.enabled) || !(w.top === w.right && w.top === w.bottom && w.top === w.left)
  }

  function canUseNative(spec) {
    return !!spec && Geometry.maxWidth(spec.widths) > 0 && !needsOverlay(spec)
  }

  function side(spec, name) { return spec && spec.widths ? spec.widths[name] : 0 }
  function top(spec) { return side(spec, "top") }
  function right(spec) { return side(spec, "right") }
  function bottom(spec) { return side(spec, "bottom") }
  function left(spec) { return side(spec, "left") }
  function uniformWidth(spec) { return side(spec, "top") }
  function color(spec) { return spec ? spec.color : "transparent" }
}
