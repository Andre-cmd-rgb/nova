.pragma library

// The Calculator's keys and what each does, apart from how they are drawn: a
// key turns one state of the display into the next. A state is
// { typed, previous, done }:
//   typed     the sum shown large, as typed, the operators as the keys
//             write them (× ÷ −); right after =, its answer
//   previous  the sum = worked out, shown small above it, "" for none
//   done      typed is an answer: a digit starts a new sum, an operator goes
//             on from the answer, Backspace takes the sum back
// No function here changes the state it is handed.

// The keys, each where it sits in its grid (row, col, and a span of rows or
// columns); kind is how it is drawn: digit, function, operator or equals.
// Basic is four columns by six rows, the operators down the right as on
// every calculator; the scientific keys are three columns to its left.
var BASIC = [
  { id: "C", label: "AC", kind: "function", row: 0, col: 0 },
  { id: "⌫", label: "󰭜", kind: "function", row: 0, col: 1 },
  { id: "%", label: "%", kind: "function", row: 0, col: 2 },
  { id: "÷", label: "÷", kind: "operator", row: 0, col: 3 },
  { id: "(", label: "(", kind: "function", row: 1, col: 0 },
  { id: ")", label: ")", kind: "function", row: 1, col: 1 },
  { id: "±", label: "±", kind: "function", row: 1, col: 2 },
  { id: "×", label: "×", kind: "operator", row: 1, col: 3 },
  { id: "7", label: "7", kind: "digit", row: 2, col: 0 },
  { id: "8", label: "8", kind: "digit", row: 2, col: 1 },
  { id: "9", label: "9", kind: "digit", row: 2, col: 2 },
  { id: "−", label: "−", kind: "operator", row: 2, col: 3 },
  { id: "4", label: "4", kind: "digit", row: 3, col: 0 },
  { id: "5", label: "5", kind: "digit", row: 3, col: 1 },
  { id: "6", label: "6", kind: "digit", row: 3, col: 2 },
  { id: "+", label: "+", kind: "operator", row: 3, col: 3 },
  { id: "1", label: "1", kind: "digit", row: 4, col: 0 },
  { id: "2", label: "2", kind: "digit", row: 4, col: 1 },
  { id: "3", label: "3", kind: "digit", row: 4, col: 2 },
  { id: "=", label: "=", kind: "equals", row: 4, col: 3, rows: 2 },
  { id: "0", label: "0", kind: "digit", row: 5, col: 0, cols: 2 },
  { id: ".", label: ".", kind: "digit", row: 5, col: 2 }
]

// 2nd turns the three functions into their inverses, ln into eˣ and log
// into 10ˣ; the angle key says the unit the functions take, and switches it.
var SCIENTIFIC = [
  { id: "2nd", label: "2nd", kind: "function", row: 0, col: 0 },
  { id: "angle", label: "Deg", kind: "function", row: 0, col: 1 },
  { id: "π", label: "π", kind: "function", row: 0, col: 2 },
  { id: "sin", label: "sin", second: "sin⁻¹", kind: "function", row: 1, col: 0 },
  { id: "cos", label: "cos", second: "cos⁻¹", kind: "function", row: 1, col: 1 },
  { id: "tan", label: "tan", second: "tan⁻¹", kind: "function", row: 1, col: 2 },
  { id: "²", label: "x²", kind: "function", row: 2, col: 0 },
  { id: "³", label: "x³", kind: "function", row: 2, col: 1 },
  { id: "^", label: "xʸ", kind: "function", row: 2, col: 2 },
  { id: "√", label: "√x", kind: "function", row: 3, col: 0 },
  { id: "∛", label: "∛x", kind: "function", row: 3, col: 1 },
  { id: "ʸ√", label: "ʸ√x", kind: "function", row: 3, col: 2 },
  { id: "ln", label: "ln", second: "eˣ", kind: "function", row: 4, col: 0 },
  { id: "log", label: "log", second: "10ˣ", kind: "function", row: 4, col: 1 },
  { id: "e", label: "e", kind: "function", row: 4, col: 2 },
  { id: "⁻¹", label: "1/x", kind: "function", row: 5, col: 0 },
  { id: "!", label: "x!", kind: "function", row: 5, col: 1 },
  { id: "EE", label: "EE", kind: "function", row: 5, col: 2 }
]

