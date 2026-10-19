import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Compact mobile-broadband widget: one signal glyph in the bar, and a narrow
// panel holding an on/off switch and read-only stats. APN, billing day and
// profile setup live on the `mobile-data` CLI so the panel stays a single
// column of numbers.
//
// The id is deliberately not `root`: PanelHero's own root is called `root`,
// and components declared for its `trailingControl` are instantiated inside
// it. A distinct id removes any question about which one wins.
Panel {
  id: mobile
  moduleName: "andrecmdrgb.mobile-data"
  ipcTarget: "andrecmdrgb.mobile-data"

  // Absolute path to the sibling CLI, resolved from this file's own location
  // so nothing has to be symlinked onto PATH and the plugin keeps working if
  // the directory is renamed. Decoded, because resolvedUrl percent-encodes
  // anything unusual in the path.
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/mobile-data")).replace(/^file:\/\//, ""))

  // Seconds between background polls. Declared in the manifest so the settings
  // panel can offer it; the fallback here is what an entry without the key gets.
  readonly property int pollInterval: {
    var seconds = Number(setting("interval", 10))
    return isFinite(seconds) && seconds > 0 ? Math.max(2, Math.round(seconds)) : 10
  }

  // Keep sampling throughput and latency while the panel is closed, so opening
  // it shows numbers that are already there rather than an empty window filling
  // up in front of you. One echo per poll, and only while connected.
  readonly property bool backgroundStats: {
    var value = setting("backgroundStats", true)
    return value !== false && value !== "false" && value !== 0 && value !== "0"
  }

  // Text messages sit in the modem's own storage until something reads them
  // out. `sms poll` is that something — it files what has arrived, says so,
  // and clears it off the modem — and this widget is what runs it, because the
  // plugin has no daemon and nothing else would.
  readonly property bool smsNotifications: {
    var value = setting("smsNotifications", true)
    return value !== false && value !== "false" && value !== 0 && value !== "0"
  }

  property var info: ({})
  readonly property string wwanState: info.state || "absent"
  readonly property bool hwPresent: info.hw === "yes"
  readonly property bool hasProfile: (info.profile || "") !== ""
  readonly property bool managed: info.managed !== "no"
  readonly property bool connected: wwanState === "connected"
  // The radio is on and something is under way: the modem is booting after a
  // suspend, or a connection is being set up. Mobile data is not off, and a
  // switch sitting in the off position says it is — which is what makes
  // people flip it.
  readonly property bool pending: wwanState === "starting" || wwanState === "connecting"
  readonly property bool live: connected || pending
  readonly property bool busy: actionProc.running
  readonly property string icon: info.icon || "󰢿"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.4)
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : Color.urgent

  // Why the last toggle failed, straight from the CLI. Cleared when one
  // succeeds, and when the link comes up by any other route.
  property string lastError: ""
  property string actionStderr: ""

  // The switch throws on click and shows where we are heading while the CLI
  // call is still in flight, rather than sitting on the stale value.
  property bool desired: false
  readonly property bool switchChecked: busy ? desired : live

  // Throughput is the delta between successive --verbose samples; ping keeps a
  // short rolling average so the number does not jitter every 1.5 s.
  property real prevRx: 0
  property real prevTx: 0
  property real prevAt: 0
  property string prevIface: ""
  property real downRate: 0
  property real upRate: 0
  property var pings: []
  property real ping: -1
  readonly property bool hasStats: info.rx_bytes !== undefined

  readonly property string metaText: {
    switch (wwanState) {
    case "connected": return (info.operator || "Connected") + (info.tech ? " · " + info.tech : "")
    case "connecting": return "Connecting…"
    case "disconnected": return (info.operator || "Registered") + " — not connected"
    case "searching": return "Searching for network"
    case "nosim": return "No SIM"
    case "locked": return "SIM locked — PIN required"
    case "disabled": return "Mobile data off"
    case "noprofile": return "No connection profile"
    case "absent": return "No modem"
    default: return "Modem starting…"
    }
  }

  // One line, and only when something actually needs doing.
  readonly property string hintText: {
    if (lastError !== "") return lastError
    if (!hasProfile) return "No profile yet — run:  mobile-data setup <APN>"
    if (!managed) return "NetworkManager is not managing the modem."
    if (wwanState === "starting") return "The modem restarts itself after sleep — give it half a minute."
    return ""
  }

  readonly property string usedText: formatBytes(parseFloat(info.used_bytes || "0"))

  readonly property string resetText: {
    if (!info.next_reset) return "—"
    var d = new Date(info.next_reset + "T00:00:00")
    if (isNaN(d.getTime())) return "—"
    return Qt.formatDate(d, "MMM d")
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshDetails() {
    if (!detailsProc.running) detailsProc.running = true
  }

  function updateInfo(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq > 0) next[lines[i].slice(0, eq)] = lines[i].slice(eq + 1)
    }
    // A transient empty read must not blink the widget out of the bar.
    if (Object.keys(next).length === 0) return
    updateRates(next)
    info = next
  }

  function updateRates(next) {
    var iface = next.iface || ""
    var now = Date.now() / 1000
    var rx = parseFloat(next.rx_bytes)
    var tx = parseFloat(next.tx_bytes)
    var haveCounters = isFinite(rx) && isFinite(tx)

    // Nothing to measure without a link, and a window carried across an outage
    // would open the panel on a latency from before it.
    if ((next.state || "") !== "connected") {
      resetStats()
      prevIface = iface
      return
    }

    if (!haveCounters || iface !== prevIface || prevAt === 0) {
      // First sample after open, or the modem moved interface — a delta
      // against the old counters would manufacture a spike.
      downRate = 0
      upRate = 0
    } else {
      var dt = now - prevAt
      if (dt > 0) {
        downRate = Math.max(0, (rx - prevRx) / dt)
        upRate = Math.max(0, (tx - prevTx) / dt)
      }
    }
    prevIface = iface
    prevRx = haveCounters ? rx : 0
    prevTx = haveCounters ? tx : 0
    prevAt = haveCounters ? now : 0

    if (next.ping_ms === undefined) return
    var v = parseFloat(next.ping_ms)
    var samples = pings.slice()
    samples.push(isFinite(v) && v >= 0 ? v : null)
    while (samples.length > 5) samples.shift()
    pings = samples

    // Median, not mean. One slow sample — a retransmit at low signal, a
    // radio waking up — would otherwise drag the average for the next five
    // ticks, which reads as latency slowly settling rather than as a single
    // outlier passing through the window.
    var seen = []
    for (var j = 0; j < samples.length; j++) {
      if (typeof samples[j] === "number") seen.push(samples[j])
    }
    seen.sort(function (a, b) { return a - b })
    var mid = seen.length / 2
    ping = seen.length === 0 ? -1
      : seen.length % 2 === 1 ? seen[(seen.length - 1) / 2]
      : (seen[mid - 1] + seen[mid]) / 2
  }

  function resetStats() {
    prevAt = 0
    prevIface = ""
    downRate = 0
    upRate = 0
    pings = []
    ping = -1
  }

  function formatBytes(bytes) {
    var n = Number(bytes)
    if (!isFinite(n) || n < 0) n = 0
    if (n < 1024) return Math.round(n) + " B"
    if (n < 1048576) return (n / 1024).toFixed(1) + " KB"
    if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB"
    return (n / 1073741824).toFixed(2) + " GB"
  }

  function formatRate(bytesPerSec) {
    return formatBytes(bytesPerSec) + "/s"
  }

  function formatPing() {
    if (pings.length === 0) return "--"
    if (ping < 0) return "timeout"
    return ping.toFixed(ping < 10 ? 1 : 0) + " ms"
  }

  function toggleData() {
    if (busy || !hasProfile) return
    lastError = ""
    actionStderr = ""
    desired = !live
    actionProc.running = true
  }

  // "mobile-data: the SIM is locked and needs its PIN" -> the part worth
  // reading. Multi-line output keeps only its first line; the panel has room
  // for a sentence, not a paragraph.
  function firstLine(text) {
    var line = String(text || "").split("\n")[0].trim()
    return line.replace(/^mobile-data:\s*/, "")
  }

  onConnectedChanged: if (connected) lastError = ""

  onOpenedChanged: if (!opened && !backgroundStats) resetStats()

  visible: hwPresent
  implicitWidth: hwPresent ? button.implicitWidth : 0
  implicitHeight: hwPresent ? button.implicitHeight : 0

  Process {
    id: statusProc
    command: [mobile.helper, "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: mobile.updateInfo(text)
    }
  }

  // The verbose feed adds byte counters and an interface-bound ping; the ping
  // can burn its full 1 s timeout, so it is asked for only when someone is
  // watching: an open panel, or backgroundStats keeping the window warm.
  Process {
    id: detailsProc
    command: [mobile.helper, "info", "--verbose"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: mobile.updateInfo(text)
    }
  }

  // Turning the radio back on re-enumerates the modem, so this can take
  // fifteen seconds or so; `busy` holds the switch in place meanwhile.
  Process {
    id: actionProc
    command: [mobile.helper, "toggle"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: mobile.actionStderr = text
    }
    // The CLI explains its refusals — no SIM, not registered yet, the modem
    // wants a power cycle. Dropping that on the floor left the switch flicking
    // back with no reason given anywhere but a terminal.
    onExited: function (code) {
      mobile.lastError = code === 0 ? "" : mobile.firstLine(mobile.actionStderr)
      mobile.opened ? mobile.refreshDetails() : mobile.refresh()
    }
  }

  Process {
    id: smsProc
    command: [mobile.helper, "sms", "poll"]
  }

  // Its own cadence, and deliberately a slow one. The status poll drops to two
  // seconds while a modem is coming back and the open panel refreshes every
  // 1.5 s; neither is a rate at which to read a message store, and a text
  // message is worth a few seconds' delay and nothing more. Runs whether the
  // panel is open or shut — the notification is the point, not the panel.
  Timer {
    interval: Math.max(mobile.pollInterval, 10) * 1000
    // Not while the radio is blocked: messages arrive at the modem, so with
    // mobile data off there is nothing to find and no reason to keep looking.
    running: mobile.smsNotifications && mobile.hwPresent && mobile.wwanState !== "disabled"
    repeat: true
    // So a message that arrived while the shell was down is announced when it
    // comes back up, rather than a poll interval later.
    triggeredOnStart: true
    onTriggered: if (!smsProc.running) smsProc.running = true
  }

  // Background poll for the bar glyph; the open panel has its own cadence.
  // With backgroundStats on this takes the verbose feed as well, so the
  // window is already full by the time the panel opens.
  // While something is settling, watch it closely: the half minute a modem
  // takes to come back after a suspend should not also cost ten seconds of
  // stale glyph at the end of it.
  Timer {
    interval: (mobile.pending ? 2 : mobile.pollInterval) * 1000
    running: !mobile.opened
    repeat: true
    triggeredOnStart: true
    // hwPresent is false until the first reply lands, so the poll that decides
    // whether to draw the widget at all is always the cheap one: no ping to
    // wait on before the glyph appears, and none at all on a machine with no
    // modem.
    onTriggered: (mobile.backgroundStats && mobile.hwPresent) ? mobile.refreshDetails() : mobile.refresh()
  }

  Timer {
    interval: 1500
    running: mobile.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: mobile.refreshDetails()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: mobile.bar
    text: mobile.icon
    // Powered but not carrying traffic reads as a dimmed glyph, matching the
    // disconnected Wi-Fi arc next door.
    opacity: mobile.connected ? 1 : 0.5
    slotSize: Style.bar.statusSlot
    tooltipText: ""
    onPressed: function (b) {
      if (b === Qt.RightButton) mobile.toggleData()
      else if (b === Qt.MiddleButton) mobile.refresh()
      else mobile.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: mobile
    bar: mobile.bar
    open: mobile.opened && mobile.hwPresent
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(250))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: mobile.close()
      onTabRequested: function (direction) {
        mobile.switchPanel(direction)
      }
      onTextKey: function (t) {
        if (t === "t" || t === "T") mobile.toggleData()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          title: "Mobile Data"
          meta: mobile.metaText
          foreground: mobile.barForeground
          fontFamily: mobile.fontFamily
          iconOpacity: mobile.connected ? 1.0 : 0.5

          iconComponent: Component {
            Text {
              text: mobile.icon
              color: mobile.barForeground
              font.family: mobile.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            ToggleSwitch {
              visible: mobile.hasProfile
              checked: mobile.switchChecked
              busy: mobile.busy || mobile.pending
              foreground: mobile.barForeground
              onToggled: mobile.toggleData()
            }
          }
        }

        Column {
          visible: mobile.connected
          width: parent.width
          spacing: Style.spacing.labelGap

          Stat {
            width: parent.width
            label: "Signal"
            value: (mobile.info.signal || "0") + "%"
          }
          Stat {
            width: parent.width
            label: "Ping"
            value: mobile.formatPing()
          }
          Stat {
            width: parent.width
            label: "Down"
            value: mobile.hasStats ? mobile.formatRate(mobile.downRate) : "--"
          }
          Stat {
            width: parent.width
            label: "Up"
            value: mobile.hasStats ? mobile.formatRate(mobile.upRate) : "--"
          }
        }

        PanelSeparator {
          foreground: mobile.barForeground
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          Stat {
            width: parent.width
            label: "Used"
            value: mobile.usedText
          }
          Stat {
            width: parent.width
            label: "Resets"
            value: mobile.resetText
          }
        }

        Text {
          visible: mobile.hintText !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: mobile.hintText
          color: mobile.lastError !== "" ? mobile.urgent : mobile.dim
          font.family: mobile.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  // Label left, value right, one line. Deliberately not a two-column grid:
  // a single column stays legible at 250 px and needs no width arithmetic.
  component Stat: Item {
    id: stat

    property string label: ""
    property string value: ""
    property color valueColor: mobile.barForeground

    implicitHeight: Math.max(statLabel.implicitHeight, statValue.implicitHeight)

    Text {
      id: statLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: stat.label
      color: mobile.barForeground
      opacity: 0.6
      font.family: mobile.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: statValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: stat.value
      color: stat.valueColor
      font.family: mobile.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
