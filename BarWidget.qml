import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar entry, and the small panel behind it. Takes the slot the stock
// power widget occupies, and answers the question that one cannot: not "how
// full is the battery" but "how long does it actually last".
//
// Every figure comes from `batterylife json`. Nothing is computed here, so
// the panel and the terminal can never disagree about what a watt is.
//
// The id is deliberately not `root`: PanelHero's own root is called `root`,
// and components declared for its `trailingControl` are instantiated inside
// it. A distinct id removes any question about which one wins.
Panel {
  id: battery
  moduleName: "andrecmdrgb.batterylife"

  // No ipcTarget: this plugin also ships a `panel` kind, and the shell
  // summons that one by plugin id. Two IpcHandlers on one target is one too
  // many, and the popup here has a button rather than a remote control.

  // Absolute path to the sibling CLI, resolved from this file's own location
  // so nothing has to be symlinked onto PATH and the plugin keeps working if
  // the directory is renamed. Decoded, because resolvedUrl percent-encodes
  // anything unusual in the path.
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/batterylife")).replace(/^file:\/\//, ""))
  readonly property string pluginId: "andrecmdrgb.batterylife"

  // Injected by omarchy-shell: this plugin's own sampler.
  property var service: null

  property var data: ({})
  readonly property var now: data.now || ({})
  readonly property var run: data.run || null
  readonly property var typical: data.typical || ({})
  readonly property bool present: data.present === true

  readonly property string state: String(now.state || "U")
  readonly property bool discharging: state === "D"
  readonly property bool charging: state === "C"
  readonly property real percent: Number(now.percent || 0)
  readonly property real fraction: Math.max(0, Math.min(1, percent / 100))
  readonly property real watts: Number(now.rateWatts || 0)
  readonly property int timeLeft: Number(now.timeLeft || 0)
  readonly property int timeToFull: Number(now.timeToFull || 0)

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.4)
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : Color.urgent

  readonly property int warnPercent: {
    var value = Number(setting("warnPercent", 15))
    return isFinite(value) ? Math.max(0, Math.min(50, Math.round(value))) : 15
  }
  readonly property bool low: discharging && percent > 0 && percent <= warnPercent

  // ---- readout ------------------------------------------------------------
  //
  // The stored value is the label the settings panel shows, so what is in
  // shell.json reads as the sentence someone chose rather than as a code.
  readonly property var readouts: ["Time left", "Percent", "Watts", "Percent + watts", "Nothing"]
  readonly property string readout: {
    var value = String(setting("readout", "Time left"))
    return battery.readouts.indexOf(value) >= 0 ? value : "Time left"
  }

  function cycleReadout() {
    var next = battery.readouts[(battery.readouts.indexOf(battery.readout) + 1) % battery.readouts.length]
    setReadoutProc.command = ["omarchy", "bar", "set", battery.pluginId, "readout", next]
    if (!setReadoutProc.running) setReadoutProc.running = true
  }

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
    return (w >= 10 ? w.toFixed(1) : w.toFixed(2)) + "W"
  }

  // The estimate, in words, or nothing while there is no basis for one. An
  // empty string here is the honest answer on a machine that has been plugged
  // in all week — better than a number invented from the last five seconds.
  readonly property string estimate: {
    if (discharging && timeLeft > 0) return formatDuration(timeLeft)
    if (charging && timeToFull > 0) return formatDuration(timeToFull)
    return ""
  }

  readonly property string barText: {
    if (!present) return ""
    switch (readout) {
    case "Percent": return Math.round(percent) + "%"
    case "Watts": return watts > 0 ? formatWatts(watts) : Math.round(percent) + "%"
    case "Percent + watts":
      return Math.round(percent) + "%" + (watts > 0 ? " " + formatWatts(watts) : "")
    case "Nothing": return ""
    default:
      // Time left is the point of this widget, but it needs history behind
      // it. Until there is any, the percentage stands in rather than a zero.
      return estimate !== "" ? estimate : Math.round(percent) + "%"
    }
  }

  readonly property string icon: {
    if (!present) return "󰂑"
    var full = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    var chg = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
    var index = Math.max(0, Math.min(9, Math.floor(fraction * 10)))
    if (state === "F") return "󰂅"
    return charging ? chg[index] : full[index]
  }

  readonly property string stateWord: {
    switch (state) {
    case "D": return "On battery"
    case "C": return "Charging"
    case "F": return "Fully charged"
    case "N": return "Not charging"
    default: return "Battery"
    }
  }

  readonly property string metaText: {
    if (!present) return "No battery"
    var parts = [stateWord]
    if (watts > 0) parts.push(formatWatts(watts))
    return parts.join("  ·  ")
  }

  // ---- data ---------------------------------------------------------------

  function refresh() {
    if (!jsonProc.running) jsonProc.running = true
  }

  // The current minute is still unsampled. Ask for it before reading, so the
  // popup never opens on numbers a minute stale.
  function sampleThenRefresh() {
    if (service && typeof service.sample === "function") service.sample()
    refreshTimer.restart()
  }

  function openHistory() {
    if (!openProc.running) openProc.running = true
  }

  Process {
    id: jsonProc
    command: [battery.helper, "json", "--days", "7", "--sessions", "12"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text))
          if (parsed && typeof parsed === "object") battery.data = parsed
        } catch (e) {
          // A truncated read is not worth blanking the widget over.
        }
      }
    }
  }

  Process { id: openProc; command: [battery.helper, "open"] }
  Process { id: setReadoutProc; onExited: battery.refresh() }

  Timer {
    id: refreshTimer
    interval: 200
    repeat: false
    onTriggered: battery.refresh()
  }

  // Every sample the service takes is a free refresh, so the widget follows
  // the record instead of polling on a cadence of its own. The slow timer is
  // only there for the figures that move without a new sample — the estimate
  // ageing while the machine sits on AC.
  Connections {
    target: battery.service
    ignoreUnknownSignals: true
    function onSampled() { battery.refresh() }
  }

  Timer {
    interval: battery.opened ? 15000 : 120000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: battery.refresh()
  }

  // ---- bar ----------------------------------------------------------------

  // WidgetButton rather than BarIconButton: the icon button sets
  // labelVisible false and paints a glyph in a fixed square slot, so the
  // readout beside the glyph would never be drawn. `vertical` is read off the
  // button, which takes it from the bar — Panel does not carry one.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: battery.bar
    text: battery.barText === "" || button.vertical
      ? battery.icon
      : battery.icon + " " + battery.barText
    foreground: battery.low ? battery.urgent : battery.barForeground
    fontSize: Style.font.bodySmall
    tooltipText: battery.present
      ? Math.round(battery.percent) + "%  ·  " + battery.metaText
        + (battery.estimate !== "" ? "  ·  " + battery.estimate
           + (battery.discharging ? " left" : " to full") : "")
      : "No battery"
    onPressed: function (b) {
      if (b === Qt.RightButton) battery.cycleReadout()
      else if (b === Qt.MiddleButton) battery.openHistory()
      else {
        if (!battery.opened) battery.sampleThenRefresh()
        battery.toggle()
      }
    }
  }

  // ---- popup --------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: battery
    bar: battery.bar
    open: battery.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(260))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: battery.close()
      onTabRequested: function (direction) { battery.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === "h" || t === "H") { battery.openHistory(); battery.close() }
        if (t === "r" || t === "R") battery.sampleThenRefresh()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          title: battery.present ? Math.round(battery.percent) + "%" : "No battery"
          meta: battery.metaText
          foreground: battery.barForeground
          fontFamily: battery.fontFamily

          iconComponent: Component {
            Text {
              text: battery.icon
              color: battery.low ? battery.urgent : battery.barForeground
              font.family: battery.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // What is left, by the measured rate rather than the instantaneous
        // one. The label says which way it is going so the number never has
        // to be read twice.
        Column {
          visible: battery.present && battery.estimate !== ""
          width: parent.width
          spacing: Style.spacing.labelGap

          Stat {
            width: parent.width
            label: battery.discharging ? "Time left" : "Until full"
            value: battery.estimate
            valueColor: battery.low ? battery.urgent : battery.barForeground
          }
        }

        PanelSeparator {
          visible: battery.run !== null
          foreground: battery.barForeground
        }

        // The run in progress. Runtime counts time awake, so a machine that
        // spent the night suspended does not come back claiming fourteen
        // hours of battery life.
        Column {
          visible: battery.run !== null
          width: parent.width
          spacing: Style.spacing.labelGap

          Stat {
            width: parent.width
            label: "This run"
            value: battery.run ? battery.formatDuration(battery.run.awake) : ""
          }
          Stat {
            width: parent.width
            label: "Used"
            value: battery.run
              ? Number(battery.run.wh).toFixed(1) + " Wh from "
                + Math.round(battery.run.startPct) + "%"
              : ""
          }
          Stat {
            width: parent.width
            label: "Average"
            value: battery.run ? battery.formatWatts(battery.run.watts) : ""
          }
        }

        PanelSeparator {
          foreground: battery.barForeground
        }

        // The answer to the question the widget exists for: at the rate this
        // machine has actually been used lately, what does a full charge buy.
        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          Stat {
            width: parent.width
            label: "Full charge"
            value: Number(battery.typical.seconds || 0) > 0
              ? battery.formatDuration(battery.typical.seconds)
              : "not enough history"
          }
          Stat {
            width: parent.width
            visible: Number(battery.typical.seconds || 0) > 0
            label: "Measured over"
            value: Number(battery.typical.runs || 0) + " runs at "
              + battery.formatWatts(battery.typical.watts)
          }
        }

        PanelActionButton {
          anchors.horizontalCenter: parent.horizontalCenter
          iconText: "󰄽"
          tooltipText: "Battery history  (H)"
          foreground: battery.barForeground
          fontFamily: battery.fontFamily
          onClicked: {
            battery.openHistory()
            battery.close()
          }
        }
      }
    }
  }

  // Label left, value right, one line. Deliberately not a two-column grid:
  // a single column stays legible at 260 px and needs no width arithmetic.
  component Stat: Item {
    id: stat

    property string label: ""
    property string value: ""
    property color valueColor: battery.barForeground

    visible: value !== ""
    implicitHeight: visible ? Math.max(statLabel.implicitHeight, statValue.implicitHeight) : 0

    Text {
      id: statLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: stat.label
      color: battery.barForeground
      opacity: 0.6
      font.family: battery.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: statValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: stat.value
      color: stat.valueColor
      font.family: battery.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
