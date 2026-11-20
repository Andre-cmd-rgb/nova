// What the prompts card reads from a duty of nova-sessiond and writes back
// to it, one line of JSON at a time (src/session/daemon/src/prompt.rs):
//
//   duty   {"type":"ask","glyph":…,"title":…,"text":…,"code":…,
//           "fields":[{"id":…,"label":…,"secret":…,"value":…}],"accept":…,
//           "cancel":…, "alone":…,
//           "choices":[{"id":…,"label":…,"detail":…,"glyph":…,"section":…}],
//           "chosen":…, "toggles":[{"id":…,"label":…,"value":…}]}
//          {"type":"wrong","text":…}   {"type":"done"}
//   card   {"type":"answer","values":{"<id>":"…"}}   {"type":"cancel"}
//
// All but type are optional. <cancel> is the Cancel answer's words; <alone>
// leaves the duty's answer alone on the card (a message, which Escape
// answers too). A choice's id is the answer's "choice"; a toggle's is
// "true" or "false" under its id.

.pragma library

// The glyph beside the question, by what it is about.
var glyphs = {
  drive: "\u{F02CA}",
  bluetooth: "\u{F00AF}",
  network: "\u{F05A9}",
  printer: "\u{F042A}",
  keyring: "\u{F0306}",
  key: "\u{F030B}",
  share: "\u{F0E55}",
  monitor: "\u{F0379}",
  window: "\u{F05B2}",
  region: "\u{F0A35}"
}

function glyph(name) {
  return glyphs[name] || "\u{F023}"
}

function text(value, longest) {
  return typeof value === "string" ? value.slice(0, longest) : ""
}

// A line from a duty as { type, ... }, with only what the card uses, of the
// kinds it knows; null for anything else. An ask has at most three fields,
// each with an id of its own; one with none and no <accept> only waits, with
// Cancel (a code typed on the other device).
function parse(line) {
  var raw
  try {
    raw = JSON.parse(String(line || ""))
  } catch (e) {
    return null
  }
  if (!raw || typeof raw !== "object") return null
  if (raw.type === "done") return { type: "done" }
  if (raw.type === "wrong") return { type: "wrong", text: text(raw.text, 300) }
  if (raw.type !== "ask") return null
  var fields = []
  var seen = {}
  var list = Array.isArray(raw.fields) ? raw.fields : []
  for (var i = 0; i < list.length && fields.length < 3; i++) {
    var f = list[i]
    if (!f || typeof f.id !== "string" || f.id === "" || seen[f.id]) continue
    seen[f.id] = true
    fields.push({ id: f.id, label: text(f.label, 80), secret: f.secret === true, value: text(f.value, 300) })
  }
  var choices = []
  var picked = {}
  var offered = Array.isArray(raw.choices) ? raw.choices : []
  for (var j = 0; j < offered.length && choices.length < 64; j++) {
    var c = offered[j]
    if (!c || typeof c.id !== "string" || c.id === "" || picked[c.id]) continue
    picked[c.id] = true
    choices.push({ id: c.id, label: text(c.label, 120), detail: text(c.detail, 120), glyph: text(c.glyph, 20), section: text(c.section, 40) })
  }
  var chosen = text(raw.chosen, 300)
  if (!picked[chosen]) chosen = choices.length > 0 ? choices[0].id : ""
  var toggles = []
  var switched = {}
  var asked = Array.isArray(raw.toggles) ? raw.toggles : []
  for (var k = 0; k < asked.length && toggles.length < 2; k++) {
    var t = asked[k]
    if (!t || typeof t.id !== "string" || t.id === "" || t.id === "choice" || switched[t.id] || seen[t.id]) continue
    switched[t.id] = true
    toggles.push({ id: t.id, label: text(t.label, 120), value: t.value === true })
  }
  return {
    type: "ask",
    glyph: text(raw.glyph, 20),
    title: text(raw.title, 200),
    text: text(raw.text, 300),
    code: text(raw.code, 20),
    fields: fields,
    accept: text(raw.accept, 40),
    cancel: text(raw.cancel, 40) || "Cancel",
    alone: raw.alone === true && text(raw.accept, 40) !== "",
    choices: choices,
    chosen: chosen,
    toggles: toggles
  }
}

// The answer to an ask: what each field holds, by its id; the choice made,
// as "choice"; each toggle, "true" or "false", by its id.
function answerLine(fields, texts, choice, toggles, states) {
  var values = {}
  for (var i = 0; i < fields.length; i++) values[fields[i].id] = String(texts[i] || "")
  if (choice) values.choice = String(choice)
  var all = toggles || []
  for (var j = 0; j < all.length; j++) values[all[j].id] = states && states[j] ? "true" : "false"
  return JSON.stringify({ type: "answer", values: values }) + "\n"
}

function cancelLine() {
  return JSON.stringify({ type: "cancel" }) + "\n"
}

// Whether the card can be answered now: every field filled in, or no field
// at all (a yes or no).
function answerable(fields, texts) {
  for (var i = 0; i < fields.length; i++)
    if (String(texts[i] || "") === "") return false
  return true
}
