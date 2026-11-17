// stub: bin/nova-battery-limit nova-battery-limit
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Commons/ChargeRule.js" as ChargeRule

// The battery's charge as the shell shows it. ChargeRule's cases, as UPower's
// device cannot be faked: a battery plugged in and resting full after its
// charge reads 100%, a limit or a charge short of 95% leaves it as it is.
// Then Charge itself, with no UPower on the bus, as on a desktop: no battery,
// so no limit is read of itself; and the limit read from nova battery limit
// (a stub) as `nova-shell battery limitChanged` asks.
ShellRoot {
  id: test

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  FileView { id: limitFile; path: Quickshell.env("HOME") + "/battery-limit.json"; printErrors: false }
  FileView { id: callsFile; path: Quickshell.env("HOME") + "/stub-calls"; blockLoading: true; printErrors: false }

  function calls() {
    callsFile.reload()
    var text = callsFile.text().trim()
    return text === "" ? [] : text.split("\n")
  }

  function rules() {
    // fraction, plugged, fully-charged, limited
    check(ChargeRule.level(0.99, true, true, false) === 1, "plugged in, charged and no limit, 99% reads full")
    check(ChargeRule.level(0.9896, true, true, false) === 1 && ChargeRule.level(0.949, true, true, false) === 1,
      "as shown in whole percent: 98.96% and 94.9% are 99% and 95%")
    check(ChargeRule.level(0.944, true, true, false) === 0.944, "short of 95% a stopped charge reads as it is")
    check(ChargeRule.level(0.96, true, true, true) === 0.96, "a battery a limit holds reads what it holds")
    check(ChargeRule.level(0.99, true, false, false) === 0.99, "a charge still under way reads as it is")
    check(ChargeRule.level(0.99, false, true, false) === 0.99, "unplugged, the battery's own")
    check(ChargeRule.resting(0.97, true, true, false) && !ChargeRule.resting(0.97, true, true, true),
      "resting is the same rule")
    check(ChargeRule.level(1.2, false, false, false) === 1 && ChargeRule.level(-1, false, false, false) === 0
      && ChargeRule.level(undefined, true, true, false) === 0, "out of range or nothing, kept to 0..1")
  }

  property int step: 0
  property int tries: 0

  // Each step waits up to 5 s for what it asked to land.
  Timer {
    id: poll
    interval: 50
    repeat: true
    onTriggered: test.go()
  }

  function waitFor(ok) {
    if (ok || ++tries >= 100) {
      tries = 0
      return true
    }
    return false
  }

  function go() {
    if (step === 0) {
      // Half a second for a read that should not come.
      if (++tries < 10) return
      tries = 0
      check(!Charge.present && Charge.level === 0 && Charge.percent === 0 && !Charge.resting,
        "with no battery, nothing to show")
      check(calls().length === 0 && !Charge.limited, "nor any limit read")
      Charge.ipc.limitChanged()
      step = 1
    } else if (step === 1) {
      if (!waitFor(calls().length >= 1 && Charge.limited)) return
      check(Charge.limited, "asked, a limit on is read")
      check(JSON.stringify(calls()) === JSON.stringify(["nova-battery-limit --json"]), "from nova battery limit --json")
      limitFile.setText('{"kind":"threshold","limit":100,"on":false}\n')
      Charge.ipc.limitChanged()
      Charge.ipc.limitChanged()
      step = 2
    } else if (step === 2) {
      if (!waitFor(calls().length >= 3 && !Charge.limited)) return
      check(!Charge.limited, "asked again, read again: none")
      check(calls().length === 3, "asked twice while it reads, it reads once more after")
      limitFile.setText("not json\n")
      Charge.readLimit()
      step = 3
    } else if (step === 3) {
      if (!waitFor(calls().length >= 4)) return
      check(!Charge.limited, "an answer it cannot read is no limit")
      poll.stop()
      console.log("DONE")
      Qt.quit()
    }
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    rules()
    limitFile.setText('{"kind":"threshold","limit":80,"on":true}\n')
    // Charge starts here, at its first use.
    Charge.limited
    poll.start()
  })
}
