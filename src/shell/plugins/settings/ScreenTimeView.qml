import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Screen Time's page in Settings: a day or a week of use, an hour-by-hour or
// day-by-day chart, and the applications that account for it.
//
// It owns no data: everything on it comes from one `nova-screentime json` call, so the
// page and the CLI can never disagree.
Item {
  id: root

  // Settings' shell, for the plugin's sampler; null in a smoke test.
  property var shell: null
  property var service: null
  // Today or the last week; the picker asks Settings, which owns it.
  property string range: "today"
  signal rangePicked(string range)
  readonly property string helper: "nova-screentime"
  // Named `info` rather than `data`: `data` is QQuickItem's default property.
  property var info: ({})

  readonly property bool weekly: range === "week"
  readonly property var days: info.days || []
  readonly property var hours: info.hours || []
  readonly property var apps: (weekly ? info.rangeApps : info.todayApps) || []
  readonly property int totalSeconds: Number((weekly ? info.rangeSeconds : info.todaySeconds) || 0)
  readonly property int goalMinutes: Number(info.goalMinutes || 0)
  readonly property bool overGoal: !weekly && goalMinutes > 0 && totalSeconds > goalMinutes * 60
  readonly property int shownApps: Math.min(7, apps.length)

  implicitHeight: content.implicitHeight

  Component.onCompleted: refresh()
  // Turned on from the switch above it: the counter's service has only just
  // started, and there is a first reading to show.
  onVisibleChanged: if (visible) refresh()

  function refresh() {
    root.service = root.shell && typeof root.shell.serviceFor === "function" ? root.shell.serviceFor("nova.screentime") : null
    if (root.service && typeof root.service.flushNow === "function") root.service.flushNow()
    loadTimer.restart()
  }

  function load() {
    if (!jsonProc.running) jsonProc.running = true
  }

  Timer {
    id: loadTimer
    interval: 150
    repeat: false
    onTriggered: root.load()
  }

  // Every flush is a free refresh: the page follows the counter while it
  // is open without polling on its own.
  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onFlushed() { root.load() }
  }

  Process {
    id: jsonProc
    command: [root.helper, "json", "--days", "7"]
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
    if (h > 0) return h + "h " + m + "m"
    if (m > 0) return m + "m"
    return total + "s"
  }

  readonly property string subtitle: {
    if (weekly) {
      var span = Math.max(1, Number(info.rangeDays || 7))
      return "last " + span + " days · " + formatDuration(totalSeconds / span) + " a day"
    }
    if (goalMinutes > 0) return "today · " + formatDuration(goalMinutes * 60) + " limit"
    return "today"
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
          text: root.formatDuration(root.totalSeconds)
          color: root.overGoal ? Commons.Color.urgent : Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
        }

        Text {
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
    // tallest, so the shape of a day is readable even on a quiet one.
    Item {
      id: chartArea
      width: parent.width
      implicitHeight: Style.space(160)

      // The columns and the scale they are drawn against come out of one
      // binding, deliberately. Held apart, they are two bindings over the
      // same data with no guaranteed order between them: the moment the
      // first reading arrives, a column can be re-evaluated against the
      // scale of the empty chart it replaces — a bar hundreds of times the
      // height of the chart, over the header and off the page, until
      // the scale catches up a frame later.
      readonly property var chart: {
        var values = root.weekly
          ? root.days.map(function (day) { return Number(day.seconds || 0) })
          : root.hours.map(function (value) { return Number(value || 0) })
        var peak = 1
        for (var i = 0; i < values.length; i++) peak = Math.max(peak, values[i])
        return { values: values, peak: peak }
      }
      readonly property int columns: chart.values.length
      readonly property real gap: root.weekly ? Style.space(10) : Style.space(3)
      readonly property real columnWidth: columns > 0
        ? Math.max(1, (width - gap * (columns - 1)) / columns)
        : 0
      property int hoveredIndex: -1

      function columnLabel(index) {
        if (root.weekly) {
          var day = root.days[index]
          return day ? day.label + " " + day.date : ""
        }
        return (index < 10 ? "0" : "") + index + ":00"
      }

      // One readout for the whole chart rather than a popup per column:
      // no popups, and it cannot fall off the edge.
      Text {
        anchors.right: parent.right
        anchors.top: parent.top
        visible: chartArea.hoveredIndex >= 0 && chartArea.hoveredIndex < chartArea.columns
        text: visible
          ? chartArea.columnLabel(chartArea.hoveredIndex) + " · "
            + root.formatDuration(chartArea.chart.values[chartArea.hoveredIndex])
          : ""
        color: Commons.Color.foreground
        opacity: 0.7
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
            // empty hour reads as an empty hour and not as a gap.
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
            // a row is a ruler, not a label.
            text: root.weekly
              ? (root.days[index] ? String(root.days[index].label).slice(0, 1) : "")
              : (index % 6 === 0 ? String(index) : "")
            color: Commons.Color.foreground
            opacity: 0.45
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    PanelSeparator {
      foreground: Commons.Color.foreground
    }

    // ---- applications ---------------------------------------------
    PanelSectionHeader {
      text: "MOST USED"
      foreground: Commons.Color.foreground
      fontFamily: Style.font.family
    }

    Column {
      width: parent.width
      spacing: Style.space(11)

      Repeater {
        model: root.shownApps

        delegate: Item {
          id: appRow
          required property int index
          readonly property var app: root.apps[index]
          readonly property real share: {
            var top = root.apps.length > 0 ? Number(root.apps[0].seconds || 0) : 0
            if (top <= 0 || !app) return 0
            return Math.max(0.02, Number(app.seconds || 0) / top)
          }

          width: parent.width
          implicitHeight: appName.implicitHeight + Style.space(9)

          Text {
            id: appName
            anchors.left: parent.left
            anchors.top: parent.top
            width: parent.width - appTime.width - Style.space(12)
            elide: Text.ElideRight
            text: appRow.app ? appRow.app.name : ""
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            id: appTime
            anchors.right: parent.right
            anchors.top: parent.top
            text: appRow.app ? root.formatDuration(appRow.app.seconds) : ""
            color: Commons.Color.foreground
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(3)
            radius: height / 2
            color: Commons.Color.foreground
            opacity: 0.1
          }

          // Measured against the busiest application, not the total: the
          // first bar is always full and the rest read against it.
          Rectangle {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            width: parent.width * appRow.share
            height: Style.space(3)
            radius: height / 2
            color: appRow.index === 0 ? Commons.Color.accent : Commons.Color.foreground
            opacity: appRow.index === 0 ? 0.9 : 0.5

            Behavior on width {
              NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
            }
          }
        }
      }

      Text {
        visible: root.apps.length === 0
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.weekly
          ? "Nothing recorded in the last week yet."
          : "Nothing recorded today yet — time starts counting as soon as a window has focus."
        color: Commons.Color.foreground
        opacity: 0.5
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        visible: root.apps.length > root.shownApps
        text: "+" + (root.apps.length - root.shownApps) + " more · screentime top 20"
        color: Commons.Color.foreground
        opacity: 0.45
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
