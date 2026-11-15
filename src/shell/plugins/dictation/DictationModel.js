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
// time grows faster than the audio (on a P1 Gen 4i's CPU 11 s of speech take
// 0.9 s and two minutes 12 s), but what is said is heard while it is said,
// a sentence at a time, and the end has only the last of them to hear.
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

// Parakeet's line, ready to paste: without its fillers and stutters
// (tidy), one line, single spaces, and a space after a finished sentence, so
// the next dictation does not run into it.
function clean(text) {
  var s = tidy(String(text || "").replace(/\s+/g, " ").replace(/^ +| +$/g, ""))
  if (s === "") return ""
  return /[.!?…]$/.test(s) ? s + " " : s
}

// ---- Fillers and stutters

// Sounds made while thinking, in English and Italian, which Parakeet writes
// down as words. "Eh?" is a question, and stays.
var FILLERS = ["uh", "uhh", "uhm", "um", "umm", "hm", "hmm", "mm", "mmm", "er", "erm", "eh", "ehm", "ehmm"]

// Words said twice on purpose ("had had", "no no", "very very"), which a
// stutter's doubled word is not.
var DOUBLES = ["that", "had", "is", "do", "very", "really", "so", "no", "yes", "bye", "oh", "ha", "haha",
  "well", "now", "ok", "okay", "go", "more", "many", "much", "please", "ah", "si", "sì", "molto",
  "piano", "pian", "ciao", "bene", "va", "tanto", "troppo", "mai", "dai"]

