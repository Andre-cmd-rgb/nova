import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Screen Time in the bar (nova.screentime-today): a glyph and today's total,
// and nothing else. Everything worth reading is on its page in Settings,
// which a click opens — a bar is the wrong place for a chart.
//
// It is a plugin of its own, off until switched on in Settings → Menu Bar,
// and it shows only while Screen Time records: the total is the service's
// (nova.screentime), which exists only while it is on. Recording does not
// need this widget, and taking it off the bar records on. The service asks
// the total once a minute for every screen's copy, and only while a copy
// holds it.
BarWidget {
  id: root
  sharedId: "nova.screentime"

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/screentime")).replace(/^file:\/\//, ""))

  function settingEnabled(name, fallback) {
    var value = setting(name, fallback)
    return value !== false && value !== "false" && value !== 0 && value !== "0"
  }

  readonly property bool showTotal: settingEnabled("showTotal", true)

  readonly property string total: shared ? shared.total : ""

  function refresh() {
    shared?.refreshTotal()
  }

  function openPanel() {
    if (!openProc.running) openProc.running = true
  }

  // Nothing to say before the first reply, nor while Screen Time is off.
  visible: total !== ""
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
