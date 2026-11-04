import QtQuick
import Quickshell.Io
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
// would refuse with an error.
WidgetButton {
  id: runner

  required property var entry
  readonly property var options: BarModel.entrySettings(entry)
  // What the command last printed, read.
  property var printed: ({ text: "", tooltip: "", active: false })

  function option(name, fallback) {
    var value = options[name]
    return value === undefined || value === null ? fallback : value
  }

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
  tooltipText: printed.tooltip || String(option("tooltip", ""))
  active: printed.active
  keepSpace: option("keepSpace", false) === true
  horizontalMargin: Number(option("horizontalMargin", 7.5))
  verticalPadding: Number(option("verticalPadding", 6))
  fontSize: Number(option("fontSize", 12))

  onPressed: function(which) {
    var key = which === Qt.RightButton ? "onRightClick" : which === Qt.MiddleButton ? "onMiddleClick" : "onClick"
    if (runner.bar) runner.bar.run(String(option(key, "")))
  }

  Process {
    id: job
    command: ["bash", "-lc", String(runner.option("exec", ""))]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: runner.read(text)
    }
  }

  Timer {
    interval: Math.max(1, Number(runner.option("interval", 5))) * 1000
    running: String(runner.option("exec", "")) !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!job.running) job.running = true
  }
}
