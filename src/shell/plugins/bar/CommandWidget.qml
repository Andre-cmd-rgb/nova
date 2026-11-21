import QtQuick
import qs.Commons
import qs.Ui
import "BarModel.js" as BarModel

// A user's widget showing what a command prints, run again every
// <interval> seconds (5 unless set): plain text, or JSON as Waybar takes it,
// {"text", "tooltip", "class"}, where a class of "active" draws it in the
// bar's urgent colour. A click runs onClick, onMiddleClick or onRightClick.
//
// It reads its settings from its own entry, as <options>: the slot hands a
// widget with a `settings` property its settings, which a read-only one
// would refuse with an error. The command is run once for every screen's
// copy, by the bar's <commands> (CommandRuns.qml).
BarButton {
  id: runner

  required property var entry
  readonly property var options: BarModel.entrySettings(entry)
  // What the command last printed, read.
  property var printed: ({ text: "", tooltip: "", active: false })

  function option(name, fallback) {
    var value = options[name]
    return value === undefined || value === null ? fallback : value
  }

  readonly property string exec: String(option("exec", ""))
  readonly property real every: Math.max(1, Number(option("interval", 5)))

  // The run this copy holds, and the bar's runs it is held in.
  property var run: null
  property var runs: null

  function keep() {
    if (run && runs === bar?.commands && run.exec === exec && run.interval === every) return
    if (run) runs.release(runner, run)
    runs = exec !== "" && bar && bar.commands ? bar.commands : null
    run = runs ? runs.hold(runner, exec, every) : null
    if (run && run.output !== "") read(run.output)
  }

  onExecChanged: keep()
  onEveryChanged: keep()
  onBarChanged: keep()
  Component.onCompleted: keep()
  Component.onDestruction: if (run) runs.release(runner, run)

  // <output> as plain text or as JSON; JSON that is not an object (a
  // number, null) is text.
  function read(output) {
    var parsed = Util.parseModuleJson(output)
    var data = parsed !== null && typeof parsed === "object" ? parsed : {}
    var classes = data.class || data.alt || ""
    printed = {
      text: data.text || String(output || "").trim(),
      tooltip: data.tooltip || String(option("tooltip", "")),
      active: classes === "active" || (Array.isArray(classes) && classes.indexOf("active") !== -1)
    }
  }

  text: printed.text || String(option("text", ""))
  tip: printed.tooltip || String(option("tooltip", ""))
  urgent: printed.active
  holdsPlace: option("keepSpace", false) === true
  margin: Number(option("horizontalMargin", 7.5))
  fontSize: Number(option("fontSize", 12))

  onClicked: function(which) {
    var key = which === Qt.RightButton ? "onRightClick" : which === Qt.MiddleButton ? "onMiddleClick" : "onClick"
    if (runner.bar) runner.bar.run(String(option(key, "")))
  }

  Connections {
    target: runner.run
    function onOutputChanged() { runner.read(runner.run.output) }
  }
}
