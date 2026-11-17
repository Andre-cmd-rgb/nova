.pragma library

// The menu's calculator: whether a search is a sum or a conversion, put the
// way qalc (libqalculate) reads it, and the answer qalc printed, to show in
// one row whose Return copies it.
//
// A search is asked of qalc only when it holds a digit and something that
// asks for a calculation: an operator, a function's brackets, or "in" or
// "to" before a unit. A word alone, a number alone, a file's name (with _ or
// a date in it) or a path is not. qalc then says no to the rest: a word it
// does not know is an error, as it is told to treat one (limimpl), and an
// error or a warning means no row.

// What asks for a calculation, once a search is put qalc's way.
const ASKS = /[-+*\/×÷^!%(]|\bto\b/
// What no sum holds, and file names, paths and code do.
const NOT_A_SUM = /[_~#@:;\\$&|<>{}\[\]"`'?]|\d{4}-\d{1,2}-\d{1,2}/
// A number alone, as a search for a file named so is.
const NUMBER_ALONE = /^[-+−]?(\d[\d.,]*|\.\d+)$/

// Number bases, which qalc converts to without a unit.
const BASES = ["hex", "hexadecimal", "bin", "binary", "oct", "octal", "dec", "decimal", "roman", "duo", "duodecimal"]

// The search as qalc should read it, or "" when it is not a sum.
//   "15% of 80"      15% × 80
//   "2 x 3"          2 × 3
//   "5 km in miles"  5 km to -miles: the conversion in one unit, not in
//                    miles, yards and inches
//   "72 f in c"      72 °F to -°C: a letter of the three temperature scales
//                    on both sides is that scale, not a farad and a coulomb
function expression(query) {
  let text = String(query || "").trim().replace(/\s+/g, " ").replace(/\s*[=]+$/, "")
  if (!/\d/.test(text) || NUMBER_ALONE.test(text) || NOT_A_SUM.test(text)) return ""
  text = text.replace(/(\d\s*%) of /gi, "$1 × ").replace(/(\d) [x×] (?=[\d(.])/gi, "$1 × ")
  const conversion = /^(.+) (?:in|to|into|as) ([^\d\s()+*\/^=!%,][^()+*=!%,]*)$/i.exec(text)
  if (conversion) {
    const [, amount, unit] = conversion
    const scale = word => ({ f: "°F", c: "°C", k: "K" })[word.replace(/^°/, "").toLowerCase()]
    const measured = /^(.*\d) ?(°?[fckFCK])$/.exec(amount)
    if (measured && scale(measured[2]) && scale(unit)) return measured[1] + " " + scale(measured[2]) + " to -" + scale(unit)
    return amount + " to " + (BASES.includes(unit.toLowerCase()) ? "" : "-") + unit
  }
  return ASKS.test(text) ? text : ""
}

// The words qalc is run with: its own settings, none of the user's, so that
// an answer reads the same for everyone; no currencies, whose rates would
// have to be fetched, and are stale without; a word it does not know an
// error rather than a product of units (limimpl); and no more than half a
// second. A leading minus is not an option.
function command(expression) {
  return ["qalc", "-defaults", "-nocurrencies", "-set", "limimpl 1", "-time", "500", (/^-/.test(expression) ? " " : "") + expression]
}

// qalc's answer, from what it printed: "2 × (3 + 4) = 14", the reading and
// the result, with each step between ("10 / 4 = 5/2 = 2.5"). { label, copy }:
// the result, and the text Return copies, with a plain minus; or null when
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
  return { label: result, copy: result.replace(/−/g, "-") }
}
