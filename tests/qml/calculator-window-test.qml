// platform: wayland
// warns: Trying to disable
// stub: bin/qalc qalc
// stub: bin/wl-copy record
// stub: bin/wl-paste wl-paste
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/calculator" as Calculator

// The Calculator's window, with a stand-in qalc: opened on a sum, its
// answer shown under it as typed, = and = again, Error, the keyboard, the
// angle's unit, Ctrl+C and Ctrl+V, the history and what else is kept, read
// back by the next opening, and Esc.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property string kept: home + "/.local/state/nova/calculator.json"

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  Loader {
    id: loader
    sourceComponent: Calculator.Panel {}
  }

  readonly property var calc: loader.item

  function window() {
    for (let i = 0; i < calc.data.length; i++)
      if (calc.data[i] && calc.data[i].contentItem !== undefined) return calc.data[i]
    return null
  }

  FileView { id: callsFile; path: test.home + "/stub-calls"; blockAllReads: true; printErrors: false }
  FileView { id: runsFile; path: test.home + "/qalc-calls"; blockAllReads: true; printErrors: false }
  FileView { id: keptFile; path: test.kept; blockAllReads: true; printErrors: false }
  FileView { id: clipboard; path: test.home + "/clipboard"; blockWrites: true; printErrors: false }

  function lines(file) {
    file.reload()
    return file.text().trim().split("\n").filter(Boolean)
  }

  function key(code, text, modifiers) {
    return calc.press({ key: code, text: text || "", modifiers: modifiers || Qt.NoModifier })
  }

  function type(text) {
    for (const ch of text) key(0, ch)
  }

  // <next> once <ready> holds, looked at every 50 ms for up to 5 s.
  function when(ready, next, what) {
    waiter.ready = ready
    waiter.next = next
    waiter.what = what
    waiter.tries = 0
    waiter.restart()
  }

  Timer {
    id: waiter
    property var ready: null
    property var next: null
    property string what: ""
    property int tries: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (ready()) {
        stop()
        next()
      } else if (++tries > 100) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  Component.onCompleted: Qt.callLater(opened)

  function opened() {
    calc.open(JSON.stringify({ expression: "2*(3+4" }))
    check(window().visible && window().title === "Calculator" && calc.calc.typed === "2×(3+4" && calc.mode === "basic" && calc.angle === "deg",
      "opened on the sum asked for, written as the keys write it, basic, in degrees, the first time")
    when(() => calc.previewShown, previewed, "the sum's answer shows under it")
  }

  function previewed() {
    const runs = lines(runsFile)
    check(calc.preview.label === "14" && runs.length === 1 && runs[0] === "2×(3+4)|C.UTF-8|" + Quickshell.env("XDG_RUNTIME_DIR") + "/nova/calculator",
      "its answer comes from one run of qalc, as the menu runs it (" + runs.join("; ") + ")")
    check(key(Qt.Key_Return, "\r"), "Return is taken")
    check(calc.calc.done && calc.calc.typed === "14" && calc.calc.previous === "2×(3+4)" && lines(runsFile).length === 1,
      "Return works the sum out with the answer already come, and shows the sum over it, its bracket closed")
    check(calc.history.length === 1 && calc.history[0].expression === "2×(3+4)" && calc.history[0].result === "14", "the sum goes into the history")
    let saved = {}
    try {
      saved = JSON.parse(lines(keptFile).join("\n"))
    } catch (e) { }
    check(saved.history && saved.history.length === 1 && saved.history[0].result === "14" && saved.mode === "basic" && saved.angle === "deg",
      "and into calculator.json, folder made where there was none")
    key(Qt.Key_C, "c", Qt.ControlModifier)
    when(() => lines(callsFile).length === 1, copied, "Ctrl+C copies the answer")
  }

  function copied() {
    check(lines(callsFile)[0] === "wl-copy -- 14", "Ctrl+C copies the answer")
    key(0, "+")
    key(0, "1")
    check(calc.calc.typed === "14+1" && !calc.calc.done, "an operator goes on from the answer")
    key(Qt.Key_Escape, "\u001b")
    check(calc.calc.typed === "" && window().visible, "Esc clears")
    type("2+3")
    calc.tap("=")
    when(() => calc.calc.done, () => {
      check(calc.calc.typed === "5", "= waits for an answer not come yet")
      calc.tap("=")
      when(() => calc.calc.typed === "8", again, "= again does + 3 again")
    }, "2+3 is worked out")
  }

  function again() {
    check(calc.calc.previous === "5+3" && calc.history[0].expression === "5+3" && calc.history.length === 3, "= again goes into the history too")
    key(Qt.Key_Backspace, "\b")
    check(calc.calc.typed === "5+3" && !calc.calc.done, "Backspace after = takes the sum back")
    calc.tap("C")
    calc.tap("C")
    type("1/0")
    check(calc.calc.typed === "1÷0", "/ types ÷")
    calc.tap("=")
    when(() => calc.failed, () => {
      check(calc.calc.typed === "1÷0" && !calc.calc.done && calc.history.length === 3, "a sum qalc cannot work out says Error, and stays to be changed")
      key(Qt.Key_Backspace, "\b")
      check(!calc.failed, "and Error goes at the next key")
      angles()
    }, "1÷0 is an error")
  }

  function angles() {
    calc.tap("C")
    calc.mode = "scientific"
    calc.tap("3")
    calc.tap("0")
    calc.tap("sin")
    check(calc.calc.typed === "sin(30)", "sin takes the number typed")
    when(() => calc.previewShown, () => {
      check(calc.preview.label === "0.5", "in degrees")
      calc.tap("angle")
      check(calc.angle === "rad" && calc.label({ id: "angle", label: "Deg" }) === "Rad", "the angle key switches to radians, and says so")
      when(() => calc.previewShown && calc.preview.label === "−0.9880316241", () => {
        check(true, "and the sum is worked out again in radians")
        calc.tap("2nd")
        check(calc.label({ id: "sin", label: "sin", second: "sin⁻¹" }) === "sin⁻¹", "2nd shows the inverses")
        calc.tap("C")
        calc.tap("2nd")
        clipboard.setText("5 km in miles\n")
        key(Qt.Key_V, "v", Qt.ControlModifier)
        when(() => calc.calc.typed === "5 km in miles", pasted, "Ctrl+V pastes")
      }, "the answer in radians")
    }, "sin(30) is answered")
  }

  function pasted() {
    check(lines(callsFile)[1] === "wl-paste --no-newline --type text", "Ctrl+V asks for text")
    when(() => calc.previewShown, () => {
      check(calc.preview.label === "3.106855961 mi", "a conversion typed as in the menu is worked out as the menu does it")
      calc.recall(calc.history[2])
      check(calc.calc.done && calc.calc.typed === "14" && calc.calc.previous === "2×(3+4)", "a sum of the history clicked comes back")
      calc.showsHistory = true
      calc.save()
      loader.active = false
      loader.active = true
      calc.open("{}")
      check(calc.mode === "scientific" && calc.angle === "rad" && calc.showsHistory && calc.history.length === 3 && calc.calc.typed === "",
        "the next opening has the scientific keys, radians, the history and its sums, and an empty display")
      check(window().implicitWidth > 3 * calc.historyWidth, "and is wider for them")
      key(Qt.Key_Escape, "\u001b")
      check(!window().visible, "Esc with nothing to clear closes it")
      finish()
    }, "the conversion is answered")
  }
}
