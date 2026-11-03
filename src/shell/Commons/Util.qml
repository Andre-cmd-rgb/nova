pragma Singleton
import Quickshell
import QtQuick

// Small helpers the plugins share. They keep no state: what has state is
// Color, Style or a service.
QtObject {
  // ---------------------------------------------------------------- numbers

  // <value> as an opacity, 0 to 1; anything that is not a number is 0.
  function clampAlpha(value) {
    var n = Number(value)
    return isFinite(n) ? Math.min(1, Math.max(0, n)) : 0
  }

  // A list's cursor moved by <delta>: an arrow (one) wraps round, a page
  // stops at the ends.
  function stepIndex(index, delta, count) {
    if (Math.abs(delta) === 1) return ((index + delta) % count + count) % count
    return Math.max(0, Math.min(count - 1, index + delta))
  }

  // Whole steps of a wheel, 120 units each, and what is left over. A mouse
  // notch is one step however large the delta it sends; a touchpad's small
  // deltas add up, until it turns round, which starts again from nothing.
  function wheelSteps(accumulator, delta) {
    var step = Math.max(-120, Math.min(120, delta))
    var total = step + (accumulator * step < 0 ? 0 : accumulator)
    var steps = Math.trunc(total / 120)
    return { steps: steps, remainder: total - steps * 120 }
  }

  // <c>, a colour or its text, at <opacity>; no colour is transparent black.
  function alpha(c, opacity) {
    var base = !c ? Qt.rgba(0, 0, 0, 1) : typeof c === "string" ? Qt.color(c) : c
    return Qt.rgba(base.r, base.g, base.b, clampAlpha(opacity))
  }

  // ---------------------------------------------------------------- text

  // A file:// URL for a path, each part of it escaped, so a space or a "#"
  // in a file's name reaches Image.source as part of the name.
  function fileUrl(path) {
    return path ? "file://" + String(path).replace(/[^\/]+/g, encodeURIComponent) : ""
  }

  // <value> in single quotes for bash, a quote in it closed, escaped and
  // opened again.
  function shellQuote(value) {
    return "'" + String(value || "").split("'").join("'\\''") + "'"
  }

  // "%00" to "%ff", for decodeBase64.
  readonly property var percentBytes: {
    var table = []
    for (var i = 0; i < 256; i++) table.push("%" + (i < 16 ? "0" : "") + i.toString(16))
    return table
  }

  // Base64 of UTF-8 text, decoded; "" for anything that is not. Qt.atob
  // given a string is deprecated and warns at every call; given the
  // characters' codes it answers with bytes, which decodeURIComponent reads as
  // UTF-8 once each is escaped.
  function decodeBase64(value) {
    var text = String(value || "")
    if (!text) return ""
    try {
      var codes = Array.prototype.map.call(text, function(ch) { return ch.charCodeAt(0) })
      var bytes = new Uint8Array(Qt.atob(codes))
      return decodeURIComponent(Array.prototype.map.call(bytes, function(b) { return percentBytes[b] }).join(""))
    } catch (e) {
      return ""
    }
  }

  // A status command's output, as Waybar's custom modules print it: the last
  // line as JSON ({ text, class, tooltip, ... }), or all of it as { text }
  // when that is not JSON; nothing is {}.
  function parseModuleJson(raw) {
    var text = String(raw || "").trim()
    if (!text) return {}
    try {
      return JSON.parse(text.slice(text.lastIndexOf("\n") + 1))
    } catch (e) {
      return { text: text }
    }
  }

  // Whether a key edits a search field's text, as Qt's line edits would:
  // Backspace a character (with Shift too), Ctrl+Backspace a word, Ctrl+U
  // all of it; Ctrl+Shift+U is left for typing a character by its code. A key
  // that would change nothing, on an empty field, is not an edit, so the
  // panel can give it its own meaning (Backspace for back, in the menu), and
  // neither is anything with Alt or Super held.
  function editsFilter(event, text) {
    if (!text || (event.modifiers & (Qt.AltModifier | Qt.MetaModifier))) return false
    return event.key === Qt.Key_U ? event.modifiers === Qt.ControlModifier : event.key === Qt.Key_Backspace
  }

  // The text after an edit editsFilter has said yes to.
  function editedFilter(event, text) {
    if (event.key === Qt.Key_U) return ""
    return event.modifiers & Qt.ControlModifier ? text.replace(/\S*\s*$/, "") : text.slice(0, -1)
  }

  // ---------------------------------------------------------------- commands

  // A bash command line, in a login shell, not waited for.
  function execDetached(command) {
    Quickshell.execDetached(["bash", "-lc", command])
  }

  // A command as its words, never parsed by a shell: bash's `exec "$@"` runs
  // them as they are, so a name with $(...) or a quote in it stays a name.
  // The login shell is for the session's PATH and environment, which an app
  // opened this way (satty, nautilus, xdg-open) needs. Use this for anything
  // with outside data in it.
  function execArgv(argv) {
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(argv))
  }

  // ---------------------------------------------------------------- data

  function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
  }

  function cloneJson(value) {
    return JSON.parse(JSON.stringify(value === undefined ? null : value))
  }

  // The bar's layout from shell.json, in a form its readers can trust: three
  // lists of { id, ...settings }, each a copy, so changing one does not
  // change the config. An entry may be a bare id; one with no id is dropped.
  function normalizeLayout(layout) {
    var given = isPlainObject(layout) ? layout : {}
    var tidy = {}
    ;["left", "center", "right"].forEach(function(part) {
      tidy[part] = (Array.isArray(given[part]) ? given[part] : []).reduce(function(entries, entry) {
        if (typeof entry === "string") {
          entries.push({ id: entry })
        } else if (isPlainObject(entry) && entry.id) {
          var copy = cloneJson(entry)
          copy.id = String(copy.id)
          entries.push(copy)
        }
        return entries
      }, [])
    })
    return tidy
  }
}
