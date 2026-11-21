import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// What the mobile data widget (BarWidget.qml) shows, asked once for every
// screen's copy of it, while a copy holds it: the modem's state from the
// sibling CLI, polled while the panel is shut and more often while one is
// open, its text messages read out, and, while there is nothing to poll, the
// radio, ModemManager or /dev listened to instead. The switch's toggle runs
// here too, so that it is made once, whichever copy is clicked.
BarWidgetService {
  id: modem

  // Absolute path to the sibling CLI, resolved from this file's own location
  // so nothing has to be symlinked onto PATH and the plugin keeps working if
  // the directory is renamed. Decoded, because resolvedUrl percent-encodes
  // anything unusual in the path.
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/mobile-data")).replace(/^file:\/\//, ""))

  // Seconds between background polls: the bar entry's "interval", else 10,
  // and never under 2.
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
  // and clears it off the modem — and this service is what runs it, because
  // the plugin has no daemon and nothing else would.
  readonly property bool smsNotifications: {
    var value = setting("smsNotifications", true)
    return value !== false && value !== "false" && value !== 0 && value !== "0"
  }

  property var info: ({})
  readonly property string wwanState: info.state || "absent"
  readonly property bool hwPresent: info.hw === "yes"
  // Switched off for want of a SIM, so out of the bar altogether, until a SIM
  // is seen in the slot (or mobile-data check, from Settings, finds one).
  readonly property bool parked: wwanState === "parked"
  readonly property bool shown: hwPresent && !parked
  readonly property bool connected: wwanState === "connected"
  // The radio is on and something is under way: the modem is booting after a
  // suspend, or a connection is being set up. Mobile data is not off, and a
  // switch sitting in the off position says it is — which is what makes
  // people flip it.
  readonly property bool pending: wwanState === "starting" || wwanState === "connecting"
  readonly property bool live: connected || pending
  // A computer without a modem is hidden from the bar.
  readonly property bool noModem: info.hw === "no" && wwanState === "absent"
  // Parked or with no modem, nothing changes until a radio does or a modem
  // comes, so the modem is not polled then: the service listens for those
  // instead.
  readonly property bool quiet: parked || noModem
  readonly property bool busy: actionProc.running

  // Why the last toggle failed, straight from the CLI. Cleared when one
  // succeeds, and when the link comes up by any other route.
  property string lastError: ""
  property string actionStderr: ""

  // The switch throws on click and shows where we are heading while the CLI
  // call is still in flight, rather than sitting on the stale value.
  property bool desired: false

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

  function toggleData() {
    if (busy) return
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

  onPanelOpenChanged: if (!panelOpen && !backgroundStats) resetStats()

  Process {
    id: statusProc
    command: [modem.helper, "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: modem.updateInfo(text)
    }
  }

  // The verbose feed adds byte counters and an interface-bound ping; the ping
  // can burn its full 1 s timeout, so it is asked for only when someone is
  // watching: an open panel, or backgroundStats keeping the window warm.
  Process {
    id: detailsProc
    command: [modem.helper, "info", "--verbose"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: modem.updateInfo(text)
    }
  }

  // Turning the radio back on re-enumerates the modem, so this can take
  // fifteen seconds or so; `busy` holds the switch in place meanwhile.
  Process {
    id: actionProc
    command: [modem.helper, "toggle"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: modem.actionStderr = text
    }
    // The CLI explains its refusals — no SIM, not registered yet, the modem
    // wants a power cycle. Dropping that on the floor left the switch flicking
    // back with no reason given anywhere but a terminal.
    onExited: function (code) {
      modem.lastError = code === 0 ? "" : modem.firstLine(modem.actionStderr)
      modem.panelOpen ? modem.refreshDetails() : modem.refresh()
    }
  }

  Process {
    id: smsProc
    command: [modem.helper, "sms", "poll"]
  }

  // Its own cadence, and deliberately a slow one. The status poll drops to two
  // seconds while a modem is coming back and the open panel refreshes every
  // 1.5 s; neither is a rate at which to read a message store, and a text
  // message is worth a few seconds' delay and nothing more. Runs whether the
  // panel is open or shut — the notification is the point, not the panel.
  Timer {
    interval: Math.max(modem.pollInterval, 10) * 1000
    // Not while the radio is blocked: messages arrive at the modem, so with
    // mobile data off there is nothing to find and no reason to keep looking.
    // Nor without ModemManager, which is what would read them.
    running: modem.wanted && modem.smsNotifications && modem.shown && modem.wwanState !== "disabled" && modem.wwanState !== "noservice"
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
    interval: (modem.pending ? 2 : modem.pollInterval) * 1000
    running: modem.wanted && !modem.panelOpen && !modem.quiet
    repeat: true
    triggeredOnStart: true
    // hwPresent is false until the first reply lands, so the poll that decides
    // whether to draw the widget at all is always the cheap one: no ping to
    // wait on before the glyph appears, and none at all on a machine with no
    // modem.
    onTriggered: (modem.backgroundStats && modem.hwPresent) ? modem.refreshDetails() : modem.refresh()
  }

  Timer {
    interval: 1500
    running: modem.panelOpen
    repeat: true
    triggeredOnStart: true
    onTriggered: modem.refreshDetails()
  }

  // Quiet, a look is taken when the WWAN radio changes: unblocked, which is
  // `mobile-data check` from Settings bringing a parked modem back, or
  // airplane mode going off, after which `info` blocks a parked one again;
  // or one appearing where there was no modem. The shell's one rfkill watch
  // (Rfkill) is held meanwhile; it says the radios as they are when it
  // starts, and when it already runs they are taken from it, as a parked one
  // still blocked is what is known.
  readonly property bool listening: wanted && quiet

  function heardRadio(change) {
    if (change.type !== Rfkill.wwan) return
    if (noModem || !change.soft) refresh()
  }

  onListeningChanged: {
    if (!listening) {
      Rfkill.release()
      return
    }
    Rfkill.hold()
    const known = Rfkill.switches
    for (const idx in known) heardRadio({ idx: idx, type: known[idx].type, op: 0, soft: known[idx].soft, hard: known[idx].hard })
  }

  Component.onDestruction: if (listening) Rfkill.release()

  Connections {
    target: Rfkill
    enabled: modem.listening
    function onHeard(change) { modem.heardRadio(change) }
  }

  // Parked, the modem is in low power and ModemManager still reads its slot;
  // a SIM put in while the computer runs has it probe the modem afresh, which
  // is heard here, and `info` looks at the slot a few seconds later, once the
  // probe has settled, and half a minute later. A SIM there brings the modem
  // back. ModemManager says nothing more of a modem in low power, so this
  // costs nothing while the slot stays empty. Its signals are the lines that
  // begin with the object's path; gdbus starts with lines of its own.
  Process {
    command: ["gdbus", "monitor", "--system", "--dest", "org.freedesktop.ModemManager1"]
    running: modem.wanted && modem.parked
    stdout: SplitParser {
      onRead: function (line) {
        if (String(line).charAt(0) !== "/") return
        plugSoon.restart()
        if (!plugLater.running) plugLater.start()
      }
    }
  }

  // A modem with no radio switch of its own, plugged in where there was none,
  // shows as character devices (cdc-wdm0, wwan0mbim0, ttyUSB0): in /dev, and
  // linked in /dev/char once udev has them. FileView watches a path and its
  // folder, so /dev/char is both. ModemManager takes a few seconds to some
  // tens of seconds to probe a modem: it is looked at then, and half a
  // minute later.
  FileView {
    path: modem.wanted && modem.noModem ? "/dev/char" : ""
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: {
      plugSoon.restart()
      plugLater.restart()
    }
  }

  Timer {
    id: plugSoon
    interval: 3000
    onTriggered: modem.refresh()
  }

  Timer {
    id: plugLater
    interval: 30000
    onTriggered: modem.refresh()
  }

  // Held again after a rest, the modem is looked at afresh: quiet, nothing
  // else would look, and it may have changed meanwhile. Let go, the looks
  // still to come are dropped.
  onWantedChanged: {
    if (wanted) {
      refresh()
      return
    }
    plugSoon.stop()
    plugLater.stop()
  }
}
