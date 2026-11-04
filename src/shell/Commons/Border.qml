pragma Singleton
import QtQuick
import qs.Commons as Commons
import "ColorText.js" as ColorText
import "Ring.js" as Ring

// Borders as the theme describes them, handed out as specs:
// { color, widths: { top, right, bottom, left }, gradient: { colors, angle,
// enabled } }. BorderSurface draws one colour at one width all round with
// its Rectangle's own border, and anything more as a ring over it.
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

  // ---------------------------------------------------------------- specs

  function _noGradient() {
    return { colors: [], angle: 0, enabled: false }
  }

  // <color> as it is, all round at <width> (a width list).
  function flat(color, width) {
    return { color: color || "transparent", widths: Ring.sides(width, 0), gradient: _noGradient() }
  }

  // No border at all.
  function none() {
    return flat(null, 0)
  }

  function _side(spec, name) {
    return spec && spec.widths ? spec.widths[name] : 0
  }

  function top(spec) { return _side(spec, "top") }
  function right(spec) { return _side(spec, "right") }
  function bottom(spec) { return _side(spec, "bottom") }
  function left(spec) { return _side(spec, "left") }

  function color(spec) {
    return spec ? spec.color : "transparent"
  }

  // What draws <spec>: "rectangle" for one colour at one width all round,
  // "ring" for a gradient or sides of different widths, and "" for no
  // width at all.
  function drawnBy(spec) {
    if (!spec || Ring.widest(spec.widths) <= 0) return ""
    const w = spec.widths
    const even = w.top === w.right && w.top === w.bottom && w.top === w.left
    return (spec.gradient && spec.gradient.enabled) || !even ? "ring" : "rectangle"
  }

  // ---------------------------------------------------------------- reading

  // A colour at <opacity> times its own: a colour, a palette role
  // (foreground or text, accent, urgent, background, not muted),
  // "transparent", or a form ColorText reads. Anything else comes back as
  // its text.
  function _tint(value, opacity) {
    const scale = opacity == null ? 1 : Util.clampAlpha(opacity)
    if (value && typeof value === "object" && value.r !== undefined)
      return Qt.rgba(value.r, value.g, value.b, (value.a === undefined ? 1 : value.a) * scale)
    const word = String(value || "").trim()
    const role = word.toLowerCase()
    if (role === "transparent") return "transparent"
    const roles = Commons.Color.roles
    if (role !== "muted" && roles.hasOwnProperty(role)) return _tint(Commons.Color[roles[role]], scale)
    return ColorText.read(word, scale)
  }

  // A value's colours at <opacity> and the angle of its last "<n>deg",
  // <fallback> standing in when it names no colour; empty is no gradient.
  function _gradient(value, fallback, opacity) {
    const read = _noGradient()
    const words = String(value || "").trim().split(/\s+/).filter(word => word !== "")
    if (words.length === 0) return read
    for (const word of words) {
      if (ColorText.isAngle(word)) read.angle = parseFloat(word)
      else read.colors.push(_tint(word, opacity))
    }
    if (read.colors.length === 0) read.colors.push(_tint(fallback, opacity))
    read.enabled = read.colors.length > 1
    return read
  }

  // A colour as a border value writes it. Qt writes a colour that is not
  // opaque as #aarrggbb, and a border value's eight digits are #rrggbbaa.
  function _asValue(color) {
    const text = String(color || "")
    if (!color || typeof color !== "object" || color.r === undefined || !/^#[0-9A-Fa-f]{8}$/.test(text)) return text
    return "#" + text.slice(3) + text.slice(1, 3)
  }

  // The colour and gradient of a border value at <opacity>, <fallback>'s
  // where it is empty; one colour still takes a gradient from <olderGradient>.
  function _paint(value, fallback, opacity, olderGradient) {
    const given = String(value || "").trim()
    const read = _gradient(given || _asValue(fallback), fallback, opacity)
    const spec = {
      color: read.colors.length > 0 ? read.colors[0] : _tint(fallback, opacity),
      gradient: read.enabled ? read : _noGradient()
    }
    if (!spec.gradient.enabled && String(olderGradient || "").trim() !== "") {
      const older = _gradient(olderGradient, spec.color, opacity)
      if (older.enabled) spec.gradient = older
    }
    return spec
  }

  // A value that names another key ("hyprland.active-border") is that key's
  // value, followed until it names no key that is set, or one come round
  // again.
  function _follow(value) {
    let text = String(value || "").trim()
    const seen = {}
    while (/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(text) && !seen[text]) {
      seen[text] = true
      const next = Commons.Color.shellValues[text]
      if (next === undefined || next === null || String(next) === "") break
      text = String(next).trim()
    }
    return text
  }

  // Widths from a list, each side then set by its own key where it has
  // one. <widthKey>(suffix) is the value of the width key ending in
  // <suffix>.
  function _widths(widthKey, fallbackWidth) {
    const widths = Ring.sides(widthKey(""), fallbackWidth)
    for (const side of ["top", "right", "bottom", "left"]) {
      const own = widthKey("-" + side)
      if (own !== undefined && own !== null && own !== "") widths[side] = Math.max(0, Number(own) || 0)
    }
    return widths
  }

  // ---------------------------------------------------------------- surfaces

  // A reader of <section>: the value of the first of the keys it is given
  // that the section sets, or "".
  function _section(section) {
    return function(keys) {
      for (const key of keys) {
        const found = Commons.Color.shellValues[section + "." + key]
        if (found !== undefined && found !== null && String(found) !== "") return found
      }
      return ""
    }
  }

  function surfaceSpec(section, token, fallbackColor, fallbackWidth, alphaKey) {
    const read = _section(section)
    // A token's own keys first, then the section's border keys.
    const names = token === "border" ? ["border"] : [token, "border"]
    const alpha = read([alphaKey || token + "-alpha"])
    const opacity = alpha !== "" && isFinite(Number(alpha)) ? Util.clampAlpha(Number(alpha)) : 1.0
    const value = _follow(read([token]))
    const spec = _paint(value, fallbackColor, opacity, read(names.map(name => name + "-gradient")))
    // A border the section leaves unset is <fallbackColor>, the colour Color
    // gives it, which already has the section's alpha.
    if (value === "") spec.color = _tint(_asValue(fallbackColor), 1)
    spec.widths = _widths(suffix => read(names.map(name => name + "-width" + suffix)), fallbackWidth)
    return spec
  }

  // Whether two colours, as values or text, are the same to the byte.
  function _sameColor(a, b) {
    const first = typeof a === "string" ? Qt.color(a) : a
    const second = typeof b === "string" ? Qt.color(b) : b
    if (!first || !second || first.r === undefined || second.r === undefined) return String(a) === String(b)
    const bytes = c => [c.r, c.g, c.b, c.a === undefined ? 1 : c.a].map(channel => Math.round(channel * 255)).join()
    return bytes(first) === bytes(second)
  }

  // A popup's border: the [popups] one while <color> is the theme's popup
  // border colour, and a plain one in <color> when the popup is given a
  // colour of its own.
  function popupSpec(color, width) {
    if (!_sameColor(color, Commons.Color.popups.border)) return flat(color, width)
    return surfaceSpec("popups", "border", color, width)
  }

  // ---------------------------------------------------------------- controls
  //
  // A control's border in a state, normal, hover-cursor ("hover" and "hot"
  // too), focus or selected: <state>-border, <state>-border-gradient and
  // <state>-border-width with its sides in [controls], the colour, alpha and
  // width Style gives the state where they are not set. Any other state is
  // read by its own keys with normal's colour, alpha and width.

  function _controlState(state) {
    return state === "hover" || state === "hot" ? "hover-cursor" : state || "normal"
  }

  // The state whose colour, alpha and width <name>'s border falls back on.
  function _drawnAs(name) {
    return ["hover-cursor", "focus", "selected"].indexOf(name) >= 0 ? name : "normal"
  }

  function controlWidths(name) {
    return _widths(suffix => Style.controls[name + "-border-width" + suffix], Style.states[_drawnAs(name)].width)
  }

  function controlHasWidth(state) {
    return Ring.widest(controlWidths(_controlState(state))) > 0
  }

  function controlSpec(state, foreground, accent) {
    const name = _controlState(state)
    const drawn = _drawnAs(name)
    const spec = _paint(Style.controls[name + "-border"], Style.stateColor(drawn, foreground, accent),
      Style.states[drawn].border, Style.controls[name + "-border-gradient"])
    spec.widths = controlWidths(name)
    return spec
  }
}
