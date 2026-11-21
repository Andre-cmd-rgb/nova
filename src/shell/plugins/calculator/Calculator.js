.pragma library

// The calculator's engine, the Calculator window's and the menu's sums
// alike, so that the two give the same answer to the same words: a sum put
// the way qalc (libqalculate) reads it, the words qalc is run with, and the
// answer it printed.
// The site runs it too (tools/build-site), in the landing page's menu.
//
// The menu asks qalc only when a search holds a digit and something that
// asks for a calculation: an operator, a function's brackets, or "in" or
// "to" before a unit. A word alone, a number alone, a file's name (with _ or
// a date in it) or a path is not. qalc then says no to the rest: a word it
// does not know is an error, as it is told to treat one (limimpl), and an
// error or a warning means no answer.

// What asks for a calculation, once a search is put qalc's way.
const ASKS = /[-+*\/×÷^!%(]|\bto\b/
// What no sum holds, and file names, paths and code do.
const NOT_A_SUM = /[_~#@:;\\$&|<>{}\[\]"`'?]|\d{4}-\d{1,2}-\d{1,2}/
// A number alone, as a search for a file named so is.
const NUMBER_ALONE = /^[-+−]?(\d[\d.,]*|\.\d+)$/

// Number bases, which qalc converts to without a unit.
const BASES = ["hex", "hexadecimal", "bin", "binary", "oct", "octal", "dec", "decimal", "roman", "duo", "duodecimal"]

// The words as typed, on one line, without the = a sum may end with.
function written(text) {
  return String(text || "").trim().replace(/\s+/g, " ").replace(/\s*[=]+$/, "")
}

// <text> (written) the way qalc should read it. qalc reads × ÷ − √ ∛ ² ³ ⁻¹
// π and sin⁻¹ as they are; the rest is put its way:
//   "15% of 80"      15% × 80
//   "2 x 3"          2 × 3
//   "log(100)"       log10(100): a calculator's log, where qalc's own warns
//   "5 km in miles"  5 km to -miles: the conversion in one unit, not in
//                    miles, yards and inches
//   "72 f in c"      72 °F to -°C: a letter of the three temperature scales
//                    on both sides is that scale, not a farad and a coulomb
function qalcForm(text) {
  text = text.replace(/(\d\s*%) of /gi, "$1 × ").replace(/(\d) [x×] (?=[\d(.])/gi, "$1 × ").replace(/(^|[^a-z])log\(/gi, "$1log10(")
  const conversion = /^(.+) (?:in|to|into|as) ([^\d\s()+*\/^=!%,][^()+*=!%,]*)$/i.exec(text)
  if (!conversion) return text
  const [, amount, unit] = conversion
  const scale = word => ({ f: "°F", c: "°C", k: "K" })[word.replace(/^°/, "").toLowerCase()]
  const measured = /^(.*\d) ?(°?[fckFCK])$/.exec(amount)
  if (measured && scale(measured[2]) && scale(unit)) return measured[1] + " " + scale(measured[2]) + " to -" + scale(unit)
  return amount + " to " + (BASES.includes(unit.toLowerCase()) ? "" : "-") + unit
}

// A search of the menu as qalc should read it, or "" when it is not a sum.
function expression(query) {
  const text = written(query)
  if (!/\d/.test(text) || NUMBER_ALONE.test(text) || NOT_A_SUM.test(text)) return ""
  const sum = qalcForm(text)
  return ASKS.test(sum) ? sum : ""
}

// The words qalc is run with: its own settings, none of the user's, so that
// an answer reads the same for everyone; no currencies, whose rates would
// have to be fetched, and are stale without; a word it does not know an
// error rather than a product of units (limimpl); the <settings> asked for
// besides ("angle deg"); and no more than half a second. A leading minus is
// not an option.
function command(expression, settings) {
  const set = (settings || []).reduce((words, setting) => words.concat(["-set", setting]), [])
  return ["qalc", "-defaults", "-nocurrencies", "-set", "limimpl 1"].concat(set, ["-time", "500", (/^-/.test(expression) ? " " : "") + expression])
}

// qalc's answer, from what it printed: "2 × (3 + 4) = 14", the reading and
// the result, with each step between ("10 / 4 = 5/2 = 2.5"). { label, copy }:
// the result, without the zeros a rounded one can end in (17.31370850 is
// 17.3137085), and the text a copy takes, with a plain minus; or null when
// qalc said anything else, as an error, a warning, an expression it could
// not work out ("1 a − 1", "6x"), a date or a vector.
function answer(printed, expression) {
  const lines = String(printed || "").split("\n").map(line => line.trim()).filter(Boolean)
  if (lines.length !== 1 || /^(error|warning):/i.test(lines[0])) return null
  const steps = lines[0].split(/ [=≈] /)
  const result = steps[steps.length - 1]
  if (steps.length < 2 || !result) return null
  const base = BASES.some(name => new RegExp(" to " + name + "$", "i").test(String(expression || "")))
  const number = /^−?(\d[\d ]*(\.\d+)?|\.\d+)(E−?\d+)?( (?!.* [−+×\/] )[^\d\s"\[\]=≈][^"\[\]=≈]*)?$/
  if (!base && !number.test(result)) return null
  if (base && /["\[\]]| [−+×\/] /.test(result)) return null
  const shown = base ? result : result.replace(/^(−?[\d ]*\.\d*?)0+(?=$|E| )/, "$1").replace(/\.(?=$|E| )/, "")
  return { label: shown, copy: shown.replace(/−/g, "-") }
}
