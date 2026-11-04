pragma Singleton
import Quickshell
import QtQuick

// Nova's small helpers, for the shell and its plugins alike. None keeps
// state: what has state is Color, Style or a service.
QtObject {
  // ------------------------------------------------- numbers and colours

  // <amount> as an opacity, from 0 to 1; what is not a number is 0.
  function clampAlpha(amount) {
    const n = Number(amount)
    if (!isFinite(n)) return 0
    return n < 0 ? 0 : n > 1 ? 1 : n
  }

  // A list's cursor moved by <step> over <length> rows: an arrow (a step of
  // one) wraps round the ends, a page stops at them.
  function stepIndex(at, step, length) {
    if (Math.abs(step) !== 1) return Math.max(0, Math.min(length - 1, at + step))
    const moved = (at + step) % length
    return moved < 0 ? moved + length : moved
  }

  // A wheel's turn in whole steps of 120 units, and what is carried over to
  // the next. A mouse notch is one step however large the delta it sends; a
  // touchpad's small deltas add up, until it turns the other way, which
  // drops what was carried.
  function wheelSteps(carried, delta) {
    const notch = Math.max(-120, Math.min(120, delta))
    const sum = carried * notch < 0 ? notch : carried + notch
    const whole = Math.trunc(sum / 120)
    return { steps: whole, remainder: sum - 120 * whole }
  }

  // <colour>, a color or its name, at <opacity>; no colour is black.
  function alpha(colour, opacity) {
    let base = Qt.rgba(0, 0, 0, 1)
    if (typeof colour === "string" && colour) base = Qt.color(colour)
    else if (colour) base = colour
    return Qt.rgba(base.r, base.g, base.b, clampAlpha(opacity))
  }

  // ------------------------------------------------------- text and paths

  // A file:// URL for a path, each of its parts escaped, so that a space or
  // a "#" in a file's name reaches Image.source as part of the name.
  function fileUrl(path) {
    if (!path) return ""
    return "file://" + String(path).split("/").map(part => encodeURIComponent(part)).join("/")
  }

  // <text> quoted for bash: in single quotes, each quote in it closed,
  // escaped and opened again.
  function shellQuote(text) {
    return "'" + String(text || "").replace(/'/g, "'\\''") + "'"
  }

  // UTF-8 text sent in base64 (nova-theme's rows over IPC): the text, or ""
  // for anything else. Qt.atob given a string is deprecated and warns at
  // each call; given the characters' codes it answers with the bytes, which
  // decodeURIComponent reads as UTF-8 once each is written %XX, and refuses
  // when they are not.
  function decodeBase64(encoded) {
    const text = String(encoded || "")
    if (text === "") return ""
    try {
      const codes = []
      for (let i = 0; i < text.length; i++) codes.push(text.charCodeAt(i))
      const bytes = new Uint8Array(Qt.atob(codes))
      let escaped = ""
      for (let i = 0; i < bytes.length; i++) escaped += (bytes[i] < 16 ? "%0" : "%") + bytes[i].toString(16)
      return decodeURIComponent(escaped)
    } catch (e) {
      return ""
    }
  }

  // A status command's output, as Waybar's custom modules print it: its last
  // line as JSON ({ text, class, tooltip, ... }), else the whole of it as
  // { text }; no output is {}.
  function parseModuleJson(output) {
    const all = String(output || "").trim()
    if (all === "") return {}
    const lastLine = all.substring(all.lastIndexOf("\n") + 1)
    try {
      return JSON.parse(lastLine)
    } catch (e) {
      return { text: all }
    }
  }

  // ------------------------------------------------------ a search field

  // Whether <key> edits a search field's <filter> as Qt's line edits would:
  // Backspace takes a character (with Shift too), Ctrl+Backspace a word,
  // Ctrl+U the whole; Ctrl+Shift+U is left for typing a character by its
  // code. On an empty field nothing is an edit, so that a panel can give the
  // key a meaning of its own (Backspace for back, in the menu), and with Alt
  // or Super held neither is anything.
  function editsFilter(key, filter) {
    if (!filter || (key.modifiers & (Qt.AltModifier | Qt.MetaModifier))) return false
    if (key.key === Qt.Key_Backspace) return true
    return key.key === Qt.Key_U && key.modifiers === Qt.ControlModifier
  }

  // <filter> after an edit editsFilter said yes to.
  function editedFilter(key, filter) {
    if (key.key === Qt.Key_U) return ""
    if (!(key.modifiers & Qt.ControlModifier)) return filter.slice(0, -1)
    // The last word, and the blanks after it.
    return filter.replace(/\S*\s*$/, "")
  }

  // ------------------------------------------------------------ commands
  //
  // Both run bash as a login shell, for the session's PATH and environment,
  // which an app opened from the shell (satty, nautilus, xdg-open) needs,
  // and neither waits for it.

  // A command line, as bash parses it.
  function execDetached(commandLine) {
    Quickshell.execDetached(["bash", "-lc", commandLine])
  }

  // A command as its words, never parsed: bash's `exec "$@"` runs them as
  // they are, so that a name with $(...) or a quote in it stays a name. For
  // anything with outside data in it.
  function execArgv(words) {
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(words))
  }

  // ----------------------------------------------------------- shell.json

  // An object read from JSON: not null, not a list.
  function isPlainObject(value) {
    if (!value || typeof value !== "object") return false
    return !Array.isArray(value)
  }

  // The bar's layout from shell.json as its readers want it: its three
  // sections, each a list of { id, ...settings } copied out of the config,
  // so that changing one leaves the config alone. A bare id becomes { id };
  // an entry without an id is left out.
  function normalizeLayout(layout) {
    const sections = { left: [], center: [], right: [] }
    for (const name in sections) {
      const given = isPlainObject(layout) && Array.isArray(layout[name]) ? layout[name] : []
      for (let i = 0; i < given.length; i++) {
        const entry = given[i]
        if (typeof entry === "string") {
          sections[name].push({ id: entry })
        } else if (isPlainObject(entry) && entry.id) {
          const copy = JSON.parse(JSON.stringify(entry))
          copy.id = String(copy.id)
          sections[name].push(copy)
        }
      }
    }
    return sections
  }
}
