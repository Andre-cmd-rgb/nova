import QtQuick
import QtQuick.Controls
import Quickshell.Io
import Quickshell.Networking
import qs.Ui
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// The network on the bar: its icon is the link the computer is on, Wi-Fi
// with its bars, a cable, or none. A click opens the panel: Wi-Fi's switch,
// the networks in range, which a click joins or leaves (a known one can be
// forgotten), and the way to Settings' Wi-Fi page, which has the rest: the
// addresses, the band and the DNS. w in the panel turns Wi-Fi on or off, as
// does `nova-shell nova.network toggleNetwork`.
//
// NetworkManager is read, and Wi-Fi acted on, through Quickshell.Networking.
// The keys and the pointer move one cursor, from the Wi-Fi switch at the top
// down to the networks and Settings.
//
// Ui.Panel rather than Panel: qmllint cannot see qs.Ui, takes a bare Panel
// for this file, and then finds the file inside itself, through its
// components, without end.
Ui.Panel {
  id: network
  widgetId: "nova.network"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color ink: bar.foreground
  readonly property color dim: Qt.darker(ink, 1.4)
  readonly property color faint: Qt.darker(ink, 1.5)
  readonly property color urgent: bar.urgent
  readonly property string typeface: bar.fontFamily
  // The cursor's fill on a row, and the fill of the network in use.
  readonly property color rowFill: bar ? Style.hoverFillFor(ink, Commons.Color.accent) : "transparent"
  readonly property color inUseFill: bar ? Style.selectedFillFor(ink, Commons.Color.accent) : "transparent"

  // ---- the link ------------------------------------------------------------

  readonly property bool nmRunning: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var hardware: Networking.devices ? Networking.devices.values : []
  readonly property var wireless: deviceOf(DeviceType.Wifi)
  readonly property var wired: deviceOf(DeviceType.Wired)
  readonly property var inRange: wireless && wireless.networks ? wireless.networks.values : []
  readonly property var joined: inRange.find(function(n) { return n && n.connected }) || null
  // A cable that is up wins over Wi-Fi: the default route takes it.
  readonly property string medium: wired && wired.connected ? "ethernet" : joined ? "wifi" : "disconnected"
  readonly property string glyph: Model.linkGlyph(medium, joined ? Model.signalOf(joined) : -1)
  readonly property bool portal: Networking.connectivity === NetworkConnectivity.Portal
  // A switch only for a radio there is: on a wired machine it would read
  // "off" beside a live link.
  readonly property bool switchable: nmRunning && !!wireless

  // The device of a type, the connected one first: an idle port may be
  // listed before the one in use.
  function deviceOf(type) {
    var all = hardware.filter(function(d) { return d && d.type === type })
    return all.find(function(d) { return d.connected }) || all[0] || null
  }

  function named(ssid) {
    return inRange.find(function(n) { return n && n.name === ssid }) || null
  }

  function toggleNetwork() {
    if (!nmRunning) return
    Networking.wifiEnabled = !Networking.wifiEnabled
    Qt.callLater(function() { network.refresh(true) })
  }

  // ---- the networks in range -----------------------------------------------

  // As plain rows, never the networks themselves (Model.networkRow says why).
  property var rows: []
  property bool scanning: false

  onRowsChanged: cursor.keepRow()

  function syncRows() {
    var next = inRange.filter(function(n) { return !!n }).map(function(n) {
      network.settle(n)
      return Model.networkRow(n)
    })
    rows = Model.sortRows(next)
  }

  function rowAt(ssid) {
    return rows.findIndex(function(r) { return r.ssid === ssid })
  }

  function locked(security) {
    return Model.asksForSecret(security, WifiSecurityType.Open, WifiSecurityType.Owe)
  }

  // ConnectionFailReason's values by name, for the model.
  readonly property var reasons: ({
    NoSecrets: ConnectionFailReason.NoSecrets,
    WifiAuthTimeout: ConnectionFailReason.WifiAuthTimeout,
    WifiNetworkLost: ConnectionFailReason.WifiNetworkLost,
    WifiClientDisconnected: ConnectionFailReason.WifiClientDisconnected,
    WifiClientFailed: ConnectionFailReason.WifiClientFailed
  })

  // One thing done to a network at a time, { ssid, verb }: a connect,
  // disconnect or forget, which its row shows while it runs. A failure,
  // { ssid, why }, shows on its row until the next action.
  property var doing: null
  property var failure: null
  readonly property bool busy: doing !== null

  function act(verb, ssid, run) {
    var target = named(ssid)
    if (busy || !target) return
    doing = { ssid: target.name || "", verb: verb }
    failure = null
    run(target)
    // NetworkManager gives up on a wrong saved passphrase after 25 s, and
    // that failure has to find the action still running: the wait for an
    // answer that never comes is longer.
    patience.restart()
  }

  // The action ends once its network is where it was sent.
  function settle(n) {
    if (!n || !busy || doing.ssid !== (n.name || "")) return
    var verb = doing.verb
    var there = verb === "connect" ? n.connected
      : verb === "disconnect" ? !n.connected && !n.stateChanging
      : !n.known && !n.stateChanging
    if (!there) return
    patience.stop()
    if (verb === "connect") ask.ssid = ""
    failure = null
    doing = null
    refresh()
  }

  function fail(n, reason) {
    if (!n || !busy || doing.ssid !== (n.name || "")) return
    patience.stop()
    failure = { ssid: doing.ssid, why: Model.failureText(reason, locked(n.security), reasons) }
    doing = null
    refresh()
  }

  // A click on a row: leave the network it is on, ask for a passphrase it
  // has none for, or join it. A row may outlive its network; then nothing
  // happens, rather than something to another network.
  function joinOrLeave(row) {
    if (row.connected) act("disconnect", row.ssid, function(n) { n.disconnect() })
    else if (locked(row.security) && !row.known) ask.open(row.ssid)
    else act("connect", row.ssid, function(n) { n.connect() })
  }

  function forget(ssid) {
    act("forget", ssid, function(n) { n.forget() })
  }

  // Enter or the tick in a row's prompt: the passphrase, and for WPA
  // Enterprise the identity with it.
  function send(ssid, eap) {
    if (busy || ask.passphrase.length === 0) return
    var secret = ask.passphrase
    var who = ask.identity
    if (!eap) {
      act("connect", ssid, function(n) { n.connectWithPsk(secret) })
    } else if (who.length > 0) {
      act("connect", ssid, function() {
        enterprise.secret = secret
        enterprise.command = ["bash", "-c", Model.ENTERPRISE_SCRIPT, "nmcli-eap", ssid, who]
        enterprise.running = true
      })
    }
  }

  // The row asking for a passphrase, open through scans, and what has been
  // typed into it.
  QtObject {
    id: ask
    property string ssid: ""
    property string passphrase: ""
    property string identity: ""

    function open(name) {
      if (ssid !== name) {
        passphrase = ""
        identity = ""
      }
      ssid = name
    }

    function drop() {
      ssid = ""
      passphrase = ""
      identity = ""
    }

    // Put away, it hands the keys back to the panel.
    onSsidChanged: {
      if (ssid !== "" || !network.opened) return
      passphrase = ""
      Qt.callLater(function() { if (keys) keys.forceActiveFocus() })
    }
  }

  // ---- scanning ------------------------------------------------------------

  // The radio's scanner is the device's, shared by the bar on every screen
  // and counted by none: a panel turns it on only while open, and turns off
  // only the one it turned on, whichever device that was.
  property var scanner: null

  function scanWith(on) {
    var mine = opened ? wireless : null
    if (scanner && scanner !== mine) scanner.scannerEnabled = false
    scanner = mine
    if (scanner) scanner.scannerEnabled = on
  }

  Component.onDestruction: if (scanner) scanner.scannerEnabled = false

  onWirelessChanged: {
    scanWith(true)
    syncRows()
  }

  onInRangeChanged: syncRows()

  // Reads the networks again. With `rescan` the scanner goes off, and on
  // again a beat later, so that the open panel lists what is in range now;
  // the beat lets it draw before NetworkManager's flood of networks.
  function refresh(rescan) {
    if (opened && wireless) {
      if (!rescan) {
        scanWith(true)
      } else {
        scanning = true
        scanWith(false)
        scanBeat.start()
      }
    }
    syncRows()
  }

  Component.onCompleted: refresh()

  // ---- opening and closing -------------------------------------------------

  function close() {
    opened = false
    ask.drop()
  }

  onOpenedChanged: {
    if (opened) {
      refresh(true)
      cursor.home()
      return
    }
    // A rescan asked for by this open goes with it, or a quick reopen would
    // find the scanner on already.
    scanBeat.stop()
    scanWindow.stop()
    scanning = false
    scanWith(false)
  }

  // ---- the cursor ----------------------------------------------------------

  // One place lit at a time, for the keys and the pointer alike: a stop
  // (Model.STOPS) and, in the networks, which row. The pointer moves it and
  // the items paint it. The networks remember their row while the cursor is
  // elsewhere.
  QtObject {
    id: cursor
    property bool shown: false
    property string stop: "rows"
    property int row: -1
    // On the row's forget cross rather than on the row.
    property bool atCross: false

    function on(where) {
      return shown && stop === where
    }

    function clamp(value, last) {
      return Math.max(0, Math.min(last, value))
    }

    function point(where, slot, forget) {
      shown = true
      stop = where
      if (where === "rows") {
        row = slot
        atCross = forget
      }
    }

    // The panel opens on the first network, or on the switch with none; the
    // cursor shows once a key or the pointer moves it.
    function home() {
      var any = network.rows.length > 0
      row = any ? 0 : -1
      atCross = false
      stop = any ? "rows" : "radio"
      shown = false
    }

    // The first key only shows the cursor, unless it is up. Down and up go
    // through the networks a row at a time, and between the other stops;
    // left and right go onto a row's cross and off it.
    function nudge(dx, dy) {
      if (!shown) {
        shown = true
        if (dy >= 0) return
      }
      var inRows = stop === "rows"
      if (inRows && ((dy > 0 && row < network.rows.length - 1) || (dy < 0 && row > 0))) {
        stepRow(dy)
      } else if (dy !== 0) {
        stop = Model.beyond(stop, dy > 0 ? 1 : -1, {
          radio: network.switchable,
          rows: network.rows.length > 0
        })
        if (inRows && stop !== "rows") atCross = false
        // Coming into the networks from above or below; at their end with
        // no stop beyond, the cursor stays where it is.
        if (stop === "rows" && !inRows) row = dy > 0 ? 0 : network.rows.length - 1
      }
      if (dx !== 0) aside(dx)
    }

    function stepRow(delta) {
      row = clamp(row + delta, network.rows.length - 1)
      atCross = false
    }

    function aside(dx) {
      var here = network.rows[row]
      if (stop === "rows" && here) atCross = Model.canForget(here) && dx > 0
    }

    // Return and Space act on what the cursor is on.
    function press() {
      if (!shown) return
      var here = network.rows[row]
      if (stop === "radio") {
        if (network.switchable) network.toggleNetwork()
      } else if (here && !network.busy) {
        if (atCross && Model.canForget(here)) network.forget(here.ssid)
        else network.joinOrLeave(here)
      }
    }

    // The rows come and go with scans: with none the cursor goes up to the
    // switch, and an open passphrase keeps it on its row.
    function keepRow() {
      var count = network.rows.length
      var asking = network.rowAt(ask.ssid)
      if (count === 0) {
        row = -1
        if (stop === "rows") stop = "radio"
      } else if (ask.ssid !== "") {
        if (asking >= 0) {
          row = asking
          stop = "rows"
        }
      } else {
        row = row >= count ? count - 1 : row < 0 && network.opened ? 0 : row
      }
      if (!Model.canForget(network.rows[row])) atCross = false
    }
  }

  // ---- what runs -----------------------------------------------------------

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

  Timer {
    id: scanBeat
    interval: 100
    onTriggered: {
      if (!network.opened || !network.wireless) return
      network.scanWith(true)
      scanWindow.start()
    }
  }

  // The rows are taken again once the scan this open started is done.
  Timer {
    id: scanWindow
    interval: 1500
    onTriggered: {
      network.scanning = false
      network.syncRows()
    }
  }

  // A network that never answers: its row says the action timed out.
  Timer {
    id: patience
    interval: 30000
    onTriggered: {
      if (!network.busy) return
      network.failure = { ssid: network.doing.ssid, why: Model.TIMED_OUT[network.doing.verb] }
      network.doing = null
      network.refresh()
    }
  }

  // ---- the bar -------------------------------------------------------------

  // A click opens the panel, or closes it; opened, it rescans a beat after
  // it shows.
  BarIcon {
    id: button
    anchors.fill: parent
    bar: network.bar
    glyph: network.glyph
    onClicked: function() {
      if (network.opened) network.close()
      else network.open()
    }
  }

  // ---- the panel -----------------------------------------------------------

  PanelSurface {
    id: card
    widget: button
    host: network
    keys: keys
    wantWidth: Style.space(380)
    wantHeight: stack.implicitHeight

    // hjkl and the arrows move the cursor, Return and Space act on it, r
    // scans again and w turns Wi-Fi on or off. A passphrase being
    // typed takes every key.
    PanelKeys {
      id: keys
      anchors.fill: parent
      panel: network
      typing: ask.ssid !== ""
      onStepped: (dx, dy) => cursor.nudge(dx, dy)
      onActivated: cursor.press()
      onStruck: function(t) {
        var key = t.toLowerCase()
        if (key === "r") network.refresh(true)
        else if (key === "w") network.toggleNetwork()
      }

      Column {
        id: stack
        anchors { left: parent.left; right: parent.right; top: parent.top }
        spacing: Style.space(12)

        // Wi-Fi, or Ethernet, and its state in a few words; the switch turns
        // the radio on or off, and is the cursor's stop above the networks.
        PanelHeader {
          glyph: network.glyph
          dimmed: !network.nmRunning || (network.switchable && !Networking.wifiEnabled)
          title: Model.linkName(network.medium, !!network.wireless)
          note: Model.linkNote(network.medium, Networking.wifiEnabled, !!network.wireless, network.portal)
          ink: network.ink
          family: network.typeface

          end: ToggleSwitch {
            id: wifiSwitch
            visible: network.switchable
            checked: Networking.wifiEnabled
            hasCursor: cursor.on("radio") && network.switchable
            foreground: network.ink
            onHovered: function(on) { if (on) cursor.point("radio") }
            onToggled: network.toggleNetwork()

            PanelToolTip {
              visible: wifiSwitch.containsMouse
              text: Networking.wifiEnabled ? "Turn Wi-Fi off" : "Turn Wi-Fi on"
              fontFamily: network.typeface
            }
          }
        }

        Rule { visible: !!network.wireless && Networking.wifiEnabled }

        // Held to 240 px, so that a crowded street does not run the panel off
        // the screen; the cursor's row scrolls into view.
        ListView {
          id: nearby
          visible: !!network.wireless
          width: parent.width
          height: Math.min(contentHeight, Style.space(240))
          spacing: Style.space(4)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar {}

          model: network.wireless ? network.rows : []
          currentIndex: cursor.row
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          function revealAsking() {
            var at = network.rowAt(ask.ssid)
            if (at >= 0) positionViewAtIndex(at, ListView.Contain)
          }

          // A Column leaves a hidden heading out; a height bound to its
          // visibility as well would loop when the view hides a delegate.
          delegate: Column {
            id: cell
            required property var modelData
            required property int index
            readonly property string title: Model.rowHeading(network.rows, index)
            width: ListView.view.width
            spacing: Style.space(4)

            Heading {
              visible: cell.title !== ""
              text: cell.title
            }

            NetworkItem {
              id: entry
              width: parent.width
              row: cell.modelData
              index: cell.index
            }

            // A passphrase opening low in a long list falls past its end, and
            // the list scrolls to it: once the cell has grown, so that the
            // scroll takes its height.
            onHeightChanged: if (entry.asking) Qt.callLater(nearby.revealAsking)
          }

          // The touchpad scrolls the list as GTK does.
          TouchpadScroll { flickable: nearby }
        }

        // With no network in range, a line, as the Bluetooth panel has it.
        Words {
          visible: !!network.wireless && Networking.wifiEnabled && network.rows.length === 0
          width: parent.width
          text: "Scanning for networks…"
          color: network.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ---- pieces --------------------------------------------------------------

  // Text in the panel's ink and typeface.
  component Words: Text {
    textFormat: Text.PlainText
    color: network.ink
    font.family: network.typeface
  }

  component Heading: PanelSectionHeader {
    foreground: network.ink
    fontFamily: network.typeface
  }

  component Rule: PanelSeparator {
    foreground: network.ink
  }

  // A field of a row's prompt; Escape puts the prompt away.
  component Field: TextField {
    tint: network.ink
    font { family: Style.font.family; pixelSize: Style.font.body }
    padX: Style.spacing.controlGap
    padY: Style.spacing.controlPaddingY
    Keys.onEscapePressed: ask.drop()
  }

  // A network in range: its bars, its name over what it is doing, and at the
  // right a lock for one that takes a secret, or a cross to forget a known
  // one (on one with a lock, for the pointer or the cursor only). A click
  // leaves it, joins it, or opens a passphrase under it. <row> is a row of
  // Model.networkRow.
  component NetworkItem: CursorSurface {
    id: item
    required property var row
    required property int index

    readonly property string ssid: row ? row.ssid : ""
    readonly property bool locked: row ? network.locked(row.security) : false
    readonly property bool eap: !!row && (row.security === WifiSecurityType.Wpa2Eap || row.security === WifiSecurityType.WpaEap)
    readonly property bool canForget: Model.canForget(row)
    readonly property bool cursorHere: cursor.stop === "rows" && cursor.row === index
    readonly property bool crossLit: cursorHere && cursor.atCross && canForget
    readonly property bool crossShown: canForget && (!locked || crossLit || crossPointer.containsMouse)
    readonly property var job: network.doing && network.doing.ssid === ssid ? network.doing : null
    readonly property var fault: network.failure && network.failure.ssid === ssid ? network.failure : null
    readonly property bool acting: job !== null
    readonly property bool failed: fault !== null
    readonly property bool asking: ask.ssid !== "" && ask.ssid === ssid

    readonly property string activity: {
      if (!row || asking) return ""
      if (job) return Model.UNDERWAY[job.verb]
      if (fault) return fault.why
      if (!row.connected) return ""
      return Networking.connectivity === NetworkConnectivity.Portal ? "Sign in required" : "Connected"
    }
    readonly property color tone: failed ? network.urgent : acting || (row && row.connected) ? network.ink : network.faint

    hasCursor: cursor.shown && cursorHere && !cursor.atCross
    current: !!row && row.connected
    foreground: network.ink
    fill: network.rowFill
    currentFill: network.inUseFill
    implicitHeight: body.implicitHeight + (asking ? form.implicitHeight + Style.spacing.md : 0)

    function settle() {
      if (row) network.settle(network.named(ssid))
    }

    function submit() {
      if (row) network.send(ssid, eap)
    }

    // The network's own news. A failure that is not this panel's connect
    // (NetworkManager retrying by itself, say) opens no passphrase.
    Connections {
      target: item.row ? network.named(item.ssid) : null
      function onConnectionFailed(reason) {
        var ours = !!network.doing && network.doing.verb === "connect" && network.doing.ssid === item.ssid
        network.fail(network.named(item.ssid), reason)
        if (ours && Model.asksAgain(reason, item.locked, network.reasons)) ask.open(item.ssid)
      }
      function onConnectedChanged() { item.settle() }
      function onKnownChanged() { item.settle() }
      function onStateChangingChanged() { item.settle() }
    }

    // The pointer moves the cursor here, and leaving does not take it away:
    // the keys carry on from the row last pointed at.
    MouseArea {
      id: rowPointer
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: body.implicitHeight
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      enabled: !network.busy
      onContainsMouseChanged: if (containsMouse) cursor.point("rows", item.index, false)
      onClicked: {
        if (!item.row) return
        cursor.point("rows", item.index, false)
        network.joinOrLeave(item.row)
      }
    }

    Item {
      id: body
      anchors {
        left: parent.left
        right: parent.right
        top: parent.top
        leftMargin: Style.space(10)
        rightMargin: Style.space(10)
      }
      implicitHeight: Math.max(bars.implicitHeight, lines.implicitHeight, mark.implicitHeight) + Style.spacing.rowPaddingX

      Words {
        id: bars
        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
        text: item.row ? Model.signalGlyph(item.row.signal) : ""
        color: item.tone
        font.pixelSize: Style.font.title
      }

      Item {
        id: mark
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        visible: item.locked || item.canForget
        width: Style.space(22)
        implicitHeight: markGlyph.implicitHeight

        Words {
          id: markGlyph
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          visible: item.locked || item.crossShown
          horizontalAlignment: Text.AlignHCenter
          text: item.crossShown ? "󰅙" : "󰌾"
          color: item.crossShown ? network.urgent : network.dim
          font.pixelSize: Style.font.subtitle
        }

        BorderSurface {
          anchors.fill: parent
          z: -1
          visible: item.crossLit
          color: Style.hoverFillFor(network.urgent, network.urgent)
          frame: Border.controlSpec("hover-cursor", network.urgent, network.urgent)
          radius: Style.cornerRadius
        }

        MouseArea {
          id: crossPointer
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
          enabled: item.canForget && !network.busy
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onContainsMouseChanged: if (containsMouse) cursor.point("rows", item.index, true)
          onClicked: if (item.row) network.forget(item.ssid)
        }

        PanelToolTip {
          visible: crossPointer.containsMouse || item.crossLit
          text: "Forget network"
          fontFamily: network.typeface
        }
      }

      // The bars and the mark carry the signal and the lock, so the second
      // line is only for what the row is doing; without it the row is one
      // line.
      Column {
        id: lines
        anchors {
          left: bars.right
          leftMargin: Style.space(10)
          right: mark.visible ? mark.left : parent.right
          rightMargin: mark.visible ? Style.space(8) : 0
          verticalCenter: parent.verticalCenter
        }
        spacing: Style.space(1)

        Words {
          width: parent.width
          text: item.row ? (item.ssid || "Hidden") : ""
          elide: Text.ElideRight
          font.pixelSize: Style.font.body
        }

        Words {
          width: parent.width
          visible: item.activity !== ""
          text: item.activity
          color: item.tone
          elide: Text.ElideRight
          font.pixelSize: Style.font.caption
        }
      }
    }

    // A failure shows in the prompt for two seconds, then it asks again.
    Timer {
      interval: 2000
      running: item.failed && item.asking
      onTriggered: {
        network.failure = null
        secretField.forceActiveFocus()
      }
    }

    // The passphrase, and for WPA Enterprise the identity above it: Enter or
    // the tick joins, Escape puts it away.
    Item {
      id: form
      anchors {
        left: parent.left
        right: parent.right
        top: rowPointer.bottom
        leftMargin: Style.space(10)
        rightMargin: Style.space(10)
        topMargin: Style.space(4)
      }
      visible: item.asking
      implicitHeight: (identityField.visible ? identityField.implicitHeight + Style.space(4) : 0) + secretField.implicitHeight + Style.spacing.rowGap
      height: implicitHeight

      Field {
        id: identityField
        anchors { left: parent.left; right: join.left; top: parent.top; rightMargin: Style.space(6) }
        visible: item.eap && !item.acting && !item.failed
        enabled: !item.acting
        placeholderText: "Identity (user@domain)"
        text: item.asking ? ask.identity : ""
        onTextChanged: if (item.asking && text !== ask.identity) ask.identity = text
        onAccepted: secretField.forceActiveFocus()
        onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
        Component.onCompleted: if (visible) Qt.callLater(forceActiveFocus)
      }

      Field {
        id: secretField
        anchors {
          left: parent.left
          right: join.left
          bottom: parent.bottom
          bottomMargin: Style.spacing.rowGap / 2
          rightMargin: Style.space(6)
        }
        visible: !item.acting && !item.failed
        enabled: !item.acting
        echoMode: TextInput.Password
        placeholderText: "Passphrase"
        text: item.asking ? ask.passphrase : ""
        onTextChanged: if (item.asking && text !== ask.passphrase) ask.passphrase = text
        onAccepted: item.submit()
        onVisibleChanged: if (visible && !item.eap) Qt.callLater(forceActiveFocus)
        Component.onCompleted: if (visible && !item.eap) Qt.callLater(forceActiveFocus)
      }

      // While the join runs, and for two seconds after it fails, with why: a
      // wrong passphrase, or a network lost, refused or gone quiet.
      BorderSurface {
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
        height: Style.spacing.controlHeight
        visible: item.acting || item.failed
        color: Style.normalFillFor(network.ink)
        frame: Border.controlSpec("normal", network.ink, Commons.Color.accent)
        radius: Style.cornerRadius

        Words {
          anchors.fill: parent
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: item.fault ? item.fault.why : "Connecting..."
          color: item.failed ? network.urgent : network.ink
          font.pixelSize: Style.font.bodySmall
        }
      }

      // 22 px, under the lock above it.
      PanelActionButton {
        id: join
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        visible: !item.acting && !item.failed
        enabled: !!item.row && secretField.text.length > 0 && (!item.eap || identityField.text.length > 0)
        iconText: "󰄬"
        tooltipText: "Connect"
        foreground: network.ink
        fontFamily: network.typeface
        onClicked: item.submit()
      }
    }
  }
}
