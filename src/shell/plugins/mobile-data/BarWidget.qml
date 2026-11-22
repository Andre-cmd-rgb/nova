import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Compact mobile-broadband widget: one signal glyph in the bar, and a narrow
// panel holding an on/off switch and read-only stats. The switch sets mobile
// data up the first time; the APN and the SIM's PIN are asked for in Settings,
// and the billing day lives on the `mobile-data` CLI, so the panel stays a
// single column of numbers. What it shows is the plugin's service's
// (Service.qml), asked once for every screen.
Panel {
  id: mobile
  widgetId: "nova.mobile-data"

  // The modem as the plugin's service (Service.qml) has it, one for every
  // screen's copy of the widget: its state, its polls and the switch's
  // toggle are the service's, and each copy shows them.
  sharedId: "nova.mobile-data"
  readonly property var modem: shared

  readonly property var info: modem ? modem.info : ({})
  readonly property string wwanState: modem ? modem.wwanState : "absent"
  readonly property bool shown: !!modem && modem.shown
  readonly property bool managed: info.managed !== "no"
  readonly property bool connected: !!modem && modem.connected
  readonly property bool pending: !!modem && modem.pending
  readonly property bool live: !!modem && modem.live
  readonly property bool busy: !!modem && modem.busy
  readonly property string icon: info.icon || "󰢿"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Commons.Color.quieter(ink, Commons.Color.popups.background, 0.71)
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : Commons.Color.urgent

  // Why the last toggle failed, straight from the CLI.
  readonly property string lastError: modem ? modem.lastError : ""

  // The switch throws on click and shows where we are heading while the CLI
  // call is still in flight, rather than sitting on the stale value.
  readonly property bool desired: !!modem && modem.desired
  readonly property bool switchChecked: busy ? desired : live

  readonly property real downRate: modem ? modem.downRate : 0
  readonly property real upRate: modem ? modem.upRate : 0
  readonly property var pings: modem ? modem.pings : []
  readonly property real ping: modem ? modem.ping : -1
  readonly property bool hasStats: info.rx_bytes !== undefined

  readonly property string metaText: {
    switch (wwanState) {
    case "connected": return (info.operator || "Connected") + (info.tech ? " · " + info.tech : "")
    case "connecting": return "Connecting…"
    case "disconnected": return (info.operator || "Registered") + " — not connected"
    case "searching": return "Searching for network"
    case "nosim": return "No SIM"
    case "locked": return info.unlock === "sim-puk" ? "The SIM is blocked" : "The SIM needs its PIN"
    case "failed": return info.why === "sim-error" ? "The SIM could not be read" : "The modem could not be turned on"
    case "denied": return "The network refused the SIM"
    case "disabled": return "Mobile data off"
    case "noprofile": return "Not set up yet"
    case "absent": return "No modem"
    case "noservice": return "ModemManager is not running"
    case "parked": return "Off — no SIM"
    default: return "Modem starting…"
    }
  }

  // One line, and only when something actually needs doing.
  readonly property string hintText: {
    if (lastError !== "") return lastError
    if (wwanState === "noservice") return "Mobile data needs ModemManager. In a terminal:  sudo systemctl enable --now ModemManager.service"
    if (wwanState === "locked") return info.unlock === "sim-puk" ? "It needs the PUK from your carrier." : "Settings → Mobile Data asks for it."
    if (wwanState === "failed" && info.why === "noenable") return "Mobile data is off, so it stops trying. The switch tries again; Settings → Updates → Check for problems says why."
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
    modem?.refresh()
  }

  function toggleData() {
    modem?.toggleData()
  }

  function formatBytes(bytes) {
    var n = Number(bytes)
    if (!isFinite(n) || n < 0) n = 0
    // Decimal, as a plan's allowance is counted and as the Finder says
    // sizes.
    if (n < 1000) return Math.round(n) + " B"
    if (n < 1e6) return (n / 1e3).toFixed(1) + " KB"
    if (n < 1e9) return (n / 1e6).toFixed(1) + " MB"
    return (n / 1e9).toFixed(2) + " GB"
  }

  function formatRate(bytesPerSec) {
    return formatBytes(bytesPerSec) + "/s"
  }

  function formatPing() {
    if (pings.length === 0) return "--"
    if (ping < 0) return "timeout"
    return ping.toFixed(ping < 10 ? 1 : 0) + " ms"
  }

  visible: shown
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0

  BarIcon {
    id: button
    anchors.fill: parent
    bar: mobile.bar
    glyph: mobile.icon
    // Powered but not carrying traffic reads as a dimmed glyph, matching the
    // disconnected Wi-Fi arc next door.
    opacity: mobile.connected ? 1 : 0.5
    slot: Style.bar.statusSlot
    tip: ""
    onClicked: function (b) {
      if (b === Qt.RightButton) mobile.toggleData()
      else if (b === Qt.MiddleButton) mobile.refresh()
      else mobile.toggle()
    }
  }

  PanelSurface {
    id: panel
    widget: button
    host: mobile
    open: mobile.opened && mobile.shown
    keys: keys
    wantWidth: Style.space(250)
    wantHeight: column.implicitHeight

    PanelKeys {
      id: keys
      anchors.fill: parent
      panel: mobile
      onStruck: function (t) {
        if (t === "t" || t === "T") mobile.toggleData()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHeader {
          glyph: mobile.icon
          dimmed: !mobile.connected
          title: "Mobile Data"
          note: mobile.metaText
          ink: mobile.ink
          family: mobile.fontFamily

          end: ToggleSwitch {
            checked: mobile.switchChecked
            busy: mobile.busy || mobile.pending
            foreground: mobile.ink
            onToggled: mobile.toggleData()
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
          foreground: mobile.ink
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
          color: mobile.lastError !== "" || mobile.wwanState === "noservice" || mobile.wwanState === "failed" ? mobile.urgent : mobile.dim
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
    property color valueColor: mobile.ink

    implicitHeight: Math.max(statLabel.implicitHeight, statValue.implicitHeight)

    Text {
      id: statLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: stat.label
      color: Commons.Color.quieter(mobile.ink, Commons.Color.popups.background, 0.6)
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
