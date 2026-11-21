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

  // How much bigger than its usual size a window like Settings or the App
  // Center opens on a screen <width> x <height> pixels (its logical size, as
  // the shell sees it), with the interface scaled by <scale>. Up to a
  // 1600-wide screen, as a 1366x768 laptop or a 1920x1080 one at UI size 1.25,
  // it is 1: the size the window was made for. From there it grows to a
  // quarter more, reached at 2400 wide, so a 1920x1080 screen gets 10%, and
  // a 2400x1500 laptop (a 16" 4K one at 1.6) or a 2560x1440 monitor the
  // quarter. A screen is measured by the smaller of its width and its 16:9
  // height, so a 3440x1440 ultrawide counts as the 2560x1440 it is tall
  // enough for. A window's own room on the screen still caps it.
  function windowGrowth(width, height, scale) {
    const s = Number(scale) > 0 ? Number(scale) : 1
    const w = Number(width) / s
    const h = Number(height) * 16 / 9 / s
    if (!isFinite(w) || !isFinite(h)) return 1
    const reach = Math.min(w, h)
    return 1 + 0.25 * Math.max(0, Math.min(1, (reach - 1600) / 800))
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

  // <colour>'s relative luminance, 0 for black to 1 for white, as WCAG
  // reckons it from sRGB.
  function luminance(colour) {
    const c = typeof colour === "string" ? Qt.color(colour) : colour
    const lin = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
  }

  // How far apart two opaque colours read, from 1 (the same) to 21 (black on
  // white): WCAG's contrast ratio.
  function contrast(a, b) {
    const la = luminance(a), lb = luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }

  // <colour> quieter by <factor>, for text and marks that should recede: it
  // lets through 1/<factor> of what is behind it, so it goes toward the card
  // on a light theme as on a dark one. Qt.darker, which dims light text,
  // makes dark text darker still: on a light theme the quiet lines came out
  // the loudest.
  function faded(colour, factor) {
    let base = Qt.rgba(0, 0, 0, 1)
    if (typeof colour === "string" && colour) base = Qt.color(colour)
    else if (colour) base = colour
    return Qt.rgba(base.r, base.g, base.b, base.a / Math.max(1, Number(factor) || 1))
  }

  // ------------------------------------------------------------ set hours
  //
  // A switch that a schedule turns on and off at set hours every day: the
  // night light's, and do-not-disturb's.

  // A time of day, "22:00", as minutes into the day; <otherwise> for
  // anything else.
  function minutesOf(text, otherwise) {
    const time = /^([01]?\d|2[0-3]):([0-5]\d)$/.exec(String(text))
    return time ? Number(time[1]) * 60 + Number(time[2]) : otherwise
  }

  // The last turn, at or before <now> (ms), of a switch on every day from
  // <from> to <to>, in minutes into the day, on the clock of that day:
  // { on, since }, with the time of the turn. Null with the two the same,
  // which is no hours at all. The clock is read as it is at <now>, so a time
  // zone changed meanwhile moves the turns with it.
  function lastTurn(now, from, to) {
    if (from === to) return null
    const today = new Date(now)
    let last = null
    for (const back of [1, 0]) {
      for (const turn of [{ on: true, at: from }, { on: false, at: to }]) {
        const since = new Date(today.getFullYear(), today.getMonth(), today.getDate() - back, Math.floor(turn.at / 60), turn.at % 60).getTime()
        if (since <= now && (!last || since > last.since)) last = { on: turn.on, since: since }
      }
    }
    return last
  }

  // The time (ms) of the next turn after <now> of the same switch, on the
  // clock as it is at <now>: what a Timer is aimed at. Null with no hours.
  function nextTurn(now, from, to) {
    if (from === to) return null
    const today = new Date(now)
    let next = null
    for (const ahead of [0, 1]) {
      for (const at of [from, to]) {
        const time = new Date(today.getFullYear(), today.getMonth(), today.getDate() + ahead, Math.floor(at / 60), at % 60).getTime()
        if (time > now && (next === null || time < next)) next = time
      }
    }
    return next
  }

  // A Timer's interval to <time> (ms) from <now>, a second past it, so that
  // a timer that goes off a moment early, as a long one can, finds it come;
  // at least a second, and no more than a day (a Timer takes 24 days at
  // most, and the clock is looked at again then).
  function intervalTo(time, now) {
    return Math.max(1000, Math.min(86400000, time - now + 1000))
  }

  // A turn as a schedule keeps it once made: on or off, and the day it falls
  // on, "on 2026-11-16"; "" for none. By the day and not the minute, so that
  // a sunset that moves a few minutes, as its place is looked up again, is
  // still the turn made, and a switch by hand since still holds.
  function turnName(turn) {
    return turn ? (turn.on ? "on " : "off ") + Qt.formatDate(new Date(turn.since), "yyyy-MM-dd") : ""
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
  // Both run bash as a login shell, and neither waits for it. The shell's
  // environment is the session's already (uwsm read /etc/profile and
  // ~/.profile); the login shell adds what only bash's own login file
  // (~/.bash_profile) sets, as a terminal has it, for a command a user wrote
  // and the app it opens (satty, nautilus, xdg-open). The menu's guards, run
  // at every opening, do without it (MenuSource).

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

  // ------------------------------------------------------------ windows

  // Whether a window of the shell's own (Settings, the Calendar), told by its
  // title, is open on another workspace than the focused one, among
  // Hyprland's windows as Quickshell lists them (Hyprland.toplevels.values).
  // One whose workspace is not known counts as here, and with no focused
  // workspace to compare with, so does every one.
  function onAnotherWorkspace(toplevels, title, focusedId) {
    if (focusedId === undefined || focusedId === null) return false
    return Array.prototype.some.call(toplevels || [], function(toplevel) {
      if (!toplevel || toplevel.title !== title) return false
      const app = toplevel.wayland ? toplevel.wayland.appId : (toplevel.lastIpcObject || {})["class"]
      if (app !== "org.quickshell") return false
      return !!toplevel.workspace && toplevel.workspace.id !== focusedId
    })
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
  // an entry without an id, or switched off (`"off": true`, which keeps its
  // place for when it is switched on), is left out.
  function normalizeLayout(layout) {
    const sections = { left: [], center: [], right: [] }
    for (const name in sections) {
      const given = isPlainObject(layout) && Array.isArray(layout[name]) ? layout[name] : []
      for (let i = 0; i < given.length; i++) {
        const entry = given[i]
        if (typeof entry === "string") {
          sections[name].push({ id: entry })
        } else if (isPlainObject(entry) && entry.id && entry.off !== true) {
          const copy = JSON.parse(JSON.stringify(entry))
          copy.id = String(copy.id)
          sections[name].push(copy)
        }
      }
    }
    return sections
  }
}
