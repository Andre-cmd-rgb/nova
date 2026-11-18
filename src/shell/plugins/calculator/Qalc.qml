import QtQuick
import Quickshell
import Quickshell.Io
import "Calculator.js" as Calculator

// qalc, one sum at a time, for the menu and the Calculator window: ask()
// runs it at once, or, while a sum is being worked out, keeps the one asked
// for to run after it, the latest only. answered() gives each sum run its
// answer (Calculator.answer), null for none, once. qalc starts afresh for
// each sum, in some 30 ms: a sum a key, typed fast, lags no more than a run.
//
// qalc in English with a dot for decimals, whatever the locale, as sums are
// typed so; and with its settings and history in the runtime folder, gone at
// logout, rather than in the home.
Item {
  id: qalc

  // More of qalc's settings, as -set takes them ("angle deg").
  property var settings: []

  signal answered(string sum, var answer)

  function ask(sum) {
    if (run.running) {
      run.next = sum
      return
    }
    run.next = ""
    run.sum = sum
    run.round += 1
    run.said = false
    run.printed = ""
    run.command = Calculator.command(sum, settings)
    run.running = true
  }

  // The sum waiting is not run.
  function drop() {
    run.next = ""
  }

  // The answer to the run of <round>, unless it has had one.
  function tell(round, found) {
    if (round !== run.round || run.said) return
    run.said = true
    answered(run.sum, found)
  }

  function askWaiting() {
    if (run.next && !run.running) ask(run.next)
  }

  Process {
    id: run
    property string sum: ""
    property string printed: ""
    property string next: ""
    // Each run's number, and whether it has been answered.
    property int round: 0
    property bool said: false
    environment: ({ LC_ALL: "C.UTF-8", QALCULATE_USER_DIR: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/calculator" })
    stdout: SplitParser {
      onRead: line => run.printed += line + "\n"
    }
    onExited: function(code, status) {
      qalc.tell(run.round, code === 0 && status === 0 ? Calculator.answer(run.printed, run.sum) : null)
    }
    // One that never started (no qalc) answers nothing, a turn later, once
    // an exit has had its say; then the sum that waited. A run started in
    // between is not this one.
    onRunningChanged: if (!running) {
      const round = run.round
      Qt.callLater(function() {
        qalc.tell(round, null)
        qalc.askWaiting()
      })
    }
  }
}
