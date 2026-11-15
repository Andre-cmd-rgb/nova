import QtQuick
import Quickshell
import "plugins/settings/UndervoltModel.js" as Model

// The Performance page's undervolt in words, from `nova power undervolt
// status --json` objects, and the command its Apply runs.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var off = { core: null, cache: null, state: "off", reason: null, intel: true }
    var both = { core: -70, cache: -70, state: "applied", reason: null, intel: true }
    var each = { core: -80, cache: -70, state: "applied", reason: null, intel: true }
    var held = { core: -70, cache: -70, state: "held", reason: "the computer stopped without shutting down", intel: true }

    check(Model.mv(-80) === "−80 mV" && Model.mv(0) === "None", "a depth, with a real minus, or none")
    check(Model.describe(-70, -70) === "−70 mV on the core and cache", "one depth for both")
    check(Model.describe(-80, -70) === "−80 mV on the core, −70 mV on the cache", "a depth each")
    check(Model.describe(-50, 0) === "−50 mV on the core, none on the cache", "and a plane left alone")

    check(Model.headline(off) === "No undervolt" && Model.headline(null) === "No undervolt", "nothing set")
    check(Model.headline(each) === "−80 mV on the core, −70 mV on the cache", "what is on the CPU")
    check(Model.headline(held) === "Held: −70 mV on the core and cache", "what is held")
    check(Model.detail(held) === "The computer stopped without shutting down.", "and why")
    check(Model.detail(both) === "" && Model.detail(off) === "", "on, or off, needs no words")
    check(Model.detail({ core: -70, cache: -70, state: "pending" }) === "Not on the CPU in this boot.", "set but not on")

    check(!Model.changed(both, -70, -70) && Model.changed(both, -80, -70), "a slider moved off what is set")
    check(!Model.changed(off, 0, 0) && Model.changed(off, -60, -60), "and with nothing set")

    check(JSON.stringify(Model.applyCommand(-80, -70)) === '["nova-power-undervolt","set","-80","-70"]', "Apply sets the core's and the cache's")
    check(JSON.stringify(Model.applyCommand(0, 0)) === '["nova-power-undervolt","off"]', "and both at none turns it off")

    console.log("DONE")
    Qt.quit()
  }
}
