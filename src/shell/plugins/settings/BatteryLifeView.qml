import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Battery Life's place in Settings' Battery page: how long a charge lasts, an
// hour-by-hour or day-by-day chart of the draw, and the last runs on battery.
//
// It owns no data: everything on it comes from one `nova-battery json` call, so the
// page and the CLI can never disagree.
Item {
  id: root

  // Settings' shell, for the plugin's sampler; null in a smoke test.
  property var shell: null
  property var service: null
  // Today or the last week; the picker asks Settings, which owns it.
  property string range: "today"
  signal rangePicked(string range)
  readonly property string helper: "nova-battery"
  // Named `info` rather than `data`: `data` is QQuickItem's default property.
  property var info: ({})

  readonly property bool weekly: range === "week"
  readonly property var hours: info.hours || []
  readonly property var days: info.days || []
  readonly property var sessions: info.sessions || []
  readonly property var typical: info.typical || ({})
  readonly property var now: info.now || ({})
  readonly property var run: info.run || null

  readonly property int atRate: Number(now.atRateSeconds || 0)
  readonly property real nowWatts: Number(now.displayWatts || 0)
  readonly property bool onBattery: String(now.state || "") === "D"
  readonly property bool charging: String(now.state || "") === "C"
  readonly property int typicalSeconds: Number(typical.seconds || 0)
  readonly property real typicalWatts: Number(typical.watts || 0)
  readonly property int typicalRuns: Number(typical.runs || 0)
  readonly property bool haveHistory: typicalSeconds > 0
  readonly property int shownRuns: Math.min(5, sessions.length)

  implicitHeight: content.implicitHeight

  Component.onCompleted: refresh()

  function refresh() {
    root.service = root.shell && typeof root.shell.serviceFor === "function" ? root.shell.serviceFor("nova.batterylife") : null
    if (root.service && typeof root.service.sample === "function") root.service.sample()
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

  // Every sample is a free refresh: the page follows the record while it is
  // open without polling on its own.
  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onSampled() { root.load() }
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
          // A truncated read is not worth blanking the page over.
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

  // "14:03" for a run that started today, "Mon 20:16" for one that did not.
  function startedAt(epoch) {
    var d = new Date(Number(epoch || 0) * 1000)
    var today = new Date()
    var sameDay = d.getFullYear() === today.getFullYear()
      && d.getMonth() === today.getMonth()
      && d.getDate() === today.getDate()
    return Qt.formatDateTime(d, sameDay ? "HH:mm" : "ddd HH:mm")
  }

  function dayOf(epoch) {
    var d = new Date(Number(epoch || 0) * 1000)
    return Qt.formatDateTime(d, "ddd d MMM")
  }

  // What a full charge gives at the rate in force right now. It moves with
  // the machine, which is the point: a terminal and a video are twenty watts
  // apart here, and one pooled number describes neither.
  readonly property string headline: {
    if (atRate > 0) return formatDuration(atRate)
    if (haveHistory) return formatDuration(typicalSeconds)
    return "—"
  }

  readonly property string subtitle: {
    if (atRate <= 0 && !haveHistory)
      return "nothing recorded yet — this fills in once the machine runs on battery"
    var parts = []
    // While charging there is no drain to quote, so the live figure describes
    // the fill instead of pretending to describe a battery that is not
    // draining.
    if (charging && nowWatts > 0) parts.push("charging at " + formatWatts(nowWatts))
    else if (atRate > 0) parts.push("at " + formatWatts(nowWatts) + (onBattery ? " right now" : ""))
    if (haveHistory) parts.push(formatDuration(typicalSeconds) + " typical")
    return parts.join("  ·  ")
  }

  Column {
    id: content
    width: parent.width
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
          text: root.headline
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
        }

        Text {
          width: Math.max(1, titleBlock.parent.width - rangePicker.width - Style.space(16))
          wrapMode: Text.WordWrap
          text: root.subtitle
          color: Commons.Color.foreground
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
        foreground: Commons.Color.foreground
        background: Commons.Color.background
        accent: Commons.Color.accent
        fontFamily: Style.font.family
        fontSize: Style.font.bodySmall
        focusable: false
        onChanged: function (value) { root.rangePicked(value) }
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
      // height of the chart, over the header and off the page, until
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
      // no popups, and it cannot fall off the edge.
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
        color: Commons.Color.foreground
        opacity: 0.7
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.left: parent.left
        anchors.top: parent.top
        visible: chartArea.columns > 0
        text: root.formatWatts(chartArea.chart.peak)
        color: Commons.Color.foreground
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
              color: Commons.Color.foreground
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
              color: column.isNow ? Commons.Color.accent : Commons.Color.foreground
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
            color: Commons.Color.foreground
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
        color: Commons.Color.foreground
        opacity: 0.5
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    // ---- runs -----------------------------------------------------
    //
    // One line each: when it started, the charge it spanned, how long it
    // ran, what it drew. No section header and no bars — four columns of
    // numbers do not need a chart underneath them to be read.
    Column {
      width: parent.width
      spacing: Style.space(9)

      Repeater {
        model: root.shownRuns

        delegate: Row {
          id: runRow
          required property int index
          readonly property var session: root.sessions[index]
          readonly property bool live: !!(session && session.active)

          width: parent.width

          Text {
            width: parent.width * 0.26
            elide: Text.ElideRight
            text: runRow.session ? root.startedAt(runRow.session.start) : ""
            color: Commons.Color.foreground
            opacity: runRow.live ? 1 : 0.75
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width * 0.26
            elide: Text.ElideRight
            text: runRow.session
              ? Math.round(runRow.session.startPct) + "% → " + Math.round(runRow.session.endPct) + "%"
              : ""
            color: Commons.Color.foreground
            opacity: 0.5
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width * 0.24
            horizontalAlignment: Text.AlignRight
            text: runRow.session ? root.formatDuration(runRow.session.awake) : ""
            color: runRow.live ? Commons.Color.accent : Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width * 0.24
            horizontalAlignment: Text.AlignRight
            text: runRow.session ? root.formatWatts(runRow.session.watts) : ""
            color: Commons.Color.foreground
            opacity: 0.5
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      Text {
        visible: root.sessions.length === 0
        width: parent.width
        wrapMode: Text.WordWrap
        text: "No discharge runs yet. One appears here after ten minutes on battery."
        color: Commons.Color.foreground
        opacity: 0.5
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
