// What the prompts card reads from a duty of nova-sessiond and writes back
// to it, one line of JSON at a time (src/session/daemon/src/prompt.rs):
//
//   duty   {"type":"ask","glyph":…,"title":…,"text":…,"code":…,
//           "fields":[{"id":…,"label":…,"secret":…,"value":…}],"accept":…}
//          {"type":"wrong","text":…}   {"type":"done"}
//   card   {"type":"answer","values":{"<id>":"…"}}   {"type":"cancel"}

.pragma library

// The glyph beside the question, by what it is about.
var glyphs = {
  drive: "\u{F02CA}",
  bluetooth: "\u{F00AF}",
  network: "\u{F05A9}",
  printer: "\u{F042A}"
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
  return {
    type: "ask",
    glyph: text(raw.glyph, 20),
    title: text(raw.title, 200),
    text: text(raw.text, 300),
    code: text(raw.code, 20),
    fields: fields,
    accept: text(raw.accept, 40)
  }
}

// The answer to an ask: what each field holds, by its id.
function answerLine(fields, texts) {
  var values = {}
  for (var i = 0; i < fields.length; i++) values[fields[i].id] = String(texts[i] || "")
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
