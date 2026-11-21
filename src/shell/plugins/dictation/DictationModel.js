// Dictation's decisions, apart from the pill and the processes that carry
// them out, so tests/qml can check them against plain values.
//
// The phases: idle, listening, transcribing, done (the check before the pill
// goes), message (a line of text, then gone), offer (the model download
// asked for) and downloading.

// A press shorter than this is a tap, which leaves the microphone on until
// the next press, instead of stopping at the release. It is measured between
// two IPC calls, each a process of its own, so it allows for their jitter.
var tapMs = 350

// The longest a dictation runs before it is let go anyway: what is said is
// heard while it is said (nova-dictationd), a sentence at a time, and the
// end has only the last of them to hear.
var maxSeconds = 600

// What SUPER + D going down does in each phase. A press while listening
// always finishes, so a tap whose release reached the shell before its press
// (two processes racing) still ends at the next press.
function onPress(phase) {
  switch (phase) {
  case "listening": return "finish"
  case "offer": return "setup"
  case "transcribing":
  case "downloading": return "none"
  default: return "start"
  }
}

// What letting go does: a hold ends there, a tap keeps listening.
function onRelease(phase, handsFree, heldMs) {
  if (phase !== "listening" || handsFree) return "none"
  return heldMs < tapMs ? "hands-free" : "finish"
}

// A line from nova-dictationd (src/dictation/src/server.rs), as an object:
// { type: "listening" }, { type: "text", text }, { type: "error", error },
// and { type: "" } for a line that is none of those.
function answer(line) {
  var value
  try {
    value = JSON.parse(String(line || ""))
  } catch (e) {
    return { type: "" }
  }
  if (!value || typeof value !== "object") return { type: "" }
  if (value.type === "listening") return { type: "listening" }
  if (value.type === "text" && typeof value.text === "string") return { type: "text", text: value.text }
  if (value.type === "error" && typeof value.error === "string") return { type: "error", error: value.error }
  return { type: "" }
}

// The wave's height while it listens, 0 to 1: up with the voice at once,
// and down slowly as it stops.
function voice(previous, level) {
  return Math.max(Number(level) || 0, (Number(previous) || 0) * 0.88)
}

// A peak from PipeWire (linear, 0 to 1) as a bar's height, 0 to 1, on a
// decibel scale: speech fills the bar, and a room's hum hardly moves it.
var floorDb = -50
var ceilingDb = -8

function level(peak) {
  var p = Number(peak)
  if (!(p > 0)) return 0
  var db = 20 * Math.log(p) / Math.LN10
  return Math.max(0, Math.min(1, (db - floorDb) / (ceilingDb - floorDb)))
}

// `dictation setup --progress` prints "progress <percent>", then "checking"
// while it compares the download with the model's SHA-256.
function progress(line) {
  var m = /^progress (\d{1,3})$/.exec(String(line || "").trim())
  return m ? Math.min(100, parseInt(m[1], 10)) : -1
}