// The marks a word can carry before or after it.
var MARKS = /^[.,!?;:…"“”'‘’«»()\[\]¿¡-]+|[.,!?;:…"“”'‘’«»()\[\]¿¡-]+$/g

// A word as compared: lower case, without the marks around it.
function bare(word) {
  return String(word).toLowerCase().replace(MARKS, "")
}

function cased(c) {
  return c.toUpperCase() !== c.toLowerCase()
}

function upper(c) {
  return cased(c) && c === c.toUpperCase()
}

// <word> with its first letter a capital, after any mark before it.
function capital(word) {
  for (var i = 0; i < word.length; i++) {
    if (cased(word.charAt(i))) return word.slice(0, i) + word.charAt(i).toUpperCase() + word.slice(i + 1)
  }
  return word
}

// <text> without "uh" and "um", and with a stuttered word ("at at six", "I,
// I think") said once. A filler takes its comma with it, and the comma before
// it ("went, uh, home" is "went home"); one that began a sentence passes its
// capital on, and one that ended it its full stop.
function tidy(text) {
  var words = String(text || "").split(" ").filter(function (w) { return w !== "" })
  var out = []
  var startsSentence = true
  for (var i = 0; i < words.length; i++) {
    var word = words[i]
    var plain = bare(word)
    var end = /[.!?]$/.test(word)
    if (FILLERS.indexOf(plain) >= 0 && !(plain === "eh" && /\?$/.test(word))) {
      var last = out.length - 1
      if (end && last >= 0 && !/[.!?]$/.test(out[last])) out[last] = out[last].replace(/[,;:]$/, "") + word.slice(-1)
      else if (/,$/.test(word) && last >= 0 && /,$/.test(out[last])) out[last] = out[last].slice(0, -1)
      if (end) startsSentence = true
      continue
    }
    var previous = out.length > 0 ? out[out.length - 1] : ""
    if (previous !== "" && plain !== "" && bare(previous) === plain && /^[^.!?;:]*,?$/.test(previous)
        && DOUBLES.indexOf(plain) < 0 && !/^[0-9]+$/.test(plain)) {
      // The first of the two goes, with the capital it had.
      out[out.length - 1] = upper(previous.charAt(0)) ? capital(word) : word
    } else {
      out.push(startsSentence ? capital(word) : word)
    }
    startsSentence = /[.!?]$/.test(word)
  }
  return out.join(" ")
}

// ---- Hearing it while it is said

// While it listens, the shell has the recording so far looked at every few
// seconds (`dictation transcribe <recording> <from>`), from where the text
// not yet settled starts. A look's answer, as an object:
//   end      seconds of recording it heard
//   pieces   [{ at, kind, text }]: parts that end at a sentence's end (kind
//            "sentence") or at a comma ("soft"), with words heard after
//            them; <at> is the second the recording can be cut at after it
//   rest     what follows the last piece
//   whole    whether the answer was all there, from its first line to its last
function parseLook(output) {
  var look = { end: 0, pieces: [], rest: "", whole: false }
  var ended = false
  String(output || "").split("\n").forEach(function (line) {
    var m = /^end (\d+(?:\.\d+)?)$/.exec(line)
    if (m) { look.end = parseFloat(m[1]); ended = true }
    else if ((m = /^piece (\d+(?:\.\d+)?) (sentence|soft) (.+)$/.exec(line)))
      look.pieces.push({ at: parseFloat(m[1]), kind: m[2], text: m[3] })
    else if ((m = /^rest ?(.*)$/.exec(line))) { look.rest = m[1]; look.whole = ended }
  })
  return look
}

// Whether a look's answer is of use to <heard>: all there (a look cut short
// or failed says nothing of what was said), and newer than what was heard.
function useful(heard, look) {
  return look.whole && look.end > heard.from && look.end >= heard.until
}

// A look's words, all of them.
function lookText(look) {
  return look.pieces.map(function (p) { return p.text }).concat([look.rest])
    .filter(function (t) { return t !== "" }).join(" ")
}

// A full stop after these is not a sentence's end.
var ABBREVIATIONS = ["dr", "mr", "mrs", "ms", "st", "prof", "jr", "sr", "vs", "etc", "sig", "dott", "ing", "avv", "geom", "rag"]

function sentenceEnd(piece) {
  if (piece.kind !== "sentence") return false
  var words = piece.text.split(" ")
  var last = words[words.length - 1]
  return !(/\.$/.test(last) && ABBREVIATIONS.indexOf(bare(last)) >= 0)
}

// How long the part not yet settled grows before a comma will do as well as
// a sentence's end: a long sentence is cut at a comma rather than heard
// whole at the end.
var softAfter = 25

// <heard> is what has been heard: { text, from, last, tail, until }, the
// settled text, the second of the recording where it ends, the previous look
// from there, and the newest look's words after it and the second it heard
// up to. A look from <heard>.from settles the pieces it and the look before
// it agree on, word for word, up to the last one that ends a sentence (or,
// once the part is softAfter long, at a comma). Words heard after an end are
// what make it one: a pause to think, with the sentence going on after it,
// is heard with what follows, and gets no full stop.
function settle(heard, look) {
  var before = heard.last
  var agreed = 0
  while (before && agreed < look.pieces.length && agreed < before.pieces.length
         && look.pieces[agreed].text === before.pieces[agreed].text)
    agreed++
  var long = look.end - heard.from >= softAfter
  var keep = 0
  for (var i = 0; i < agreed; i++) {
    if (sentenceEnd(look.pieces[i]) || (long && look.pieces[i].kind === "soft")) keep = i + 1
  }
  if (keep === 0) return { text: heard.text, from: heard.from, last: look, tail: lookText(look), until: look.end }
  var kept = look.pieces.slice(0, keep).map(function (p) { return p.text }).join(" ")
  return {
    text: join(heard.text, kept),
    from: look.pieces[keep - 1].at,
    last: null,
    tail: lookText({ pieces: look.pieces.slice(keep), rest: look.rest }),
    until: look.end
  }
}

// Nothing heard yet.
function unheard() {
  return { text: "", from: 0, last: null, tail: "", until: 0 }
}

// A level, 0 to 1, from which the microphone hears a voice: a word said
// softly is over it, a room's hum well under.
var voiceLevel = 0.25

// Whether the newest look heard all that was said, <voiceAt> being the
// second the voice was last heard (counted from the press, which is before
// the recording's first second): then its words are the dictation's, at
// once, with nothing left to hear.
function heardAll(heard, voiceAt) {
  return heard.until > 0 && voiceAt + 0.4 < heard.until
}

// <next> after <text>. After a cut at a comma, Parakeet starts the next part
// with a capital it would not have given it mid-sentence. What looks like a
// name keeps it: "I", a word in capitals, an abbreviation ("Dr."), and a
// word before another with a capital ("Lieutenant Colonel").
function join(text, next) {
  if (text === "") return next
  if (next === "") return text
  var words = next.split(" ")
  var first = words[0]
  var second = words.length > 1 ? words[1] : ""
  if (!/[.!?]$/.test(text) && !/^I($|['’,.!?;:])/.test(first) && !/\.$/.test(first)
      && upper(first.charAt(0)) && first.slice(1) === first.slice(1).toLowerCase()
      && !upper(second.charAt(0)))
    next = next.charAt(0).toLowerCase() + next.slice(1)
  return text + " " + next
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
