import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// The optional half of the plugin: a glyph and today's total, and nothing
// else. Everything worth reading is in the window this opens — a bar is the
// wrong place for a chart.
//
// Turning it off (`screentime indicator off`) only hides this. The service
// keeps counting, because it is a separate kind in the same manifest. The
// total is the service's, asked once a minute for every screen's copy.
BarWidget {
  id: root
  widgetId: "nova.screentime"
  // Held only while it shows (its total is in the tooltip too).
  sharedId: indicator ? "nova.screentime" : ""

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/screentime")).replace(/^file:\/\//, ""))
  readonly property string pluginId: "nova.screentime"

  function settingEnabled(name, fallback) {
    var value = setting(name, fallback)
    return value !== false && value !== "false" && value !== 0 && value !== "0"
  }

  readonly property bool indicator: settingEnabled("indicator", true)
  readonly property bool showTotal: settingEnabled("showTotal", true)

  readonly property string total: shared ? shared.total : ""

  function refresh() {
    shared?.refreshTotal()
  }

  function openPanel() {
    if (!openProc.running) openProc.running = true
  }

  // Nothing to say before the first reply.
  visible: indicator && total !== ""
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  Process {
    id: openProc
    command: [root.helper, "open"]
  }

  BarButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showTotal ? "󰥔 " + root.total : "󰥔"
    tip: "Screen time today: " + root.total
    fontSize: Style.font.bodySmall
    onClicked: function (b) {
      if (b === Qt.RightButton) root.refresh()
      else root.openPanel()
    }
  }
}
