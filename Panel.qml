import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Battery Life window: what one discharge run cost minute by minute, what
// the last week averaged, and every run long enough to mean something.
//
// Summoned by the shell, from the Omarchy menu or the bar widget:
//   omarchy-shell shell summon andrecmdrgb.batterylife '{}'
//
// It owns no data. Everything on screen comes from one `batterylife json`
// call, so what the window shows and what the CLI prints can never disagree.
Item {
  id: root

  // Injected by omarchy-shell; `service` is this plugin's own sampler.
  property var shell: null
  property var manifest: null
  property var service: null

  readonly property string pluginId: "andrecmdrgb.batterylife"
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/batterylife")).replace(/^file:\/\//, ""))

  property bool closingFromHost: false
  // Named `info` rather than `data`: `data` is QQuickItem's default property,
  // the one children are assigned to, and shadowing it drops them silently.
  property var info: ({})
  property string range: "today"

  readonly property bool weekly: range === "week"
  readonly property var hours: info.hours || []
  readonly property var days: info.days || []
  readonly property var sessions: info.sessions || []
  readonly property var typical: info.typical || ({})
  readonly property var now: info.now || ({})
  readonly property var run: info.run || null

  readonly property int typicalSeconds: Number(typical.seconds || 0)
  readonly property real typicalWatts: Number(typical.watts || 0)
  readonly property int typicalRuns: Number(typical.runs || 0)
  readonly property bool haveHistory: typicalSeconds > 0
  readonly property int shownRuns: Math.min(6, sessions.length)

  // ---- lifecycle ----------------------------------------------------------

  function open(payloadJson) {
    closingFromHost = false
    // `{"range":"week"}` opens straight into the weekly view, so a menu entry
    // or a script can point at either one.
    if (payloadJson) {
      try {
        var payload = JSON.parse(String(payloadJson))
        if (payload && (payload.range === "week" || payload.range === "today"))
          range = payload.range
      } catch (e) {
        // An unparseable payload just means the default view.
      }
    }
    window.visible = true
    refresh()
    Qt.callLater(function () { keys.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  // Closing from inside the window has to tell the shell, or its idea of what
  // is open drifts and the next summon appears to do nothing.
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  function refresh() {
    if (service && typeof service.sample === "function") service.sample()
    loadTimer.restart()
  }

  function load() {
    if (!jsonProc.running) jsonProc.running = true
  }

  Timer {
    id: loadTimer
    interval: 200
    repeat: false
    onTriggered: root.load()
  }

  // Every sample is a free refresh: the window follows the record while it is
  // open without polling on its own.
  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onSampled() { if (window.visible) root.load() }
  }

  Process {
    id: jsonProc
    command: [root.helper, "json", "--days", "7", "--sessions", "12"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text))
          if (parsed && typeof parsed === "object") root.info = parsed
        } catch (e) {
          // A truncated read is not worth blanking the window over.
        }
      }
    }
  }

  // ---- formatting ---------------------------------------------------------

  function formatDuration(seconds) {
    var total = Math.max(0, Math.round(Number(seconds) || 0))
    var h = Math.floor(total / 3600)
    var m = Math.floor((total % 3600) / 60)
    if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
    if (m > 0) return m + "m"
    return total + "s"
  }

  function formatWatts(value) {
    var w = Number(value || 0)
    return (w >= 10 ? w.toFixed(1) : w.toFixed(2)) + " W"
  }

  function clockOf(epoch) {
    var d = new Date(Number(epoch || 0) * 1000)
    return Qt.formatDateTime(d, "HH:mm")
  }

  function dayOf(epoch) {
    var d = new Date(Number(epoch || 0) * 1000)
    return Qt.formatDateTime(d, "ddd d MMM")
  }

  readonly property string headline: haveHistory ? formatDuration(typicalSeconds) : "—"

  readonly property string subtitle: {
    if (!haveHistory)
      return "not enough history yet — runtime appears after a discharge run or two"
    return "a full charge at " + formatWatts(typicalWatts)
      + "  ·  measured over " + typicalRuns + (typicalRuns === 1 ? " run" : " runs")
  }

  // ---- window -------------------------------------------------------------

  FloatingWindow {
    id: window
    title: "Battery Life"
    color: Color.background
    implicitWidth: Style.space(560)
    implicitHeight: Style.space(640)
    minimumSize: Qt.size(Style.space(440), Style.space(500))

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        switch (event.key) {
        case Qt.Key_Escape:
          root.requestClose()
          event.accepted = true
          break
        case Qt.Key_Left:
        case Qt.Key_Right:
        case Qt.Key_Tab:
          root.range = root.weekly ? "today" : "week"
          event.accepted = true
          break
        case Qt.Key_T:
          root.range = "today"
          event.accepted = true
          break
        case Qt.Key_W:
          root.range = "week"
          event.accepted = true
          break
        case Qt.Key_R:
          root.refresh()
          event.accepted = true
          break
        }
      }

      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(22)
        spacing: Style.space(16)

        // ---- header ---------------------------------------------------
        Item {
          width: parent.width
          implicitHeight: Math.max(titleBlock.implicitHeight, rangePicker.implicitHeight)

          Column {
            id: titleBlock
            anchors.left: parent.left
            anchors.top: parent.top
            spacing: Style.space(2)

            Text {
              text: "BATTERY LIFE"
              color: Color.foreground
              opacity: 0.45
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              text: root.headline
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
            }

            Text {
              width: Math.max(1, titleBlock.parent.width - rangePicker.width - Style.space(16))
              wrapMode: Text.WordWrap
              text: root.subtitle
              color: Color.foreground
              opacity: 0.5
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          ButtonGroup {
            id: rangePicker
            anchors.right: parent.right
            anchors.top: parent.top
            value: root.range
            options: [
              { label: "Today", value: "today" },
              { label: "Week", value: "week" }
            ]
            foreground: Color.foreground
            background: Color.background
            accent: Color.accent
            fontFamily: Style.font.family
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function (value) { root.range = value }
          }
        }

        // ---- chart ----------------------------------------------------
        //
        // One component for both ranges: 24 hours of today, or one bar per
        // day of the week. Every column shares a scale taken from the
        // tallest, so the shape is readable on a quiet day too.
        Item {
          id: chartArea
          width: parent.width
          implicitHeight: Style.space(170)

          // The columns and the scale they are drawn against come out of one
          // binding, deliberately. Held apart, they are two bindings over the
          // same data with no guaranteed order between them: the moment the
          // first reading arrives, a column can be re-evaluated against the
          // scale of the empty chart it replaces — a bar hundreds of times the
          // height of the chart, over the header and out of the window, until
          // the scale catches up a frame later.
          readonly property var chart: {
            var rows = root.weekly ? root.days : root.hours
            var values = []
            for (var i = 0; i < rows.length; i++)
              values.push(Number((root.weekly ? rows[i].watts : rows[i].watts) || 0))
            var peak = 1
            for (var j = 0; j < values.length; j++) peak = Math.max(peak, values[j])
            return { values: values, peak: peak, rows: rows }
          }
          readonly property int columns: chart.values.length
          readonly property real gap: root.weekly ? Style.space(10) : Style.space(3)
          readonly property real columnWidth: columns > 0
            ? Math.max(1, (width - gap * (columns - 1)) / columns)
            : 0
          property int hoveredIndex: -1

          function columnLabel(index) {
            var row = chart.rows[index]
            if (!row) return ""
            var when = root.weekly
              ? row.label + " " + String(row.date).slice(5)
              : (row.hour < 10 ? "0" : "") + row.hour + ":00"
            if (Number(row.awake || 0) <= 0) return when + "  ·  not on battery"
            return when + "  ·  " + root.formatDuration(row.awake) + " on battery"
          }

          // One readout for the whole chart rather than a popup per column:
          // no extra windows, and it cannot fall off the edge.
          Text {
            anchors.right: parent.right
            anchors.top: parent.top
            visible: chartArea.hoveredIndex >= 0 && chartArea.hoveredIndex < chartArea.columns
            text: {
              if (!visible) return ""
              var label = chartArea.columnLabel(chartArea.hoveredIndex)
              var value = chartArea.chart.values[chartArea.hoveredIndex]
              return value > 0 ? label + "  ·  " + root.formatWatts(value) : label
            }
            color: Color.foreground
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.left: parent.left
            anchors.top: parent.top
            visible: chartArea.columns > 0
            text: root.formatWatts(chartArea.chart.peak)
            color: Color.foreground
            opacity: 0.35
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            id: chartRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: Style.space(18)
            anchors.bottom: axisRow.top
            spacing: chartArea.gap

            Repeater {
              model: chartArea.columns

              delegate: Item {
                id: column
                required property int index
                readonly property real value: chartArea.chart.values[index] || 0
                // A share of the track, never more than all of it.
                readonly property real fill: value > 0
                  ? Math.min(1, value / chartArea.chart.peak)
                  : 0
                readonly property bool isNow: root.weekly
                  ? index === chartArea.columns - 1
                  : index === new Date().getHours()

                width: chartArea.columnWidth
                height: chartRow.height

                // The track keeps every column present at full height, so an
                // hour spent plugged in reads as an empty hour and not as a
                // gap in the chart.
                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius > 0 ? Style.space(3) : 0
                  color: Color.foreground
                  opacity: chartArea.hoveredIndex === column.index ? 0.14 : 0.07
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: column.fill > 0
                    ? Math.min(parent.height, Math.max(Style.space(2), parent.height * column.fill))
                    : 0
                  radius: Style.cornerRadius > 0 ? Style.space(3) : 0
                  color: column.isNow ? Color.accent : Color.foreground
                  opacity: column.isNow ? 0.95 : 0.55

                  Behavior on height {
                    NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                  }
                }

                HoverHandler {
                  onHoveredChanged: {
                    if (hovered) chartArea.hoveredIndex = column.index
                    else if (chartArea.hoveredIndex === column.index) chartArea.hoveredIndex = -1
                  }
                }
              }
            }
          }

          Row {
            id: axisRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(16)
            spacing: chartArea.gap

            Repeater {
              model: chartArea.columns

              delegate: Text {
                required property int index
                width: chartArea.columnWidth
                horizontalAlignment: Text.AlignHCenter
                // Weekday initials, or the quarter-day marks — 24 numbers in
                // a row is a ruler, not an axis.
                text: {
                  var row = chartArea.chart.rows[index]
                  if (!row) return ""
                  if (root.weekly) return String(row.label).slice(0, 1)
                  return index % 6 === 0 ? String(row.hour) : ""
                }
                elide: Text.ElideRight
                color: Color.foreground
                opacity: 0.45
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: chartArea.columns === 0
            width: parent.width - Style.space(40)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.weekly
              ? "No time on battery in the last week."
              : "Nothing on battery today yet — the chart fills in as soon as this machine is unplugged."
            color: Color.foreground
            opacity: 0.5
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator {
          foreground: Color.foreground
        }

        // ---- runs -----------------------------------------------------
        PanelSectionHeader {
          text: "DISCHARGE RUNS"
          foreground: Color.foreground
          fontFamily: Style.font.family
        }

        Column {
          width: parent.width
          spacing: Style.space(11)

          Repeater {
            model: root.shownRuns

            delegate: Item {
              id: runRow
              required property int index
              readonly property var session: root.sessions[index]
              // Measured against the longest run on screen, not against a
              // day: the top bar is always full and the rest read against it.
              readonly property real share: {
                var top = 0
                for (var i = 0; i < root.shownRuns; i++)
                  top = Math.max(top, Number(root.sessions[i].awake || 0))
                if (top <= 0 || !session) return 0
                return Math.max(0.02, Number(session.awake || 0) / top)
              }

              width: parent.width
              implicitHeight: whenText.implicitHeight + detailText.implicitHeight + Style.space(11)

              Text {
                id: whenText
                anchors.left: parent.left
                anchors.top: parent.top
                width: parent.width - lengthText.width - Style.space(12)
                elide: Text.ElideRight
                text: runRow.session
                  ? root.dayOf(runRow.session.start) + "  " + root.clockOf(runRow.session.start)
                    + (runRow.session.active ? "  ·  still running" : "")
                  : ""
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                id: lengthText
                anchors.right: parent.right
                anchors.top: parent.top
                text: runRow.session ? root.formatDuration(runRow.session.awake) : ""
                color: runRow.session && runRow.session.active ? Color.accent : Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                id: detailText
                anchors.left: parent.left
                anchors.top: whenText.bottom
                text: runRow.session
                  ? Math.round(runRow.session.startPct) + "% → " + Math.round(runRow.session.endPct) + "%"
                    + "  ·  " + Number(runRow.session.wh).toFixed(1) + " Wh"
                  : ""
                color: Color.foreground
                opacity: 0.5
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              // What that run implies for a full battery — the same number the
              // header averages, run by run, so an unusually cheap or
              // expensive afternoon is visible rather than buried in the mean.
              Text {
                anchors.right: parent.right
                anchors.top: whenText.bottom
                text: runRow.session
                  ? root.formatWatts(runRow.session.watts)
                    + (Number(runRow.session.fullSeconds || 0) > 0
                       ? "  ·  full " + root.formatDuration(runRow.session.fullSeconds) : "")
                  : ""
                color: Color.foreground
                opacity: 0.5
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Style.space(3)
                radius: height / 2
                color: Color.foreground
                opacity: 0.1
              }

              Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                width: parent.width * runRow.share
                height: Style.space(3)
                radius: height / 2
                color: runRow.session && runRow.session.active ? Color.accent : Color.foreground
                opacity: runRow.session && runRow.session.active ? 0.9 : 0.5

                Behavior on width {
                  NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                }
              }
            }
          }

          Text {
            visible: root.sessions.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "No discharge runs recorded yet. Unplug for a few minutes and one will appear here — or run `batterylife import` to seed the last week from UPower's own log."
            color: Color.foreground
            opacity: 0.5
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.sessions.length > root.shownRuns
            text: "+" + (root.sessions.length - root.shownRuns) + " more  ·  batterylife sessions 20"
            color: Color.foreground
            opacity: 0.45
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
        text: "T today · W week · R refresh · Esc close"
        color: Color.foreground
        opacity: 0.35
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
