import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// The optional half of the plugin: a glyph and today's total, and nothing
// else. Everything worth reading is in the window this opens — a bar is the
// wrong place for a chart.
//
// Turning it off (`screentime indicator off`) only hides this. The service
// keeps counting, because it is a separate kind in the same manifest.
BarWidget {
  id: root
  moduleName: "andrecmdrgb.screentime"

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/screentime")).replace(/^file:\/\//, ""))
  readonly property string pluginId: "andrecmdrgb.screentime"

  function settingEnabled(name, fallback) {
    var value = setting(name, fallback)
    return value !== false && value !== "false" && value !== 0 && value !== "0"
  }

  readonly property bool indicator: settingEnabled("indicator", true)
  readonly property bool showTotal: settingEnabled("showTotal", true)

  property string total: ""

  function refresh() {
    if (!totalProc.running) totalProc.running = true
  }

  function openPanel() {
    if (!openProc.running) openProc.running = true
  }

  // Nothing to say before the first reply, and a vertical bar has no room for
  // the label — the glyph alone still opens the window.
  visible: indicator && total !== ""
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  Process {
    id: totalProc
    command: [root.helper, "today", "--short"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.total = String(text).trim()
    }
  }

  Process {
    id: openProc
    command: [root.helper, "open"]
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showTotal && !root.vertical ? "󰥔 " + root.total : "󰥔"
    tooltipText: "Screen time today: " + root.total
    fontSize: Style.font.bodySmall
    onPressed: function (b) {
      if (b === Qt.RightButton) root.refresh()
      else root.openPanel()
    }
  }
}
