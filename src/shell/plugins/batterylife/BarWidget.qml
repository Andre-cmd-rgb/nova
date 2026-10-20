import QtQuick
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
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
  moduleName: "nova.batterylife"

  // A target of its own, not the plugin id: the shell summons the `panel`
  // kind — the history window — by plugin id, and two IpcHandlers on one
  // target means one of them is quietly ignored. This one opens the popup,
  // so a keybind can reach it:
  //
  //   nova-shell nova.batterylife.bar toggle
  ipcTarget: "nova.batterylife.bar"

  // Absolute path to the sibling CLI, resolved from this file's own location
  // so nothing has to be symlinked onto PATH and the plugin keeps working if
  // the directory is renamed. Decoded, because resolvedUrl percent-encodes
  // anything unusual in the path.
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/batterylife")).replace(/^file:\/\//, ""))
  readonly property string pluginId: "nova.batterylife"

  // The bar does not inject this, and never did. `shell.qml` hands `service`
  // to *panel* loaders only; `Bar.qml`'s `injectProps` sets `bar`,
  // `moduleName` and `settings` and nothing else. So this stayed null for the
  // widget's whole life, the Connections block below bound to null, and the
  // "every sample is a free refresh" path never ran once — which left the
  // slow fallback timer as the only thing that ever refreshed the bar.
  //
  // The bar does carry the host shell and the host does expose the lookup, so
  // ask for the service rather than waiting to be handed it. `service` is kept
  // so an injected one still wins if the shell ever starts injecting.
  //
  // Resolved, not bound: `serviceFor` is a plain function call, so a binding
  // would keep whatever the answer was the first time it ran and never look
  // again — and the first answer is null. Measured on this machine: the widget
  // asks once before the host has built its services and once after. Ask on
  // every event that could have changed the answer, stop once it is found.
  property var service: null
  property var resolvedSampler: null
  readonly property var sampler: service || resolvedSampler

  function resolveSampler() {
    if (service !== null || resolvedSampler !== null) return
    if (bar && bar.shell && typeof bar.shell.serviceFor === "function")
      resolvedSampler = bar.shell.serviceFor(pluginId)
  }

  onBarChanged: battery.resolveSampler()

  // Named `info`, not `data`, and `chargeState`, not `state`: both of those
  // are properties QQuickItem already has. `data` is its *default* property —
  // the one an item's children are assigned to — so shadowing it with a var
  // silently stops every child below from being added to the item. The widget
  // then loads without an error, reserves a slot the width of an empty label,
  // and paints nothing at all.
  property var info: ({})
  readonly property var now: info.now || ({})
  readonly property var run: info.run || null
  readonly property var typical: info.typical || ({})

  // The record is what every measured figure is built from, and it moves at
  // the sampler's cadence — a minute on battery, five on AC. Charge and state
  // do not have to wait for it: UPower publishes both already, and publishes
  // them on change rather than on a clock. So the glyph and the percentage
  // are live and cost nothing, while everything *measured* still comes from
  // the CLI and still reads the same number the terminal would print.
  //
  // `percentage` is 0..1 here, not 0..100. That is the one trap in it, and it
  // is why this goes through the same Math.round(x * 100) the stock battery
  // service uses rather than being read straight out.
  readonly property var device: UPower.displayDevice
  readonly property bool deviceReady: device !== null && device.isPresent === true

  readonly property string liveState: {
    if (!deviceReady) return ""
    switch (device.state) {
    case UPowerDeviceState.Charging: return "C"
    case UPowerDeviceState.Discharging: return "D"
    case UPowerDeviceState.FullyCharged: return "F"
    case UPowerDeviceState.PendingCharge:
    case UPowerDeviceState.PendingDischarge: return "N"
    default: return ""
    }
  }

  readonly property bool present: deviceReady || info.present === true

  readonly property string chargeState: liveState !== "" ? liveState : String(now.state || "U")
  readonly property bool discharging: chargeState === "D"
  readonly property bool charging: chargeState === "C"
  readonly property real percent: deviceReady
    ? Math.round(Number(device.percentage || 0) * 100)
    : Number(now.percent || 0)
  readonly property real fraction: Math.max(0, Math.min(1, percent / 100))
  // displayWatts, not rateWatts: the CLI keeps the drain estimate and the
  // number to show apart, so a charging battery is never labelled with the
  // average of the discharge runs behind it.
  readonly property real watts: Number(now.displayWatts || 0)
  readonly property int timeLeft: Number(now.timeLeft || 0)
  readonly property int timeToFull: Number(now.timeToFull || 0)
  // What a full charge gives at the rate in force right now, rather than a
  // pooled average — writing in a terminal and watching a video are twenty
  // watts apart on this machine, and one number for both says neither.
  readonly property int atRate: Number(now.atRateSeconds || 0)

  property var profiles: []
  property string activeProfile: ""

  function profileIcon(name) {
    if (name === "power-saver") return "󰌪"
    if (name === "balanced") return "󰊚"
    if (name === "performance") return "󰓅"
    return "󰂄"
  }

  function profileLabel(name) {
    var text = String(name || "")
    if (text === "power-saver") return "Saver"
    return text.charAt(0).toUpperCase() + text.slice(1)
  }

  function setProfile(name) {
    // nova-powerd remembers the choice for the current power source.
    profileProc.command = ["nova-power-profile", "set", String(name)]
    if (!profileProc.running) profileProc.running = true
  }

  function loadProfiles() {
    if (!profilesProc.running) profilesProc.running = true
  }

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.4)
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : Commons.Color.urgent

  readonly property int warnPercent: {
    var value = Number(setting("warnPercent", 15))
    return isFinite(value) ? Math.max(0, Math.min(50, Math.round(value))) : 15
  }
  readonly property bool low: discharging && percent > 0 && percent <= warnPercent

  // The bar draws its open-panel mark at 55% of the slot unless the module
  // says otherwise, which on a padded glyph-plus-text slot lands under the
  // text alone. This one tracks what is actually painted.
  readonly property real openPanelIndicatorWidth: button.vertical ? 0 : Math.ceil(content.implicitWidth)

  // A Panel is a bare Item: it has no implicit size of its own, and the bar
  // lays widgets out by implicitWidth. Without these the slot is zero wide
  // and the widget is placed, loaded, and invisible — with no error anywhere
  // to say so. Nothing to show before the first reading lands, either.
  visible: present
  implicitWidth: present ? button.implicitWidth : 0
  implicitHeight: present ? button.implicitHeight : 0

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
    setReadoutProc.command = ["nova", "bar", "set", battery.pluginId, "readout", next]
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
    var level = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    var chg = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
    var index = Math.max(0, Math.min(9, Math.floor(fraction * 10)))
    if (chargeState === "F") return "󰂅"
    // "Not charging" is plugged in but taking nothing — a charge threshold
    // holding it, usually. The bolt would say current is flowing, so it gets
    // the plain level glyph, which is what the stock widget does too.
    return charging ? chg[index] : level[index]
  }

  readonly property string stateWord: {
    switch (chargeState) {
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
  //
  // The direct fork is the fallback for a shell where the service did not
  // load at all. It is safe to call either way: the CLI keeps a 15 s floor
  // between rows in the same state, so a redundant sample is a no-op rather
  // than a duplicate row skewing the averages behind it.
  function sampleThenRefresh() {
    if (sampler && typeof sampler.sample === "function") sampler.sample()
    else if (!directSampleProc.running) directSampleProc.running = true
    refreshTimer.restart()
    loadProfiles()
  }

  Component.onCompleted: {
    resolveSampler()
    loadProfiles()
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
          if (parsed && typeof parsed === "object") battery.info = parsed
        } catch (e) {
          // A truncated read is not worth blanking the widget over.
        }
      }
    }
  }

  Process { id: openProc; command: [battery.helper, "open"] }

  // Only ever reached when the service did not load; see sampleThenRefresh.
  Process {
    id: directSampleProc
    command: [battery.helper, "sample"]
    onExited: battery.refresh()
  }

  Process {
    id: profilesProc
    command: ["nova-power-profile", "list", "--active-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var names = []
        var active = ""
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split("\t")
          if (!parts[0]) continue
          names.push(parts[0])
          if (parts[1] === "1") active = parts[0]
        }
        if (names.length === 0) return
        battery.profiles = names
        battery.activeProfile = active
      }
    }
  }

  Process {
    id: profileProc
    onExited: battery.loadProfiles()
  }
  Process { id: setReadoutProc; onExited: battery.refresh() }

  Timer {
    id: refreshTimer
    interval: 200
    repeat: false
    onTriggered: battery.refresh()
  }

  // Every sample the service takes is a free refresh, so the widget follows
  // the record instead of polling on a cadence of its own.
  Connections {
    target: battery.sampler
    ignoreUnknownSignals: true
    function onSampled() { battery.refresh() }
  }

  // A read is a 150 ms fork, so it is worth spending on a change and not
  // worth spending on a clock. These are the three changes that move a number
  // this widget shows, and between them they cover everything the old timer
  // was waiting around for.
  //
  // Pulling the plug is the one that was most visible: the estimate and the
  // glyph used to keep the old source's answer for up to two minutes.
  Connections {
    target: UPower
    function onOnBatteryChanged() { battery.sampleThenRefresh() }
  }

  onChargeStateChanged: battery.sampleThenRefresh()
  onPercentChanged: battery.refresh()

  // What is left for a timer is only the figures that age without any of the
  // above moving — the run's own elapsed time, and the estimate drifting as
  // the average behind it fills out. That is a slow thing, so this is a net
  // rather than the mechanism.
  Timer {
    interval: battery.opened ? 10000 : 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      // Costs nothing once resolved, and covers a shell that loaded this
      // widget before it loaded the service.
      battery.resolveSampler()
      battery.refresh()
    }
  }

  // ---- bar ----------------------------------------------------------------

  // The glyph and the readout are drawn separately, because they want
  // different sizes: the glyph at the bar's icon size, so it matches every
  // other status glyph beside it and the stock power widget it replaced, and
  // the readout at label size, so it matches the text widgets it sits next
  // to. A button paints one string in one size, so neither BarIconButton nor
  // a plain WidgetButton label can do both.
  //
  // WidgetButton is still the shell: it registers the click target with the
  // bar, owns the tooltip, and draws the hover and press chrome. Its own
  // label is turned off and the content sits inside it, so the whole slot —
  // glyph and readout alike — stays one click target.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: battery.bar
    labelVisible: false
    // Keyed off the glyph rather than the label, which is now always empty.
    hasVisualContent: battery.icon !== ""
    fixedWidth: button.vertical ? -1 : Math.ceil(content.implicitWidth) + Style.space(9) * 2
    fixedHeight: button.vertical ? Style.bar.iconSlot : -1
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

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: battery.icon
        color: battery.low ? battery.urgent : battery.barForeground
        font.family: battery.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: battery.barText !== "" && !button.vertical
        text: battery.barText
        color: battery.low ? battery.urgent : battery.barForeground
        font.family: battery.fontFamily
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
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
    // Wide enough for three named profile buttons in one row. Naming them
    // beats three bare glyphs someone has to hover to identify, and wrapping
    // them onto two rows for the sake of a narrower panel is not cleaner.
    contentWidth: panel.fittedContentWidth(Style.space(320))
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
        spacing: Style.space(14)

        // Two numbers and a way to change the profile. Everything else this
        // plugin knows — what the run has cost, what it averaged, how many
        // runs are behind the projection — belongs in the window, not in a
        // panel someone opened to glance at the battery.
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

          // Top right, level with the charge: the way out of a small panel
          // belongs in its corner, not at the end of a column of numbers.
          trailingControl: Component {
            PanelActionButton {
              iconText: "󰋚"
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

        Column {
          visible: battery.present
          width: parent.width
          spacing: Style.spacing.labelGap

          Stat {
            width: parent.width
            label: battery.discharging ? "Time left" : "Until full"
            value: battery.estimate
            valueColor: battery.low ? battery.urgent : battery.barForeground
          }

          // Not the pooled average: at this rate, right now. It moves when
          // the machine's load moves, which is the point.
          Stat {
            width: parent.width
            visible: !battery.charging && battery.atRate > 0
            label: "Full charge"
            value: battery.formatDuration(battery.atRate)
          }
        }

        PanelSeparator {
          visible: battery.profiles.length > 0
          foreground: battery.barForeground
        }

        Row {
          id: profileRow
          visible: battery.profiles.length > 0
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: battery.profiles.length > 0
            ? (width - spacing * (battery.profiles.length - 1)) / battery.profiles.length
            : 0

          Repeater {
            model: battery.profiles

            Button {
              required property var modelData
              width: profileRow.cellWidth
              iconText: battery.profileIcon(String(modelData))
              iconSize: Style.font.body
              text: battery.profileLabel(modelData)
              fontSize: Style.font.caption
              foreground: battery.barForeground
              fontFamily: battery.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: battery.activeProfile === modelData
              onClicked: battery.setProfile(modelData)
            }
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
