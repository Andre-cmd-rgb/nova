// stub: bin/nova-bluetooth-power bluetooth-power
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Bluetooth on or off as its switches show it (BluetoothPower): what was
// asked, at once; asked again while a call runs, the last asked for after
// it; back to BlueZ's for a call that fails, and for one BlueZ never
// follows. There is no bus under the test, so BlueZ has no adapter, and
// Bluetooth is off as BlueZ has it; nova-bluetooth-power is a stub.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(got, want, what) {
    const ok = JSON.stringify(got) === JSON.stringify(want)
    check(ok, what + (ok ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // Waits for <done> to hold, then calls <then>; fails <what> after 5 s.
  function when(done, then, what) {
    waiter.done = done
    waiter.then = then
    waiter.what = what
    waiter.left = 100
    waiter.start()
  }

  Timer {
    id: waiter
    property var done: null
    property var then: null
    property string what: ""
    property int left: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (done()) {
        stop()
        then()
      } else if (--left <= 0) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  FileView {
    id: calls
    path: test.home + "/stub-calls"
    printErrors: false
    blockLoading: true
  }

  FileView {
    id: exitCode
    path: test.home + "/bluetooth-power-exit"
    printErrors: false
    blockWrites: true
  }

  // Nothing running, and nothing asked shown.
  function settled() {
    return !BluetoothPower.runner.running && BluetoothPower.asked === null
  }

  function begin() {
    same(BluetoothPower.on, false, "BlueZ has no adapter: off")
    same(BluetoothPower.turning, "", "and nothing on its way")
    BluetoothPower.toggle()
    same(BluetoothPower.on, true, "clicked: on at once")
    same(BluetoothPower.turning, "on", "and on its way")
    BluetoothPower.toggle()
    same(BluetoothPower.on, false, "clicked again before the call is done: off at once")
    when(settled, twice, "the calls run")
  }

  function twice() {
    calls.reload()
    same(calls.text().trim().split("\n"), ["nova-bluetooth-power on", "nova-bluetooth-power off"],
      "on, then off once it is done: the last asked for runs last")
    same(BluetoothPower.on, false, "BlueZ has it off, as asked: off")
    exitCode.setText("1\n")
    BluetoothPower.toggle()
    same(BluetoothPower.on, true, "a call that will fail: on at once all the same")
    when(settled, failed, "the failing call runs")
  }

  function failed() {
    same(BluetoothPower.on, false, "a call that failed: back to BlueZ's")
    exitCode.setText("0\n")
    BluetoothPower.toggle()
    when(() => !BluetoothPower.runner.running, () => {
      same(BluetoothPower.on, true, "the call done, BlueZ not caught up yet: still on")
      when(settled, () => {
        same(BluetoothPower.on, false, "BlueZ never following: back to BlueZ's")
        finish()
      }, "a switch BlueZ never follows goes back")
    }, "the call runs")
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(begin)
}
