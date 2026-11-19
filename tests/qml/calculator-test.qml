import QtQuick
import Quickshell
import "plugins/calculator/Calculator.js" as Calculator
import "plugins/calculator/Keypad.js" as Keypad

// The Calculator's keys, apart from its window: what each writes on the sum
// typed, C and AC, ±, the keys after =, what of a sum is worked out while
// it is typed, = again, words from elsewhere, the history; and the sums put
// qalc's way alike for the window and the menu.
ShellRoot {
  id: test

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  // The sum typed after <keys>, from nothing.
  function typed(keys) {
    return keys.reduce((state, key) => Keypad.press(state, key), Keypad.blank()).typed
  }

  // Each of <cases>, [keys, sum], that does not come out so, as words.
  function wrong(cases) {
    return cases.filter(([keys, sum]) => typed(keys) !== sum).map(([keys, sum]) => keys.join(" ") + " → " + typed(keys))
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    let off = wrong([
      [["1", "2", "+", "3", "4"], "12+34"], [["0", "5"], "5"], [["2", "+", "0", "5"], "2+5"], [["1", "0", "5"], "105"],
      [[".", "5"], "0.5"], [["2", ".", "."], "2."], [["2", "(", "3"], "2×(3"], [["(", "2", "+", "3", ")", "4"], "(2+3)×4"],
      [[")", "2"], "2"], [["(", "2", "+", ")"], "(2+"]
    ])
    check(off.length === 0, "digits, the point and brackets: a lone 0 replaced, one point a number, a bracket after a value times it, none closed unopened (" + off.join("; ") + ")")

    off = wrong([
      [["+"], "0+"], [["−", "5"], "−5"], [["2", "+", "×"], "2×"], [["2", "×", "−", "3"], "2×−3"],
      [["2", "×", "−", "+"], "2+"], [["2", "×", "−", "−"], "2×−"], [["3", "EE", "−", "5"], "3E−5"], [["3", "EE", "+"], "3E"]
    ])
    check(off.length === 0, "an operator after another takes its place, but a minus after × makes the number negative (" + off.join("; ") + ")")

    off = wrong([
      [["1", "2", "±"], "−12"], [["1", "2", "±", "±"], "12"], [["1", "2", "+", "3", "±"], "12+(−3"],
      [["1", "2", "+", "3", "±", "4"], "12+(−34"], [["1", "2", "+", "3", "±", "±"], "12+3"], [["1", "2", "+", "±", "5"], "12+(−5"],
      [["3", "±", "²"], "(−3)²"], [["1", "2", "+", "3", "±", "^", "2"], "12+(−3)^2"], [["1", "2", "−", "3", "²"], "12−3²"]
    ])
    check(off.length === 0, "± turns the number at the end round, and a power takes its minus too (" + off.join("; ") + ")")

    off = wrong([
      [["3", "0", "sin"], "sin(30)"], [["sin", "3", "0"], "sin(30"], [["2", "×", "sin", "3", "0"], "2×sin(30"],
      [["(", "2", "+", "7", ")", "sin"], "sin(2+7)"], [["9", "√"], "√9"], [["(", "2", "+", "7", ")", "√"], "√(2+7)"],
      [["3", "²", "2"], "3²×2"], [["2", "7", "ʸ√", "3"], "27^(1/3"], [["5", "!"], "5!"], [["4", "⁻¹"], "4⁻¹"],
      [["2", "π"], "2×π"], [["2", "e"], "2×e"], [["3", "EE", "5"], "3E5"], [["2", "eˣ"], "e^2"], [["10ˣ", "3"], "10^3"],
      [["²"], ""], [["2", "0", "0", "+", "1", "5", "%"], "200+15%"]
    ])
    check(off.length === 0, "a function takes the value at the end or opens for the next; marks, roots, powers and constants (" + off.join("; ") + ")")

    off = wrong([
      [["1", "2", "+", "3", "4", "C"], "12+"], [["1", "2", "+", "C"], ""], [["1", "2", "+", "sin", "⌫"], "12+"],
      [["1", "2", "⌫"], "1"], [["2", "7", "ʸ√", "⌫"], "27"], [["4", "⁻¹", "⌫"], "4"]
    ])
    const entry = Keypad.press(Keypad.press(Keypad.blank(), "1"), "+")
    check(off.length === 0 && Keypad.clearsEntry(Keypad.press(entry, "2")) && !Keypad.clearsEntry(entry) && !Keypad.clearsEntry(Keypad.press(Keypad.blank(), "7")),
      "C clears the number typed after the rest, AC all; Backspace takes back what one key wrote (" + off.join("; ") + ")")

    const done = { typed: "14", previous: "2×(3+4)", done: true }
    const after = key => Keypad.press(done, key)
    check(after("5").typed === "5" && !after("5").done && after("+").typed === "14+" && after("sin").typed === "sin(14)"
      && after("⌫").typed === "2×(3+4)" && !after("⌫").done && after("±").typed === "−14" && after("±").done
      && Keypad.press({ typed: "−14", previous: "", done: true }, "²").typed === "(−14)²",
      "after =, a digit starts anew, an operator or a function goes on from the answer, Backspace takes the sum back, ± turns it round")

    const ready = ["2×sin(", "12+", "12+(−", "3E−", "5 km in", "2×(3+"].map(Keypad.ready)
    check(ready.join("|") === "2|12|12|3|5 km|2×(3)", "what waits for more at the end is left out of the sum worked out while typing, and its brackets are closed (" + ready.join("|") + ")")
    check(Keypad.toWorkOut({ typed: "5", previous: "2+3", done: true }) === "5+3" && Keypad.toWorkOut({ typed: "−2", previous: "1^2", done: true }) === "(−2)^2"
      && Keypad.toWorkOut({ typed: "14", previous: "2×(3+4)", done: true }) === "" && Keypad.toWorkOut({ typed: "12+", previous: "", done: false }) === "12",
      "= again does the last operator and number again on the answer; a sum ending in a bracket has none")
    check(Keypad.keyFor("*", false) === "×" && Keypad.keyFor("/", false) === "÷" && Keypad.keyFor("-", false) === "−" && Keypad.keyFor(",", true) === "."
      && Keypad.keyFor(",", false) === "" && Keypad.keyFor("k", false) === "",
      "the keyboard's * / - are × ÷ −, the keypad's comma a point, and a letter is written as it is")
    check(Keypad.written(done, " ").typed === "14 " && Keypad.written(done, "s").typed === "s" && Keypad.written(Keypad.blank(), " ").typed === "",
      "after =, a space goes on from the answer (14 in hex), a letter starts anew")

    const tidied = ["2*(3+4)", "10 / 4", "60 mph in km/h", "-5 - 2", "x-ray", "1,234.5 + 1", " 2+2 = ", "a\nb"].map(Keypad.tidy)
    check(tidied.join("|") === "2×(3+4)|10÷4|60 mph in km/h|−5 − 2|x-ray|1234.5 + 1|2+2|a b", "words from elsewhere as the keys write them (" + tidied.join("|") + ")")
    check(Keypad.pasted({ typed: "2×", previous: "", done: false }, "21").typed === "2×21" && Keypad.pasted(done, "3*3").typed === "3×3",
      "a paste goes after the sum, and after = in its place")
    const sum = { expression: "2×(3+4)", result: "14" }
    check(Keypad.recalled({ typed: "1+", previous: "", done: false }, sum).typed === "1+14"
      && JSON.stringify(Keypad.recalled({ typed: "9", previous: "", done: false }, sum)) === JSON.stringify({ typed: "14", previous: "2×(3+4)", done: true }),
      "a sum of the history clicked: its answer after an operator, else the sum and its answer as after =")

    let history = []
    for (let i = 0; i < 105; i++) history = Keypad.added(history, { expression: i + "+1", result: String(i + 1) })
    check(history.length === 100 && history[0].expression === "104+1" && Keypad.added(history, { expression: "104+1", result: "105" }) === history,
      "the history keeps the last 100, newest first, and the same sum twice in a row once")
    check(Keypad.historyFrom([sum, null, { expression: "", result: "1" }, { expression: 2, result: "2" }, "x"]).length === 1 && Keypad.historyFrom("x").length === 0,
      "a history read from a file keeps only entries of two texts")

    check(Calculator.qalcForm(Calculator.written("log(100)")) === "log10(100)" && Calculator.expression("log(100)") === "log10(100)"
      && Calculator.qalcForm("2log(100)+blog(1)") === "2log10(100)+blog(1)"
      && Calculator.qalcForm(Calculator.written("5 km in miles =")) === Calculator.expression("5 km in miles")
      && Calculator.qalcForm(Calculator.written("2×(3+4)")) === "2×(3+4)",
      "the window and the menu put a sum qalc's way alike: log is log10, in is to, = at the end dropped")
    const words = Calculator.command("2", ["angle deg"])
    check(words.slice(0, 5).join(" ") === "qalc -defaults -nocurrencies -set limimpl 1" && words.join(" ").includes("-set angle deg -time 500")
      && words[words.length - 1] === "2" && Calculator.command("2").indexOf("angle deg") < 0,
      "the window's qalc has the menu's settings and the angle's unit besides")
    const trimmed = ["x ≈ 17.31370850", "x ≈ 2.000000000E19", "x = 1.50 mi", "x = 100.0", "x ≈ 3.106855961 mi"].map(printed => Calculator.answer(printed, "").label)
    check(trimmed.join("|") === "17.3137085|2E19|1.5 mi|100|3.106855961 mi" && Calculator.answer("8 = 0000 1000", "8 to bin").label === "0000 1000",
      "an answer read back for both drops the zeros a rounded number ends in, but a base's digits (" + trimmed.join("|") + ")")
    check(Keypad.same("12", "12") && Keypad.same("12.", "12") && !Keypad.same("2+3", "5") && Keypad.angled("2×sin(30") && !Keypad.angled("2+3"),
      "an answer that says what the sum says is not shown; a sum with a function that takes an angle is told")

    console.log("DONE")
    Qt.quit()
  }
}