// What a key does with 2nd on: its second's id.
var SECOND = { "sin": "sin⁻¹", "cos": "cos⁻¹", "tan": "tan⁻¹", "ln": "eˣ", "log": "10ˣ" }

// Functions written with their bracket, and the other runs of characters a
// key writes as one: Backspace takes each away whole.
const FUNCTIONS = ["sin", "cos", "tan", "sin⁻¹", "cos⁻¹", "tan⁻¹", "ln", "log"]
const TOKENS = FUNCTIONS.map(name => name + "(").concat(["^(1/", "⁻¹"])

const OPERATOR = /[+−×÷^]$/
// What ends a sum that a number cannot follow without an operator between:
// a bracket closed, a constant, or a mark after a number.
const VALUE_END = /([)π!%²³¹]|(^|[+−×÷^(])e)$/
// A number at the end, with its exponent (EE) if it has one.
const NUMBER_END = /(\d+(\.\d*)?|\.\d+)(E−?\d*)?$/
// A sum that is one number, as an answer is.
const PLAIN = /^−?(\d+(\.\d*)?|\.\d+)(E−?\d+)?$/

function blank() {
  return { typed: "", previous: "", done: false }
}

function edited(typed) {
  return { typed: typed, previous: "", done: false }
}

// The brackets opened and not closed yet, which the display shows closed in
// a fainter colour, and qalc closes by itself.
function opens(typed) {
  let depth = 0
  for (const ch of typed) {
    if (ch === "(") depth++
    else if (ch === ")" && depth > 0) depth--
  }
  return depth
}

// Where the number at the end starts, or -1.
function numberStart(typed) {
  const found = NUMBER_END.exec(typed)
  return found ? found.index : -1
}

// Where the value at the end starts, or -1: a number, a constant or a
// bracket with the function before it, with the marks after it (x², 5!).
function operandStart(typed) {
  let end = typed.length
  for (;;) {
    if (typed.slice(0, end).endsWith("⁻¹")) end -= 2
    else if (/[²³!%]$/.test(typed.slice(0, end))) end -= 1
    else break
  }
  const body = typed.slice(0, end)
  if (body.endsWith(")")) {
    let depth = 0
    for (let i = body.length - 1; i >= 0; i--) {
      if (body[i] === ")") depth++
      else if (body[i] === "(" && --depth === 0) {
        let start = i
        while (start > 0 && /[a-z⁻¹√∛]/.test(body[start - 1])) start--
        return start
      }
    }
    return -1
  }
  const number = numberStart(body)
  if (number >= 0) return number
  if (/π$/.test(body) || /(^|[+−×÷^(])e$/.test(body)) return body.length - 1
  return -1
}

// Whether <value> is one bracket, from its first character to its last.
function grouped(value) {
  if (!value.startsWith("(")) return false
  let depth = 0
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "(") depth++
    else if (value[i] === ")" && --depth === 0) return i === value.length - 1
  }
  return false
}

// A value as a root's or a power's: as it is when it is one number or one
// bracket, else in brackets.
function bracketed(value) {
  return /^(\d+(\.\d+)?|\.\d+)$/.test(value) || value === "π" || value === "e" || grouped(value) ? value : "(" + value + ")"
}

