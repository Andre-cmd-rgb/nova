import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.Ui
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model
import "../../settings" as Settings

// The network's bar widget and its panel: the link the computer is on, its
// traffic and ping, the Wi-Fi band, the DNS provider, and the networks in
// reach to join, leave or forget.
//
// NetworkManager is read through Quickshell.Networking, and Wi-Fi is acted
// on through it; nova-network-status reports the link, nova-network-band the
// band, and nova-dns the DNS. One cursor runs through the panel, moved by
// the keys and by the pointer alike, from the radio's switch down through
// the band and the DNS to the networks.
//
// Ui.Panel is named with its module: qmllint cannot see qs.Ui, so a bare
// Panel would be read as this file, which then holds itself through its
// inline components without end.
Ui.Panel {
  id: root
  moduleName: "nova.network"
  ipcTarget: "nova.network"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------------------------------------------------------- NetworkManager

  readonly property bool managed: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var devices: Networking.devices ? Networking.devices.values : []
  readonly property var radio: device(DeviceType.Wifi)
  readonly property var port: device(DeviceType.Wired)
  readonly property var inReach: radio && radio.networks ? radio.networks.values : []
  readonly property var joined: inReach.find(function(network) { return network && network.connected }) || null

  // Wired wins when both are up: it is the device the default route takes.
  readonly property string kind: port && port.connected ? "ethernet" : joined ? "wifi" : "disconnected"
  readonly property int strength: joined ? Math.round((joined.signalStrength || 0) * 100) : -1
  readonly property string glyph: Model.linkGlyph(kind, strength)

  // The radio's switch is there only when there is a radio: on a wired
  // machine it would read "off" beside a live link.
  readonly property bool canToggleWifi: managed && !!radio

  // The device of a type, a connected one first: a machine may have an idle
  // port beside the one in use, and the first listed may be the idle one.
  function device(type) {
    var idle = null
    for (var i = 0; i < devices.length; i++) {
      var each = devices[i]
      if (!each || each.type !== type) continue
      if (each.connected) return each
      if (!idle) idle = each
    }
    return idle
  }

  function network(ssid) {
    return inReach.find(function(each) { return each && each.name === ssid }) || null
  }

  function toggleNetwork() {
    if (!managed) return
    Networking.wifiEnabled = !Networking.wifiEnabled
    Qt.callLater(function() { root.refresh(true) })
  }

  // ---------------------------------------------------------------- the link

  // nova-network-status's last reading: iface, type, ip, gateway, ssid,
  // speed, the byte counters and the pings.
  property var info: ({})
  property var traffic: ({})
  property var ping: ({ iface: "", samples: [] })
  readonly property bool pinged: ping.samples.length > 0
  readonly property real pingMs: Model.pingTime(ping.samples)
  readonly property int pingLoss: Model.pingLoss(ping.samples)
  // The rows below the title stay whether or not a reading is in, so that one
  // coming in does not move the panel; "--" until then.
  readonly property bool counted: info.rx_bytes !== undefined

  // Under the title, while there is a link, a phrase that changes every few
  // seconds.
  readonly property var phrases: ["Wiring bits", "Handling packets", "Sorting frames", "Hauling bytes", "Routing crumbs", "Counting collisions", "Bending light"]
  property int phrase: 0
  readonly property bool linked: info.type === "ethernet" || (info.type === "wifi" && !!joined)

  function read(text) {
    var fields = Model.readFields(text)
    // A band change takes the link down and up again, and in between there
    // is no route to report. The last reading stands until the link is back,
    // rather than the panel emptying mid-change; with no change asked for,
    // a link gone is shown gone.
    if (bandBusy && !fields.iface) return
    info = fields
    traffic = Model.traffic(traffic, fields, Date.now() / 1000)
    ping = Model.pings(ping, fields)
  }

  onInfoChanged: {
    if (linked) return
    phraseSwap.stop()
    meta.opacity = 1
  }

  function copy(value) {
    if (!value || !bar) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
  }

  // -------------------------------------------------------------- Wi-Fi band

  // From nova-network-band: the band the radio is on, the one pinned
  // ("auto" for none), and those the network answers on. While a pin is
  // being made, the panel shows the one asked for; the command's answer
  // decides what stays.
  property string bandCurrent: ""
  property string bandSelected: "auto"
  property var bands: []
  property string pendingBand: ""
  readonly property bool bandBusy: pendingBand !== ""
  readonly property string bandShown: bandBusy ? pendingBand : bandSelected
  readonly property bool bandPinned: bandShown !== "auto"
  // On Wi-Fi, with bands to choose from or a pin to undo. It stays through
  // the reconnect a pin causes, when the link is briefly not Wi-Fi.
  readonly property bool canSelectBand: (kind === "wifi" || bandBusy) && (bands.length > 1 || bandPinned)
  // Under Automatic there is nothing to choose, and the pills fold away.
  readonly property bool pillsShown: canSelectBand && bandPinned

  function readBands(text) {
    var status = Model.readBands(text)
    // Mid-reconnect there is no network to read bands from; as with the
    // link, the last answer stands.
    if (bandBusy && status.available.length === 0) return
    bandCurrent = status.band
    bandSelected = status.selected
    bands = status.available
  }

  function askBands() {
    if (bandProbe.running) return
    bandProbe.command = ["nova-network-band"]
    bandProbe.running = true
  }

  // The panel stays open through the reconnect a pin causes: that is what
  // there is to watch.
  function setBand(band) {
    if (!band || change.running) return
    pendingBand = band
    change.command = ["nova-network-band", band]
    change.running = true
  }

  // Automatic off pins the band the radio is on, which the heading names.
  function toggleAutomatic() {
    if (bandSelected !== "auto") setBand("auto")
    else if (bandCurrent !== "") setBand(bandCurrent)
  }

  // --------------------------------------------------------------------- DNS

  readonly property var dnsChoices: [
    { name: "DHCP", hint: "Use DNS from DHCP" },
    { name: "Cloudflare", hint: "Set DNS to Cloudflare" },
    { name: "Google", hint: "Set DNS to Google" },
    { name: "Custom", hint: "Set custom DNS servers" }
  ]
  property string dnsProvider: ""
  property string pendingDns: ""
  property bool customOpen: false

  function dnsCommand(provider) {
    return provider ? "nova-dns " + Util.shellQuote(provider) : "nova-dns"
  }

  // A preset is set and the panel closes; Custom opens the sheet for the
  // addresses.
  function setDns(provider) {
    if (!bar || !provider || change.running || customDns.busy) return
    customOpen = provider === "Custom"
    if (customOpen) return
    pendingDns = provider
    change.command = ["bash", "-c", dnsCommand(provider)]
    change.running = true
    close()
  }

  // ---------------------------------------------------------------- networks

  // The networks in reach, as plain rows (Model.networkRow says why).
  property var rows: []
  property bool scanning: false

  function syncRows() {
    var next = []
    inReach.forEach(function(each) {
      if (!each) return
      settle(each)
      next.push(Model.networkRow(each))
    })
    rows = Model.sortRows(next)
  }

  function rowIndex(ssid) {
    for (var i = 0; i < rows.length; i++) if (rows[i] && rows[i].ssid === ssid) return i
    return -1
  }

  function asksForSecret(security) {
    return Model.asksForSecret(security, WifiSecurityType.Open, WifiSecurityType.Owe)
  }

  // ConnectionFailReason's values by name, for the model.
  readonly property var failReasons: ({
    NoSecrets: ConnectionFailReason.NoSecrets,
    WifiAuthTimeout: ConnectionFailReason.WifiAuthTimeout,
    WifiNetworkLost: ConnectionFailReason.WifiNetworkLost,
    WifiClientDisconnected: ConnectionFailReason.WifiClientDisconnected,
    WifiClientFailed: ConnectionFailReason.WifiClientFailed
  })

  // One action on a network at a time: a connect, disconnect or forget. Its
  // row says so while it runs, and says why if it fails. An SSID is matched
  // only while there is an action or failure, so that a hidden network,
  // whose SSID is "", never matches the empty defaults.
  property string actionSsid: ""
  property string actionKind: ""
  property string failureSsid: ""
  property string failureReason: ""
  readonly property bool busy: actionKind !== ""

  // The row asking for a passphrase, kept open through scans, and what has
  // been typed into it.
  property string passwordSsid: ""
  property string passwordText: ""
  property string identityText: ""

  function act(kind, network, run) {
    if (busy || !network) return
    actionSsid = network.name || ""
    actionKind = kind
    failureSsid = ""
    failureReason = ""
    run(network)
    // NetworkManager gives up on a wrong saved passphrase after 25 s, and that
    // failure has to find the action still running, so the backstop for an
    // answer that never comes is longer.
    actionTimeout.restart()
  }

  // Ends the action once the network is where it was sent.
  function settle(network) {
    if (!network || !busy || actionSsid !== (network.name || "")) return
    var done = actionKind === "connect" ? network.connected
      : actionKind === "disconnect" ? !network.connected && !network.stateChanging
      : !network.known && !network.stateChanging
    if (!done) return
    actionTimeout.stop()
    if (actionKind === "connect") passwordSsid = ""
    failureSsid = ""
    failureReason = ""
    actionSsid = ""
    actionKind = ""
    refresh()
  }

  function fail(network, reason) {
    if (!network || !busy || actionSsid !== (network.name || "")) return
    actionTimeout.stop()
    failureSsid = actionSsid
    failureReason = Model.failureText(reason, asksForSecret(network.security), failReasons)
    actionSsid = ""
    actionKind = ""
    refresh()
  }

  function connectTo(ssid) {
    act("connect", network(ssid), function(each) { each.connect() })
  }

  function connectWithPassphrase(ssid, passphrase) {
    act("connect", network(ssid), function(each) { each.connectWithPsk(passphrase) })
  }

  function connectEnterprise(ssid, identity, passphrase) {
    act("connect", network(ssid), function() {
      enterprise.secret = passphrase
      enterprise.command = ["bash", "-c", Model.ENTERPRISE_SCRIPT, "nmcli-eap", ssid, identity]
      enterprise.running = true
    })
  }

  // A row may outlive its network; one that no longer has it does nothing,
  // rather than act on another.
  function disconnectFrom(ssid) {
    act("disconnect", network(ssid), function(each) { each.disconnect() })
  }

  function forget(row) {
    act("forget", row ? network(row.ssid) : null, function(each) { each.forget() })
  }

  function openPasswordPrompt(ssid) {
    if (passwordSsid !== ssid) {
      passwordText = ""
      identityText = ""
    }
    passwordSsid = ssid
  }

  function cancelPasswordPrompt() {
    passwordSsid = ""
    passwordText = ""
    identityText = ""
  }

  // What a click on a row does: leave the network it is on, ask for a
  // passphrase it has none for, or join.
  function choose(row) {
    if (row.connected) disconnectFrom(row.ssid)
    else if (asksForSecret(row.security) && !row.known) openPasswordPrompt(row.ssid)
    else connectTo(row.ssid)
  }

  onPasswordSsidChanged: {
    if (passwordSsid !== "" || !opened) return
    passwordText = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // ---------------------------------------------------------------- scanning

  // The radio's scanner is the device's, shared by the bar on every screen
  // and counted by none: each panel turns it on only while it is open, and
  // turns off only the one it turned on, whichever device that was.
  property var scannerOf: null

  function scan(on) {
    var next = opened ? radio : null
    if (scannerOf && scannerOf !== next) scannerOf.scannerEnabled = false
    scannerOf = next
    if (scannerOf) scannerOf.scannerEnabled = on
  }

  Component.onDestruction: if (scannerOf) scannerOf.scannerEnabled = false

  onRadioChanged: {
    scan(true)
    syncRows()
  }

  onInReachChanged: {
    syncRows()
    if (opened) bandSettle.restart()
  }

  // Asks every command again. With `rescan`, the scanner goes off and back on
  // a beat later, so that the open panel lists what is in reach now: the
  // beat lets the panel draw before NetworkManager's flood of networks.
  function refresh(rescan) {
    if (!status.running) status.running = true
    if (!dnsProbe.running) {
      dnsProbe.command = ["bash", "-c", dnsCommand("")]
      dnsProbe.running = true
    }
    askBands()
    if (opened && radio) {
      if (rescan) {
        scanning = true
        scan(false)
        scanRestart.start()
      } else {
        scan(true)
      }
    }
    syncRows()
  }

  Component.onCompleted: refresh()

  // -------------------------------------------------------------- the cursor

  // One spot lit at a time, the keys' and the pointer's alike: the radio's
  // switch ("header"), the band (its Automatic switch, or the pill at
  // bandIndex), the DNS pill at dnsIndex, or the row at selectedIndex (or its
  // Forget mark). The pointer moves the cursor; the items paint it.
  property bool cursorActive: false
  property string focusSection: "dns"
  property int bandIndex: 0
  property bool bandAutoFocused: true
  property int dnsIndex: 0
  property int selectedIndex: -1
  property bool wifiActionFocused: false

  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Commons.Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Commons.Color.accent) : "transparent"

  function clamp(value, last) {
    return Math.max(0, Math.min(last, value))
  }

  function pointAt(section) {
    cursorActive = true
    focusSection = section
  }

  // Up and down run switch, band, DNS, networks, skipping what is not
  // there; the band is the Automatic switch then the pills, when they show.
  function moveCursor(dx, dy) {
    if (!cursorActive) {
      cursorActive = true
      if (dy >= 0) return
    }
    if (dy > 0) {
      if (focusSection === "header") {
        if (canSelectBand) {
          focusSection = "band"
          bandAutoFocused = true
        } else {
          focusSection = "dns"
        }
      } else if (focusSection === "band") {
        if (bandAutoFocused && pillsShown) bandAutoFocused = false
        else focusSection = "dns"
      } else if (focusSection === "dns") {
        if (rows.length > 0) {
          focusSection = "wifi"
          if (selectedIndex < 0) selectedIndex = 0
        }
      } else {
        moveRow(dy)
      }
    } else if (dy < 0) {
      if (focusSection === "band") {
        if (!bandAutoFocused) bandAutoFocused = true
        else if (canToggleWifi) focusSection = "header"
      } else if (focusSection === "dns") {
        if (canSelectBand) {
          focusSection = "band"
          bandAutoFocused = !pillsShown
        } else if (canToggleWifi) {
          focusSection = "header"
        }
      } else if (focusSection === "wifi") {
        if (selectedIndex > 0) {
          moveRow(dy)
        } else {
          focusSection = "dns"
          wifiActionFocused = false
        }
      }
    }
    if (dx === 0) return
    if (focusSection === "band" && !bandAutoFocused) bandIndex = clamp(bandIndex + dx, bands.length - 1)
    else if (focusSection === "dns") dnsIndex = clamp(dnsIndex + dx, dnsChoices.length - 1)
    else if (focusSection === "wifi") moveToForget(dx)
  }

  function moveRow(delta) {
    if (rows.length === 0) {
      selectedIndex = -1
      return
    }
    selectedIndex = selectedIndex < 0 ? (delta > 0 ? 0 : rows.length - 1) : clamp(selectedIndex + delta, rows.length - 1)
    wifiActionFocused = false
  }

  // Right onto a row's Forget mark, where it has one; left back off it.
  function moveToForget(dx) {
    var row = rows[selectedIndex]
    if (selectedIndex < 0 || !row) return
    wifiActionFocused = Model.canForget(row) && dx > 0
  }

  function activateCursor() {
    if (!cursorActive) return
    if (focusSection === "header") {
      if (canToggleWifi) toggleNetwork()
    } else if (focusSection === "band") {
      if (bandAutoFocused) toggleAutomatic()
      else if (bandIndex >= 0 && bandIndex < bands.length) setBand(bands[bandIndex])
    } else if (focusSection === "dns") {
      if (dnsIndex >= 0 && dnsIndex < dnsChoices.length) setDns(dnsChoices[dnsIndex].name)
    } else {
      var row = rows[selectedIndex]
      if (busy || selectedIndex < 0 || !row) return
      if (wifiActionFocused && Model.canForget(row)) forget(row)
      else choose(row)
    }
  }

  // The bands come and go with scans; the cursor keeps to what is there.
  onBandsChanged: if (bandIndex > bands.length - 1) bandIndex = Math.max(0, bands.length - 1)
  onCanSelectBandChanged: {
    if (canSelectBand || focusSection !== "band") return
    focusSection = "dns"
    bandAutoFocused = true
  }
  onPillsShownChanged: if (!pillsShown) bandAutoFocused = true

  // Likewise the rows: an empty list sends the cursor up to the DNS, and an
  // open passphrase keeps it on its row.
  onRowsChanged: {
    if (rows.length === 0) {
      selectedIndex = -1
      wifiActionFocused = false
      if (focusSection === "wifi") focusSection = "dns"
    } else if (passwordSsid !== "") {
      var asking = rowIndex(passwordSsid)
      if (asking >= 0) {
        selectedIndex = asking
        focusSection = "wifi"
      }
    } else if (selectedIndex >= rows.length) {
      selectedIndex = rows.length - 1
    } else if (selectedIndex < 0 && opened) {
      selectedIndex = 0
    }
    if (!Model.canForget(rows[selectedIndex])) wifiActionFocused = false
  }

  // ------------------------------------------------------------- open, close

  function close() {
    controller.hide()
    cancelPasswordPrompt()
  }

  // The panel opens on the first network, or on the DNS with none; the
  // cursor shows once a key or the pointer moves it.
  onOpenedChanged: {
    if (opened) {
      refresh(true)
      selectedIndex = rows.length > 0 ? 0 : -1
      wifiActionFocused = false
      focusSection = rows.length > 0 ? "wifi" : "dns"
      dnsIndex = Math.max(0, dnsChoices.findIndex(function(choice) { return choice.name === dnsProvider }))
      bandIndex = Math.max(0, bands.indexOf(bandSelected))
      bandAutoFocused = !pillsShown
      cursorActive = false
      return
    }
    // A rescan asked for by this open goes with it, or a quick reopen would
    // find the scanner already on.
    scanRestart.stop()
    scanDone.stop()
    scanning = false
    // So that the next open does not work out a rate from a reading taken
    // long before.
    traffic = {}
    ping = { iface: "", samples: [] }
    scan(false)
  }

  // --------------------------------------------------------------- processes

  Process {
    id: status
    command: ["nova-network-status", "--verbose"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.read(text)
    }
  }

  Process {
    id: dnsProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.dnsProvider = text.trim() || "DHCP"
    }
  }

  Process {
    id: bandProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readBands(text)
    }
  }

  // A pin or a DNS preset. Its answer decides what the panel shows: a
  // refused one leaves what is in force.
  Process {
    id: change
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (root.pendingDns !== "") {
        if (exitCode === 0) root.dnsProvider = root.pendingDns
        root.pendingDns = ""
      }
      if (root.pendingBand !== "") {
        if (exitCode === 0) root.bandSelected = root.pendingBand
        root.pendingBand = ""
        root.refresh()
      }
    }
  }

  // The WPA Enterprise join (Model.ENTERPRISE_SCRIPT), the password on stdin.
  Process {
    id: enterprise
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
  }

  // The link is read every 1.5 s while the panel is open, so the title
  // follows NetworkManager as a connection comes up.
  Timer {
    interval: 1500
    repeat: true
    running: root.opened
    onTriggered: if (!status.running) status.running = true
  }

  Timer {
    id: scanRestart
    interval: 100
    onTriggered: {
      if (!root.opened || !root.radio) return
      root.scan(true)
      scanDone.start()
    }
  }

  // "SCANNING WI-FI…" shows until the scan this open started is done.
  Timer {
    id: scanDone
    interval: 1500
    onTriggered: {
      root.scanning = false
      root.syncRows()
    }
  }

  // The bands change with the link, or with a scan that finds the network
  // on another; nova-network-band runs nmcli several times, so it is asked
  // a second after either, and every 15 s besides.
  readonly property string bandLink: String(info.ssid || "") + "\t" + String(info.freq || "")
  onBandLinkChanged: if (opened) bandSettle.restart()

  Timer {
    id: bandSettle
    interval: 1000
    onTriggered: if (root.opened) root.askBands()
  }

  Timer {
    interval: 15000
    repeat: true
    running: root.opened
    onTriggered: root.askBands()
  }

  // A network that never answers: its row says the action timed out.
  Timer {
    id: actionTimeout
    interval: 30000
    onTriggered: {
      if (!root.busy) return
      root.failureSsid = root.actionSsid
      root.failureReason = root.actionKind === "connect" ? "Timed out connecting"
        : root.actionKind === "disconnect" ? "Timed out disconnecting" : "Timed out forgetting"
      root.actionSsid = ""
      root.actionKind = ""
      root.refresh()
    }
  }

  Timer {
    interval: 2800
    repeat: true
    running: root.opened && root.linked
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation { target: meta; property: "opacity"; to: 0; duration: 180; easing.type: Easing.OutQuad }
    ScriptAction { script: root.phrase = (root.phrase + 1) % root.phrases.length }
    PropertyAnimation { target: meta; property: "opacity"; to: 1; duration: 260; easing.type: Easing.InQuad }
  }

  // ----------------------------------------------------------------- the bar

  // A click opens the panel; opening rescans, a beat after the panel shows.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    onPressed: function(which) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  // --------------------------------------------------------------- the panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    // The keys: hjkl and the arrows move, Enter and Space act, r reads
    // everything again, w switches the radio. A passphrase being typed
    // takes them all.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.passwordSsid !== ""
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "w" || t === "W") root.toggleNetwork()
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // The link: its glyph, its name with the cable's speed, the phrase,
        // and the radio's switch.
        Item {
          width: parent.width
          implicitHeight: Math.max(heroGlyph.implicitHeight, heroText.implicitHeight, root.canToggleWifi ? radioSwitch.implicitHeight : 0)

          Text {
            id: heroGlyph
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.glyph
            color: root.bar.foreground
            opacity: root.managed ? 1 : 0.5
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
          }

          ToggleSwitch {
            id: radioSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.canToggleWifi
            checked: Networking.wifiEnabled
            hasCursor: root.cursorActive && root.focusSection === "header" && root.canToggleWifi
            foreground: root.bar.foreground
            onHovered: function(on) { if (on) root.pointAt("header") }
            onToggled: root.toggleNetwork()

            PanelToolTip {
              visible: radioSwitch.containsMouse
              text: Networking.wifiEnabled ? "Turn Wi-Fi off" : "Turn Wi-Fi on"
              fontFamily: root.bar.fontFamily
            }
          }

          Column {
            id: heroText
            anchors.left: heroGlyph.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: root.canToggleWifi ? radioSwitch.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              readonly property string name: root.info.type === "wifi" ? root.info.ssid || "Wi-Fi"
                : root.info.type === "ethernet" ? "Ethernet"
                : root.info.iface || (root.kind === "disconnected" ? "Disconnected" : "No connection")
              readonly property string speed: Model.linkSpeed(root.info)
              width: parent.width
              textFormat: Text.PlainText
              text: speed !== "" ? name + " (" + speed + ")" : name
              color: root.bar.foreground
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              id: meta
              width: parent.width
              visible: text !== ""
              textFormat: Text.PlainText
              text: root.linked ? root.phrases[root.phrase % root.phrases.length].toUpperCase()
                : root.kind === "disconnected" ? "NOT CONNECTED" : ""
              color: Qt.darker(root.bar.foreground, 1.4)
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }
        }

        // Traffic and ping, then the addresses; the addresses copy on a click.
        GridLayout {
          visible: !!root.info.iface
          width: parent.width
          columns: 4
          columnSpacing: Style.space(20)
          rowSpacing: Style.spacing.labelGap

          StatName { text: "Ping" }
          StatValue {
            text: Model.pingText(root.pingMs, root.pinged)
            color: root.pingLoss > 0 ? root.bar.urgent : root.bar.foreground
          }
          StatName { text: "Packet Loss" }
          StatValue {
            text: Model.lossText(root.pingLoss, root.pinged)
            color: root.pingLoss > 0 ? root.bar.urgent : root.bar.foreground
          }

          StatName { text: "Receiving" }
          StatValue { text: root.counted ? Model.rateText(root.traffic.down) : "--" }
          StatName { text: "Sending" }
          StatValue { text: root.counted ? Model.rateText(root.traffic.up) : "--" }

          StatName { text: "Downloaded" }
          StatValue { text: root.counted ? Model.bytesText(parseFloat(root.info.rx_bytes || "0")) : "--" }
          StatName { text: "Uploaded" }
          StatValue { text: root.counted ? Model.bytesText(parseFloat(root.info.tx_bytes || "0")) : "--" }

          StatName { text: "IP Address" }
          StatValue { text: root.info.ip || "--"; copyHint: root.info.ip ? "Copy IP" : "" }
          StatName { text: "Gateway" }
          StatValue { text: root.info.gateway || "--"; copyHint: root.info.gateway ? "Copy gateway" : "" }
        }

        PanelSeparator {
          visible: root.canSelectBand
          foreground: root.bar.foreground
        }

        // The band: its heading with the Automatic switch, then the pills.
        Column {
          visible: root.canSelectBand
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(bandHeading.implicitHeight, automatic.implicitHeight)

            PanelSectionHeader {
              id: bandHeading
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: Model.bandHeading(root.bandShown, root.bandCurrent)
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Row {
              id: automatic
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              PanelSectionHeader {
                id: automaticLabel
                anchors.verticalCenter: parent.verticalCenter
                text: "AUTOMATIC"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              // As tall as the heading's letters, and centred on them: the
              // heading's top padding (room for Nerd Font glyphs) puts its
              // letters below the middle of its box.
              ToggleSwitch {
                id: automaticSwitch
                anchors.verticalCenter: automaticLabel.verticalCenter
                anchors.verticalCenterOffset: Math.round(automaticLabel.topPadding / 2)
                trackHeight: Math.round(automaticLabel.font.pixelSize * 1.2)
                cursorPad: Style.space(3)
                checked: !root.bandPinned
                busy: root.bandBusy
                hasCursor: root.cursorActive && root.focusSection === "band" && root.bandAutoFocused
                foreground: root.bar.foreground
                onToggled: root.toggleAutomatic()
                onHovered: function(on) {
                  if (!on) return
                  root.pointAt("band")
                  root.bandAutoFocused = true
                }

                PanelToolTip {
                  visible: automaticSwitch.containsMouse
                  text: root.bandPinned ? "Let Wi-Fi pick the band" : "Stay on " + Model.bandName(root.bandCurrent)
                  fontFamily: root.bar.fontFamily
                }
              }
            }
          }

          // The pills fold away under Automatic, the rest of the panel
          // sliding up after them; hidden once folded, the column's spacing
          // goes with them.
          Item {
            width: parent.width
            height: root.pillsShown ? pills.implicitHeight : 0
            visible: height > 0
            opacity: root.pillsShown ? 1 : 0
            clip: true

            Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

            Row {
              id: pills
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.bands

                BandPill {
                  required property string modelData
                  required property int index
                  band: modelData
                  slot: index
                  width: (pills.width - pills.spacing * (Math.max(1, root.bands.length) - 1)) / Math.max(1, root.bands.length)
                }
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "DNS PROVIDER"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: dnsPills
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.dnsChoices

              DnsPill {
                required property var modelData
                required property int index
                provider: modelData.name
                tooltipText: modelData.hint
                slot: index
                width: (dnsPills.width - dnsPills.spacing * 3) / 4
              }
            }
          }

          Settings.DnsView {
            id: customDns
            visible: root.customOpen
            title: ""
            onApplied: root.refresh()
          }
        }

        PanelSeparator {
          visible: !!root.radio
          foreground: root.bar.foreground
        }

        PanelSectionHeader {
          visible: !!root.radio && root.scanning
          text: "SCANNING WI-FI…"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        // Held to 240 px, so that a crowded street does not run the panel off
        // the screen; the keys scroll the row they reach into view.
        ListView {
          id: networkList
          visible: !!root.radio
          width: parent.width
          height: Math.min(contentHeight, Style.space(240))
          spacing: Style.space(4)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.radio ? root.rows : []
          currentIndex: root.selectedIndex
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          // A Column leaves a hidden heading out; a height bound to its
          // visibility as well would loop when the list hides a delegate.
          delegate: Column {
            id: entry
            required property var modelData
            required property int index
            readonly property string heading: Model.rowHeading(root.rows, index)
            width: ListView.view.width
            spacing: Style.space(4)

            PanelSectionHeader {
              visible: entry.heading !== ""
              text: entry.heading
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            NetworkRow {
              width: parent.width
              net: entry.modelData
              index: entry.index
            }
          }

          // The touchpad scrolls the list as GTK does.
          TouchpadScroll { flickable: networkList }
        }
      }
    }
  }

  // ------------------------------------------------------------------ pieces

  // A band. Filled is the band the radio is on; bold, the one pinned. Under
  // Automatic only the live band is lit, and once one is pinned the two meet
  // on the same pill.
  component BandPill: Button {
    id: pill
    required property string band
    required property int slot

    text: Model.bandName(band)
    tooltipText: Model.bandHint(band)
    fontSize: Style.font.bodySmall
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    active: root.bandCurrent === band
    selected: root.bandShown === band
    hasCursor: root.cursorActive && root.focusSection === "band" && !root.bandAutoFocused && root.bandIndex === slot

    onClicked: root.setBand(band)
    onHovered: function(on) {
      if (!on) return
      root.pointAt("band")
      root.bandIndex = pill.slot
    }
  }

  // A DNS provider, filled while it is the one in use.
  component DnsPill: Button {
    id: pill
    required property string provider
    required property int slot

    text: provider
    fontSize: Style.font.bodySmall
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    active: root.dnsProvider === provider
    hasCursor: root.cursorActive && root.focusSection === "dns" && root.dnsIndex === slot

    onClicked: root.setDns(provider)
    onHovered: function(on) {
      if (!on) return
      root.pointAt("dns")
      root.dnsIndex = pill.slot
    }
  }

  // A network in reach: its bars, its name and what it is doing, and at the
  // right a lock for one that takes a secret, or a mark to forget a known
  // one (shown on the pointer or the cursor, for one with a lock). A click
  // leaves, joins, or opens the passphrase under the row.
  component NetworkRow: CursorSurface {
    id: row
    required property var net
    required property int index

    readonly property string ssid: net ? net.ssid : ""
    readonly property bool asks: net ? root.asksForSecret(net.security) : false
    readonly property bool enterprise: !!net && (net.security === WifiSecurityType.Wpa2Eap || net.security === WifiSecurityType.WpaEap)
    readonly property bool forgettable: Model.canForget(net)
    readonly property bool selected: root.focusSection === "wifi" && root.selectedIndex === index
    readonly property bool forgetFocused: selected && root.wifiActionFocused && forgettable
    readonly property bool forgetShown: forgettable && (!asks || forgetFocused || forgetMouse.containsMouse)
    readonly property bool acting: root.busy && root.actionSsid === ssid
    readonly property bool failed: root.failureReason !== "" && root.failureSsid === ssid
    readonly property bool asking: root.passwordSsid !== "" && root.passwordSsid === ssid

    readonly property string activity: {
      if (!net || asking) return ""
      if (acting) return root.actionKind === "connect" ? "Connecting…" : root.actionKind === "disconnect" ? "Disconnecting…" : "Forgetting…"
      if (failed) return root.failureReason || "Failed"
      if (net.connected) return Networking.connectivity === NetworkConnectivity.Portal ? "Sign in required" : "Connected"
      return ""
    }
    readonly property color tone: failed ? root.bar.urgent
      : acting || (net && net.connected) ? root.bar.foreground
      : Qt.darker(root.bar.foreground, 1.5)

    hasCursor: root.cursorActive && selected && !root.wifiActionFocused
    current: !!net && net.connected
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: body.implicitHeight + (asking ? prompt.implicitHeight + Style.spacing.md : 0)

    function submit() {
      if (!net || root.busy || root.passwordText.length === 0) return
      if (!enterprise) root.connectWithPassphrase(ssid, root.passwordText)
      else if (root.identityText.length > 0) root.connectEnterprise(ssid, root.identityText, root.passwordText)
    }

    function point(onForget) {
      root.pointAt("wifi")
      root.selectedIndex = row.index
      root.wifiActionFocused = onForget
    }

    // The network's own news. A failure that is not this panel's connect
    // (NetworkManager retrying on its own, say) opens no passphrase.
    Connections {
      target: row.net ? root.network(row.ssid) : null
      function onConnectionFailed(reason) {
        var ours = root.actionKind === "connect" && root.actionSsid === (row.ssid || "")
        root.fail(root.network(row.ssid), reason)
        if (ours && Model.asksAgain(reason, row.asks, root.failReasons)) root.openPasswordPrompt(row.ssid)
      }
      function onConnectedChanged() { if (row.net) root.settle(root.network(row.ssid)) }
      function onKnownChanged() { if (row.net) root.settle(root.network(row.ssid)) }
      function onStateChangingChanged() { if (row.net) root.settle(root.network(row.ssid)) }
    }

    // The pointer moves the cursor here, and leaving does not take it away,
    // so the keys carry on from the row last pointed at.
    MouseArea {
      id: rowMouse
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: body.implicitHeight
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      enabled: !root.busy
      onContainsMouseChanged: if (containsMouse) row.point(false)
      onClicked: {
        if (!row.net) return
        row.point(false)
        root.choose(row.net)
      }
    }

    Item {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(bars.implicitHeight, labels.implicitHeight, mark.implicitHeight) + Style.spacing.rowPaddingX

      Text {
        id: bars
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: row.net ? Model.signalGlyph(row.net.signal) : ""
        color: row.tone
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
      }

      Item {
        id: mark
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: row.asks || row.forgettable
        width: Style.space(22)
        implicitHeight: markGlyph.implicitHeight

        Text {
          id: markGlyph
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          visible: row.asks || row.forgetShown
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: row.forgetShown ? "󰅙" : "󰌾"
          color: row.forgetShown ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        BorderSurface {
          anchors.fill: parent
          z: -1
          visible: row.forgetFocused
          color: Style.hoverFillFor(root.bar.urgent, root.bar.urgent)
          borderSpec: Border.controlSpec("hover-cursor", root.bar.urgent, root.bar.urgent)
          radius: Style.cornerRadius
        }

        MouseArea {
          id: forgetMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
          enabled: row.forgettable && !root.busy
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onContainsMouseChanged: if (containsMouse) row.point(true)
          onClicked: if (row.net) root.forget(row.net)
        }

        PanelToolTip {
          visible: forgetMouse.containsMouse || row.forgetFocused
          text: "Forget network"
          fontFamily: root.bar.fontFamily
        }
      }

      // The bars and the mark carry the signal and the lock, so the second
      // line is only for what the row is doing; without it the row is one
      // line.
      Column {
        id: labels
        anchors.left: bars.right
        anchors.leftMargin: Style.space(10)
        anchors.right: mark.visible ? mark.left : parent.right
        anchors.rightMargin: mark.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: row.net ? (row.ssid || "Hidden") : ""
          color: root.bar.foreground
          elide: Text.ElideRight
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: row.activity !== ""
          textFormat: Text.PlainText
          text: row.activity
          color: row.tone
          elide: Text.ElideRight
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // A failure shows in the prompt for two seconds, then it asks again.
    Timer {
      interval: 2000
      running: row.failed && row.asking
      onTriggered: {
        root.failureSsid = ""
        root.failureReason = ""
        passphrase.forceActiveFocus()
      }
    }

    // The passphrase, and for WPA Enterprise the identity first: Enter or
    // the tick joins, Escape puts it away.
    Item {
      id: prompt
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: rowMouse.bottom
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(4)
      visible: row.asking
      implicitHeight: (identity.visible ? identity.implicitHeight + Style.space(4) : 0) + passphrase.implicitHeight + Style.spacing.rowGap
      height: implicitHeight

      TextField {
        id: identity
        anchors.left: parent.left
        anchors.right: join.left
        anchors.top: parent.top
        anchors.rightMargin: Style.space(6)
        visible: row.enterprise && !row.acting && !row.failed
        enabled: !row.acting
        placeholderText: "Identity (user@domain)"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        text: row.asking ? root.identityText : ""
        onTextChanged: if (row.asking && text !== root.identityText) root.identityText = text
        onAccepted: passphrase.forceActiveFocus()
        Keys.onEscapePressed: root.cancelPasswordPrompt()
        onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
        Component.onCompleted: if (visible) Qt.callLater(forceActiveFocus)
      }

      TextField {
        id: passphrase
        anchors.left: parent.left
        anchors.right: join.left
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.spacing.rowGap / 2
        anchors.rightMargin: Style.space(6)
        visible: !row.acting && !row.failed
        enabled: !row.acting
        password: true
        placeholderText: "Passphrase"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        text: row.asking ? root.passwordText : ""
        onTextChanged: if (row.asking && text !== root.passwordText) root.passwordText = text
        onAccepted: row.submit()
        Keys.onEscapePressed: root.cancelPasswordPrompt()
        onVisibleChanged: if (visible && !row.enterprise) Qt.callLater(forceActiveFocus)
        Component.onCompleted: if (visible && !row.enterprise) Qt.callLater(forceActiveFocus)
      }

      // While the join runs, and for two seconds after it fails, with why:
      // a wrong passphrase, or a network lost, refused or gone quiet.
      BorderSurface {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: Style.spacing.controlHeight
        visible: row.acting || row.failed
        color: Style.normalFillFor(root.bar.foreground)
        borderSpec: Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent)
        radius: Style.cornerRadius

        Text {
          anchors.fill: parent
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: row.failed ? root.failureReason : "Connecting..."
          color: row.failed ? root.bar.urgent : root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // 22 px, under the lock above it.
      PanelActionButton {
        id: join
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !row.acting && !row.failed
        enabled: row.net && passphrase.text.length > 0 && (!row.enterprise || identity.text.length > 0)
        iconText: "󰄬"
        tooltipText: "Connect"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onClicked: row.submit()
      }
    }
  }

  component StatName: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // A reading, right-aligned; with a copyHint, a click copies it.
  component StatValue: Text {
    id: value
    property string copyHint: ""

    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall

    MouseArea {
      id: copyMouse
      anchors.fill: parent
      enabled: value.copyHint !== "" && value.text !== ""
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.copy(value.text)
    }

    PanelToolTip {
      visible: copyMouse.enabled && copyMouse.containsMouse
      text: value.copyHint
      fontFamily: root.bar.fontFamily
    }
  }
}
