pragma Singleton
import QtQuick
import Quickshell.Bluetooth
import Quickshell.Io

// Bluetooth on or off, as every switch for it shows it: the bar's menu and
// Settings alike. A switch clicked shows what it asked for at once, and keeps
// showing it until BlueZ has it so, which takes seconds when the radio's
// block powered the controller down and it comes back (a ThinkPad's does);
// the rest of the time it shows BlueZ's. nova-bluetooth-power does the
// asking, one call at a time: asked again while one runs, the last asked
// for runs after it. One that fails, or that BlueZ never follows, goes back
// to BlueZ's.
QtObject {
  id: power

  // As BlueZ has it.
  readonly property bool live: !!Bluetooth.defaultAdapter && Bluetooth.defaultAdapter.enabled
  // As last asked for, true or false, while BlueZ has not caught up; null
  // the rest of the time.
  property var asked: null
  // As the switches show it.
  readonly property bool on: asked === null ? live : asked
  // Asked for and not there yet: "on" or "off" on its way, else "".
  readonly property string turning: asked === null || asked === live ? "" : asked ? "on" : "off"

  function set(want) {
    asked = !!want
    late.stop()
    if (!runner.running) runner.go()
  }

  function toggle() { set(!on) }

  // Once nothing runs and BlueZ has what was asked, BlueZ's alone is shown.
  function settle() {
    if (asked !== null && !runner.running && asked === live) {
      asked = null
      late.stop()
    }
  }

  onLiveChanged: settle()

  property Process runner: Process {
    property bool want: false
    // Whether the call running was heard to exit: one that cannot start
    // only stops running.
    property bool heard: true
    function go() {
      want = power.asked
      command = ["nova-bluetooth-power", want ? "on" : "off"]
      heard = false
      running = true
    }
    onExited: function (exitCode) {
      heard = true
      if (power.asked !== null && power.asked !== want) go()
      else if (exitCode !== 0) power.asked = null
      else {
        power.settle()
        if (power.asked !== null) power.late.restart()
      }
    }
    onRunningChanged: {
      if (!running && !heard) {
        heard = true
        power.asked = null
      }
    }
  }

  // BlueZ's word can come a moment after the command is done; this long
  // after, a switch it never followed goes back to what it has.
  property Timer late: Timer {
    interval: 3000
    onTriggered: if (!power.runner.running) power.asked = null
  }
}
