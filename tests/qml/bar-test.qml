import QtQuick
import Quickshell
import "plugins/bar/BarModel.js" as Model

// The bar's centre anchor, the widget the rest of the centre hangs off: as
// shell.json names it, the clock for a name not in the centre (one from
// before a rename), and none when none is named.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var center = [{ id: "nova.indicators" }, { id: "nova.clock", format: "HH:mm" }, { id: "nova.weather" }]
    check(Model.centerAnchor("nova.weather", center) === "nova.weather", "the widget shell.json names")
    check(Model.centerAnchor("old.clock", center) === "nova.clock", "a name not in the centre is the clock")
    check(Model.centerAnchor("old.clock", [{ id: "nova.weather" }]) === "old.clock", "unless the clock is not there either")
    check(Model.centerAnchor("", center) === "" && Model.centerAnchor(undefined, center) === "", "none named is none")

    console.log("DONE")
    Qt.quit()
  }
}
