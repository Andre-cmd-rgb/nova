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

// The longest a dictation runs before it is transcribed anyway. Parakeet's
// time grows faster than the audio: on a P1 Gen 4i's CPU, 11 s of speech take
// 0.9 s and two minutes 12 s.
var maxSeconds = 120

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

// Parakeet's line, ready to paste: one line, single spaces, and a space after
// a finished sentence, so the next dictation does not run into it.
function clean(text) {
  var s = String(text || "").replace(/\s+/g, " ").replace(/^ +| +$/g, "")
  if (s === "") return ""
  return /[.!?…]$/.test(s) ? s + " " : s
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

// The last `count` levels, oldest first, with `next` added at the end.
function pushLevel(levels, next, count) {
  var out = (levels || []).slice(Math.max(0, (levels || []).length - count + 1))
  out.push(next)
  while (out.length < count) out.unshift(0)
  return out
}

// `dictation setup --progress` prints "progress <percent>", then "checking"
// while it compares the download with the model's SHA-256.
function progress(line) {
  var m = /^progress (\d{1,3})$/.exec(String(line || "").trim())
  return m ? Math.min(100, parseInt(m[1], 10)) : -1
}

// Seconds as the hands-free pill's clock: 0:07, 1:42.
function clock(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var rest = s % 60
  return Math.floor(s / 60) + ":" + (rest < 10 ? "0" : "") + rest
}