// <typed> with a value below zero at its end in brackets, closed, so that
// a power or a mark after it takes the minus too: −3 then x² is (−3)², 9,
// where −3² is −9.
function sealed(typed) {
  const at = operandStart(typed)
  if (at < 0) return typed
  const before = typed.slice(0, at)
  if (before.endsWith("(−")) return typed + ")"
  if (/(^|[+−×÷^(E])−$/.test(before)) return before.slice(0, -1) + "(−" + typed.slice(at) + ")"
  return typed
}

// An answer as the start of a sum that raises it: in brackets below zero.
function continued(answer) {
  return answer.startsWith("−") ? "(" + answer + ")" : answer
}

// ---------------------------------------------------------------- the keys

// What <id>, a key of BASIC or SCIENTIFIC or its second, does to <state>.
// = is the window's, as it waits for qalc; the angle and 2nd keys are too.
function press(state, id) {
  if (/^[0-9]$/.test(id)) return digit(state, id)
  switch (id) {
  case ".": return point(state)
  case "+": case "−": case "×": case "÷": case "^": return operator(state, id)
  case "ʸ√": return infix(state, "^(1/")
  case "(": return open(state)
  case ")": return close(state)
  case "%": case "²": case "³": case "⁻¹": case "!": return postfix(state, id)
  case "±": return negate(state)
  case "⌫": return backspace(state)
  case "C": return clear(state)
  case "√": case "∛": return root(state, id)
  case "eˣ": return power(state, "e^")
  case "10ˣ": return power(state, "10^")
  case "π": case "e": return constant(state, id)
  case "EE": return exponent(state)
  }
  if (FUNCTIONS.includes(id)) return applied(state, id)
  return state
}

function digit(state, d) {
  if (state.done) return edited(d)
  const typed = state.typed
  // A lone 0 is replaced: 0 then 5 is 5, and 2+0 then 5 is 2+5.
  if (/(^|[^\d.])0$/.test(typed)) return edited(typed.slice(0, -1) + d)
  if (VALUE_END.test(typed)) return edited(typed + "×" + d)
  return edited(typed + d)
}

function point(state) {
  if (state.done) return edited("0.")
  const typed = state.typed
  const at = numberStart(typed)
  if (at >= 0) return /[.E]/.test(typed.slice(at)) ? state : edited(typed + ".")
  return edited(typed + (VALUE_END.test(typed) ? "×0." : "0."))
}

// An operator goes after the value; one after another takes its place,
// but for a minus after × ÷ or ^, which makes the next number negative.
function operator(state, op) {
  if (state.done) return edited((op === "^" ? continued(state.typed) : state.typed) + op)
  const typed = op === "^" ? sealed(state.typed) : state.typed
  if (typed === "") return edited(op === "−" ? "−" : "0" + op)
  const last = typed.slice(-1), before = typed.slice(-2, -1)
  if (OPERATOR.test(typed)) {
    if (op === last) return state
    if (op === "−" && "×÷^".includes(last)) return edited(typed + "−")
    if (typed === "−" || before === "(" || before === "E") return state
    if (last === "−" && "×÷^".includes(before)) return edited(typed.slice(0, -2) + op)
    return edited(typed.slice(0, -1) + op)
  }
  if (last === "(" || last === "E") return op === "−" ? edited(typed + "−") : state
  return edited(typed + op)
}

// ʸ√x: the root the next number says, written as the power it is.
function infix(state, text) {
  if (state.done) return edited(continued(state.typed) + text)
  if (operandStart(state.typed) < 0) return state
  return edited(sealed(state.typed) + text)
}

function open(state) {
  if (state.done) return edited("(")
  const typed = state.typed
  if (typed.endsWith("E")) return state
  return edited(typed + (typed !== "" && (VALUE_END.test(typed) || numberStart(typed) >= 0) ? "×(" : "("))
}

// A bracket closes only one opened, and not straight after an operator.
function close(state) {
  if (state.done || opens(state.typed) === 0 || /[+−×÷^(E√∛]$/.test(state.typed)) return state
  return edited(state.typed + ")")
}

// A mark after the value: %, x², x³, 1/x, x!.
function postfix(state, mark) {
  const raises = mark !== "%"
  if (state.done) return edited((raises ? continued(state.typed) : state.typed) + mark)
  if (operandStart(state.typed) < 0) return state
  return edited((raises ? sealed(state.typed) : state.typed) + mark)
}

// ±: the number at the end below zero, or back: after an operator it is
// written (−5, with the bracket closed when the sum is. An answer turns
// round and stays one.
function negate(state) {
  const turned = text => text.startsWith("−") ? text.slice(1) : "−" + text
  if (state.done) return { typed: turned(state.typed), previous: "", done: true }
  const typed = state.typed
  if (typed === "" || typed === "−") return edited(typed === "" ? "−" : "")
  if (typed.endsWith("(−")) return edited(typed.slice(0, -2))
  const at = operandStart(typed)
  if (at < 0) {
    if (OPERATOR.test(typed)) return edited(typed + "(−")
    if (typed.endsWith("(")) return edited(typed + "−")
    return state
  }
  const before = typed.slice(0, at), value = typed.slice(at)
  if (before.endsWith("(−")) return edited(before.slice(0, -2) + value)
  if (before === "−" || /[(E]−$/.test(before)) return edited(before.slice(0, -1) + value)
  if (before === "") return edited("−" + value)
  if (before.endsWith("(")) return edited(before + "−" + value)
  return edited(before + "(−" + value)
}

// Backspace takes away what one key wrote. Right after =, it takes the sum
// back, to be changed.
function backspace(state) {
  if (state.done) return state.previous ? edited(state.previous) : edited(state.typed.slice(0, -1))
  const typed = state.typed
  const token = TOKENS.filter(t => typed.endsWith(t)).sort((a, b) => b.length - a.length)[0]
  return edited(typed.slice(0, typed.length - (token ? token.length : 1)))
}

// C clears the number being typed, and AC everything; the key is C while
// there is a number after the rest of the sum (clearsEntry).
function clearsEntry(state) {
  return !state.done && numberStart(state.typed) > 0
}

function clear(state) {
  return clearsEntry(state) ? edited(state.typed.slice(0, numberStart(state.typed))) : blank()
}

// A function takes the value at the end, as a calculator's key does to the
// number shown; with none, it opens its bracket for the next.
function applied(state, name) {
  const argument = value => grouped(value) ? value : "(" + value + ")"
  if (state.done) return edited(name + argument(state.typed))
  const typed = state.typed
  const at = operandStart(typed)
  if (at >= 0) return edited(typed.slice(0, at) + name + argument(typed.slice(at)))
  if (typed === "" || /[+−×÷^(]$/.test(typed)) return edited(typed + name + "(")
  return state
}

function root(state, sign) {
  if (state.done) return edited(sign + bracketed(state.typed))
  const typed = state.typed
  const at = operandStart(typed)
  if (at >= 0) return edited(typed.slice(0, at) + sign + bracketed(typed.slice(at)))
  if (typed === "" || /[+−×÷^(]$/.test(typed)) return edited(typed + sign)
  return state
}

// eˣ and 10ˣ: <base> to the value at the end, or to the number typed next.
function power(state, base) {
  if (state.done) return edited(base + bracketed(state.typed))
  const typed = state.typed
  const at = operandStart(typed)
  if (at >= 0) return edited(typed.slice(0, at) + base + bracketed(typed.slice(at)))
  if (typed === "" || /[+−×÷^(]$/.test(typed)) return edited(typed + base)
  return state
}

// π and e, times what is before them.
function constant(state, sign) {
  if (state.done) return edited(sign)
  const typed = state.typed
  if (typed === "" || /[+−×÷^(]$/.test(typed)) return edited(typed + sign)
  if (typed.endsWith("E")) return state
  return edited(typed + "×" + sign)
}

// EE: the power of ten the number is multiplied by, typed next (3E5).
function exponent(state) {
  if (state.done) return PLAIN.test(state.typed) && !state.typed.includes("E") ? edited(state.typed + "E") : state
  const at = numberStart(state.typed)
  if (at < 0 || state.typed.slice(at).includes("E")) return state
  return edited(state.typed + "E")
}

// ---------------------------------------------------------- the keyboard

// The key a typed character stands for, or "" for one written as it is (a
// letter, a space: "5 km in miles", "0x1F in dec"). The keypad's decimal
// key may type a comma.
function keyFor(text, keypad) {
  if (/^[0-9]$/.test(text)) return text
  if (keypad && text === ",") return "."
  return { ".": ".", "+": "+", "-": "−", "*": "×", "/": "÷", "^": "^", "(": "(", ")": ")", "%": "%", "!": "!",
    "−": "−", "×": "×", "÷": "÷" }[text] || ""
}

// A character typed that no key stands for, written as it is; right after
// =, a space goes on from the answer ("14 in hex") and a letter starts anew.
function written(state, text) {
  if (state.done) return edited(text === " " ? state.typed + " " : text)
  if (text === " " && (state.typed === "" || state.typed.endsWith(" "))) return state
  return edited(state.typed + text)
}

// ------------------------------------------------------- other ways in

// Words from elsewhere (pasted, from the menu, from nova calculator) as
// the display writes them: on one line, at most 200 characters, without the
// = they may end with or the commas of thousands; * as ×, - as − but inside
// a word, and / as ÷ between numbers (km/h stays).
function tidy(text) {
  return String(text || "").replace(/\s+/g, " ").trim().replace(/\s*=+$/, "").slice(0, 200)
    .replace(/(\d),(?=\d{3}(\D|$))/g, "$1")
    .replace(/\*/g, "×")
    .replace(/-/g, (dash, at, all) => /[a-z]/i.test(all[at - 1] || "") && /[a-z]/i.test(all[at + 1] || "") ? dash : "−")
    .replace(/([\d)])\s*\/\s*(?=[\d(.])/g, "$1÷")
}

// Pasted words go after what is typed; right after =, in its place.
function pasted(state, text) {
  const words = tidy(text)
  if (!words) return state
  return edited(state.done ? words : state.typed + words)
}

// A sum the history keeps, clicked: its answer goes on the end of a sum
// waiting for a number, and otherwise the sum and its answer come back as
// right after =.
function recalled(state, entry) {
  if (!state.done && /[+−×÷^(]$/.test(state.typed)) return edited(state.typed + entry.result)
  return { typed: entry.result, previous: entry.expression, done: true }
}

// --------------------------------------------------------------- to qalc

// What of <typed> can be worked out now: without what waits for more at
// its end (an operator, a bracket or a function just opened, an E, the "in"
// of a conversion), so that the answer shown while typing stays put
// between keys; and with its brackets closed, as the history keeps it.
function ready(typed) {
  let text = typed
  for (;;) {
    const token = TOKENS.concat(["(−", "√", "∛"]).filter(t => text.endsWith(t)).sort((a, b) => b.length - a.length)[0]
    if (token) text = text.slice(0, -token.length)
    else if (/[+−×÷^(E ]$/.test(text)) text = text.slice(0, -1)
    else if (/ (in|to|into|as)$/i.test(text)) text = text.replace(/ \w+$/, "")
    else return text + ")".repeat(opens(text))
  }
}

// = again, right after =: the last operator and number of the sum, on the
// answer (2+3 = 5, = 8, = 11), or "".
function repeated(previous) {
  const found = /([+−×÷^])(\d+(\.\d+)?(E−?\d+)?)$/.exec(previous)
  return found && opens(previous.slice(0, found.index)) === 0 ? found[0] : ""
}

// The sum = works out: what is typed, as far as it can be worked out;
// right after =, the answer with the last operator and number again, or ""
// for none.
function toWorkOut(state) {
  if (!state.done) return ready(state.typed)
  const again = repeated(state.previous)
  return again ? (again[0] === "^" ? continued(state.typed) : state.typed) + again : ""
}

// Whether <text> is one number, which is its own answer.
function plain(text) {
  return PLAIN.test(text)
}

// Whether <typed> takes an angle: a sum the angle key's unit changes.
function angled(typed) {
  return /(sin|cos|tan)/.test(typed)
}

// Whether the answer says nothing the sum does not: 12 for 12.
function same(typed, label) {
  return typed === label || PLAIN.test(typed) && Number(typed.replace(/−/g, "-")) === Number(label.replace(/−/g, "-"))
}

// --------------------------------------------------------------- history

var HISTORY_LIMIT = 100

// The history with <entry> ({ expression, result }) on top, the same one
// just before it once, HISTORY_LIMIT at most.
function added(history, entry) {
  const top = history[0]
  if (top && top.expression === entry.expression && top.result === entry.result) return history
  return [entry].concat(history).slice(0, HISTORY_LIMIT)
}

// The history a file kept, of entries that are two texts each.
function historyFrom(list) {
  return (Array.isArray(list) ? list : []).filter(entry => entry && typeof entry.expression === "string"
    && typeof entry.result === "string" && entry.expression && entry.result)
    .map(entry => ({ expression: entry.expression, result: entry.result })).slice(0, HISTORY_LIMIT)
}
