import QtQuick
import Quickshell
import Quickshell.Networking
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Wi-Fi's page in Settings: the radio, the network it is on, and the others in
// reach. The bar's Wi-Fi menu stays the quick way in, and joins the enterprise
// (802.1X) networks this page leaves to it: those ask for an identity too.
Column {
  id: root
  spacing: Style.space(22)

  readonly property var devices: Networking.devices ? Networking.devices.values : []
  readonly property var device: {
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      if (!d || d.type !== DeviceType.Wifi) continue
      if (d.connected) return d
      if (!fallback) fallback = d
    }
    return fallback
  }
  readonly property var networkObjects: device && device.networks ? device.networks.values : []
  readonly property bool radioOn: Networking.wifiEnabled

  // Plain snapshots, never the WifiNetwork objects themselves: NetworkManager
  // can drop a network while a delegate still holds it, which takes Quickshell
  // down. Actions look the network up again by name.
  property var rows: []
  property string rowsText: ""
  readonly property var current: rows.length > 0 && rows[0].connected ? rows[0] : null
  readonly property var known: rows.filter(function (r) { return r.known && !r.connected })
  readonly property var others: rows.filter(function (r) { return !r.known && !r.connected })

  // One action at a time, the way NetworkManager takes them.
  property string busySsid: ""
  property string busyKind: ""
  property string failedSsid: ""
  property string failure: ""
  // The row asking for a password, and what is typed into it.
  property string askingSsid: ""

  // Scanning lives on the shared device, so this page turns it off again
  // only when it was the one to turn it on.
  property var scanner: null

  function scan() {
    if (scanner === device) return
    if (scanner) scanner.scannerEnabled = false
    scanner = device && !device.scannerEnabled ? device : null
    if (scanner) scanner.scannerEnabled = true
  }

  Component.onCompleted: { scan(); sync() }
  Component.onDestruction: if (scanner) scanner.scannerEnabled = false
  onDeviceChanged: { scan(); sync() }
  onNetworkObjectsChanged: sync()

  function networkFor(ssid) {
    for (var i = 0; i < networkObjects.length; i++)
      if (networkObjects[i] && networkObjects[i].name === ssid) return networkObjects[i]
    return null
  }

  function needsPassword(security) {
    return security !== WifiSecurityType.Open && security !== WifiSecurityType.Owe
  }

  function sync() {
    var list = []
    for (var i = 0; i < networkObjects.length; i++) {
      var n = networkObjects[i]
      if (!n || !n.name) continue
      list.push({
        ssid: n.name,
        connected: !!n.connected,
        known: !!n.known,
        signal: Math.round((n.signalStrength || 0) * 100),
        secured: needsPassword(n.security),
        enterprise: n.security === WifiSecurityType.Wpa2Eap || n.security === WifiSecurityType.WpaEap
      })
    }
    list.sort(function (a, b) {
      if (a.connected !== b.connected) return a.connected ? -1 : 1
      if (a.known !== b.known) return a.known ? -1 : 1
      return b.signal - a.signal
    })
    var text = JSON.stringify(list)
    if (text !== rowsText) {
      rowsText = text
      rows = list
    }

    if (busyKind === "") return
    var network = networkFor(busySsid)
    if (!network) finish("")
    else if (busyKind === "connect" && network.connected) finish("")
    else if (busyKind === "disconnect" && !network.connected && !network.stateChanging) finish("")
    else if (busyKind === "forget" && !network.known && !network.stateChanging) finish("")
  }

  function start(kind, ssid, action) {
    var network = networkFor(ssid)
    if (busyKind !== "" || !network) return
    busySsid = ssid
    busyKind = kind
    failedSsid = ""
    failure = ""
    action(network)
    giveUp.restart()
  }

  function finish(reason) {
    giveUp.stop()
    if (reason.length > 0) {
      failedSsid = busySsid
      failure = reason
    } else if (busyKind === "connect") {
      askingSsid = ""
    }
    busySsid = ""
    busyKind = ""
  }

  function join(row) {
    if (row.enterprise && !row.known) {
      failedSsid = row.ssid
      failure = "Join it from the Wi-Fi menu in the bar, which asks for the identity too."
    } else if (row.secured && !row.known) {
      askingSsid = row.ssid
    } else {
      start("connect", row.ssid, function (n) { n.connect() })
    }
  }

  function joinWith(ssid, password) {
    if (password.length === 0) return
    start("connect", ssid, function (n) { n.connectWithPsk(password) })
  }

  function signalIcon(signal) {
    if (signal >= 75) return "󰤨"
    if (signal >= 50) return "󰤥"
    if (signal >= 25) return "󰤢"
    return "󰤟"
  }

  // The radio's on/off, and a scan's results, arrive without a signal for the
  // networks already listed: a light poll keeps the rows true.
  Timer {
    interval: 2000
    repeat: true
    running: true
    onTriggered: root.sync()
  }

  Timer {
    id: giveUp
    interval: 30000
    onTriggered: root.finish("No answer from the network.")
  }

  Connections {
    target: root.busyKind === "connect" ? root.networkFor(root.busySsid) : null
    function onConnectionFailed(reason) {
      var row = root.rows.filter(function (r) { return r.ssid === root.busySsid })[0]
      var secured = !!row && row.secured
      if (secured && (reason === ConnectionFailReason.NoSecrets || reason === ConnectionFailReason.WifiAuthTimeout)) {
        root.askingSsid = root.busySsid
        root.finish(reason === ConnectionFailReason.NoSecrets ? "It needs the password." : "Wrong password?")
      } else if (reason === ConnectionFailReason.WifiNetworkLost) root.finish("The network went out of reach.")
      else root.finish("Could not join.")
    }
  }

  Section {
    Toggle {
      width: parent.width
      label: "Wi-Fi"
      description: !root.radioOn ? "Off."
        : root.current ? "Connected to " + root.current.ssid + "."
        : "On, and not connected."
      checked: root.radioOn
      onClicked: Networking.wifiEnabled = !Networking.wifiEnabled
    }
  }

  // Outside the lists, so a refresh of the rows never takes what is typed.
  Section {
    title: "PASSWORD FOR " + root.askingSsid.toUpperCase()
    visible: root.radioOn && root.askingSsid.length > 0
    Row {
      spacing: Style.space(8)
      TextField {
        id: password
        width: Style.space(260)
        password: true
        placeholderText: "Password"
        onAccepted: root.joinWith(root.askingSsid, text)
        onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
      }
      Button {
        text: root.busyKind === "connect" ? "Joining…" : "Join"
        bordered: true
        onClicked: root.joinWith(root.askingSsid, password.text)
      }
      Button {
        text: "Cancel"
        onClicked: root.askingSsid = ""
      }
    }
    Caption {
      width: parent.width
      visible: root.failedSsid === root.askingSsid && root.failure.length > 0
      text: root.failure
    }
  }

  Section {
    title: "CONNECTED"
    visible: root.radioOn && !!root.current
    Repeater {
      model: root.current ? [root.current] : []
      delegate: networkRow
    }
  }

  Section {
    title: "KNOWN NETWORKS"
    visible: root.radioOn && root.known.length > 0
    Repeater {
      model: root.known
      delegate: networkRow
    }
  }

  Section {
    title: "OTHER NETWORKS"
    visible: root.radioOn
    Repeater {
      model: root.others
      delegate: networkRow
    }
    Caption {
      width: parent.width
      visible: root.others.length === 0
      text: root.rows.length === 0 ? "Looking for networks…" : "No other networks in reach."
    }
  }

  Component {
    id: networkRow

    Line {
      id: entry
      required property var modelData
      readonly property bool busy: root.busySsid === modelData.ssid && root.busyKind !== ""
      label: modelData.ssid
      detail: {
        if (entry.busy) {
          if (root.busyKind === "connect") return "Joining…"
          if (root.busyKind === "disconnect") return "Leaving…"
          return "Forgetting…"
        }
        if (root.failedSsid === entry.modelData.ssid && root.failure.length > 0) return root.failure
        var parts = [root.signalIcon(entry.modelData.signal) + " " + entry.modelData.signal + "%"]
        parts.push(entry.modelData.enterprise ? "Enterprise" : entry.modelData.secured ? "Secured" : "Open")
        if (entry.modelData.known && !entry.modelData.connected) parts.push("saved")
        return parts.join("  ·  ")
      }

      Row {
        spacing: Style.space(8)
        Button {
          visible: entry.modelData.connected
          text: "Disconnect"
          bordered: true
          onClicked: root.start("disconnect", entry.modelData.ssid, function (n) { n.disconnect() })
        }
        Button {
          visible: entry.modelData.known && !entry.modelData.connected
          text: "Forget"
          bordered: true
          onClicked: root.start("forget", entry.modelData.ssid, function (n) { n.forget() })
        }
        Button {
          visible: !entry.modelData.connected && root.askingSsid !== entry.modelData.ssid
          text: "Join"
          bordered: true
          onClicked: root.join(entry.modelData)
        }
      }
    }
  }
}
