import QtQuick
import Quickshell
import "plugins/settings/Readout.js" as Readout

// The Performance page's readout in words, from `nova-power status --json`
// objects: on battery under a tier, plugged in, and with figures missing.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var battery = {
      source: "battery", governor: { tier: "light", busy: 7, temp: 48, fans: "held", watts: 4.62 },
      pl1: 12, pl2: 18, ceiling: 45, turbo: false, boost: false, fanRpm: 0, batteryWatts: 9.87
    }
    check(Readout.processor(battery) === "7% busy, 48 °C, 4.6 W", "the processor: busy, hot, drawing")
    check(Readout.limits(battery) === "Light, for reading and video: 12 W sustained, 18 W in bursts, up to 45% speed, no turbo.", "a battery tier and its limits")
    check(Readout.fans(battery) === "Still, held quiet by the governor", "fans the governor holds still")
    check(Readout.battery(battery) === "9.9 W from the battery", "the whole computer's draw")

    battery.boost = true
    check(Readout.limits(battery).indexOf("A boost has lifted the battery's limits.") > 0, "a boost says so")

    var plugged = {
      source: "ac", governor: { tier: null, busy: 3, temp: 57, fans: "auto", watts: 23.4 },
      pl1: 109, pl2: 135, ceiling: 100, turbo: true, boost: true, fanRpm: 2586, batteryWatts: null
    }
    check(Readout.processor(plugged) === "3% busy, 57 °C, 23 W", "watts past ten lose the decimal")
    check(Readout.limits(plugged) === "Plugged in: 109 W sustained, 135 W in bursts.", "plugged in: the firmware's limits, no boost talk")
    check(Readout.fans(plugged) === "2586 rpm, the firmware's curve", "fans on the firmware's curve")
    check(Readout.battery(plugged) === "", "no battery draw plugged in")

    var sparse = { source: "battery", governor: { tier: "nonsense", busy: 1, temp: null, fans: "?", watts: null },
      pl1: null, pl2: null, ceiling: null, turbo: null, boost: false, fanRpm: null, batteryWatts: 0 }
    check(Readout.processor(sparse) === "1% busy", "a figure missing is left out")
    check(Readout.limits(sparse) === "On battery.", "an unknown tier, no limits")
    check(Readout.fans(sparse) === "", "no fan figures, no fan line")
    check(Readout.battery(sparse) === "", "a battery that reports nothing")
    console.log("DONE")
    Qt.quit()
  }
}
