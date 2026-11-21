import QtQuick
import Quickshell
import Quickshell.Bluetooth
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bluetooth's page in Settings: the radio, iPhone notifications, the devices
// paired with this computer, and, while the page is open, the ones nearby
// that could be. The bar's Bluetooth menu stays the quick way in.
Column {
  id: root
  spacing: Style.space(22)

  readonly property var adapter: Bluetooth.defaultAdapter
  // A ThinkPad's Bluetooth switch powers the controller down, and BlueZ's
  // adapter goes with it, so the radio's own switch says there is Bluetooth to
  // turn back on: the shell's one rfkill watch has it (Rfkill), held while
  // the page is shown.
  readonly property var radioSwitches: Rfkill.blocked(Rfkill.bluetooth)
  readonly property bool available: !!adapter || Object.keys(radioSwitches).length > 0
  readonly property bool powered: !!adapter && adapter.enabled
  readonly property var deviceObjects: Bluetooth.devices ? Bluetooth.devices.values : []

  // Plain snapshots, never the Device objects: BlueZ drops a device when a
  // scan forgets it, and a delegate still holding it takes Quickshell down.
  property var rows: []
  property string rowsText: ""
  readonly property var mine: rows.filter(function (r) { return r.connected || r.paired })
  readonly property var nearby: rows.filter(function (r) { return !r.connected && !r.paired })

  // address -> "connecting" | "disconnecting" | "forgetting"
  property var pending: ({})

  // Whether Bluetooth LE is on, as `nova bluetooth le` has it; null where it
  // cannot say. Its switch runs through Settings, which reads it back.
  property var le: null
  // Whether iPhone notifications are switched on (nova notification iphone),
  // and whether their service ran when Settings read its state.
  property bool iphone: false
  property bool iphoneRunning: false
  // <changes>: what it sets, by its path in what this view was given, which
  // Settings shows at once (SettingsState); null for none.
  signal command(var argv, var changes)

  // Each scan this page asks for. Settings ends it once the page is gone: the
  // page cannot, as BlueZ may confirm the scan only after that.
  signal discoveryStarted()

  Component.onCompleted: {
    Rfkill.hold()
    sync()
  }
  Component.onDestruction: Rfkill.release()
  onDeviceObjectsChanged: sync()

  function label(d) {
    return String(d.deviceName || d.name || "").trim()
  }

  // A scan turns up devices known only by an address or a service UUID, in
  // any of its spellings; nobody can tell those apart, so they are not
  // listed. The bar's Bluetooth menu tests the same way, in its own
  // panels/bluetooth/Model.js: each plugin carries what it uses.
  function named(text) {
    return text !== ""
      && !/^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(text)
      && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text)
      && !/^[0-9a-f]{32}$/i.test(text)
      && !/^0x[0-9a-f]{4,32}$/i.test(text)
  }

  function sync() {
    var list = []
    for (var i = 0; i < deviceObjects.length; i++) {
      var d = deviceObjects[i]
      if (!d || !d.address || !named(label(d))) continue
      list.push({
        address: d.address,
        name: label(d),
        connected: !!d.connected,
        paired: !!(d.paired || d.bonded || d.trusted),
        battery: d.batteryAvailable ? Math.round((d.battery || 0) * 100) : -1
      })
    }
    list.sort(function (a, b) {
      if (a.connected !== b.connected) return a.connected ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    var text = JSON.stringify(list)
    if (text !== rowsText) {
      rowsText = text
      rows = list
    }

    var next = Object.assign({}, pending)
    var changed = false
    for (var address in next) {
      var row = list.filter(function (r) { return r.address === address })[0]
      var done = next[address] === "forgetting" ? !row || !row.paired
        : next[address] === "connecting" ? !!row && row.connected
        : !row || !row.connected
      if (done) { delete next[address]; changed = true }
    }
    if (changed) pending = next
  }

  function act(action, row, state) {
    var next = Object.assign({}, pending)
    next[row.address] = state
    pending = next
    Quickshell.execDetached(["nova-bluetooth-device", action, row.address])
    giveUp.restart()
  }

  Timer {
    interval: 1500
    repeat: true
    running: true
    onTriggered: root.sync()
  }

  // An action BlueZ never answers stops reading as under way.
  Timer {
    id: giveUp
    interval: 30000
    onTriggered: root.pending = ({})
  }

  // A scan ends by itself after a while: while the page is open, there is
  // always one running.
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.powered && !root.adapter.discovering
    onTriggered: {
      root.discoveryStarted()
      root.adapter.discovering = true
    }
  }

  Section {
    Toggle {
      width: parent.width
      label: "Bluetooth"
      detail: !root.available ? "Not available" : BluetoothPower.turning === "on" ? "Turning on…"
        : BluetoothPower.turning === "off" ? "Turning off…" : ""
      checked: BluetoothPower.on
      onClicked: if (root.available) BluetoothPower.toggle()
    }
    Toggle {
      width: parent.width
      visible: root.available && root.le !== null
      label: "Bluetooth Low Energy"
      checked: root.le === true
      onClicked: root.command(["nova-bluetooth-le", checked ? "off" : "on"], { "bluetooth.le": !checked })
    }
  }

  IphoneNotifications {
    id: phoneNotes
    visible: root.available
    on: root.iphone
    running: root.iphoneRunning
    powered: root.powered
    onCommand: function (argv) { root.command(argv, null) }
  }

  Section {
    title: "MY DEVICES"
    visible: root.powered
    Repeater {
      model: root.mine
      delegate: deviceRow
    }
    Caption {
      width: parent.width
      visible: root.mine.length === 0
      text: "No devices"
    }
  }

  Section {
    title: "NEARBY DEVICES"
    visible: root.powered
    Repeater {
      model: root.nearby
      delegate: deviceRow
    }
    Caption {
      width: parent.width
      visible: root.nearby.length === 0
      text: "Searching…"
    }
  }

  Component {
    id: deviceRow

    Line {
      id: entry
      required property var modelData
      readonly property string busy: root.pending[modelData.address] || ""
      // An iPhone whose notifications show here comes back by itself; a
      // connection from here would be over classic Bluetooth, as its
      // headset.
      readonly property bool notifying: phoneNotes.addresses.indexOf(modelData.address) >= 0
      label: modelData.name
      detail: {
        if (entry.busy === "connecting") return modelData.paired ? "Connecting…" : "Pairing…"
        if (entry.busy === "disconnecting") return "Disconnecting…"
        if (entry.busy === "forgetting") return "Forgetting…"
        // Nearby devices are not paired: their section says so.
        var parts = modelData.connected ? ["Connected"] : modelData.paired ? ["Not connected"] : []
        if (modelData.battery >= 0) parts.push(modelData.battery + "% battery")
        return parts.join("  ·  ")
      }

      Row {
        spacing: Style.space(8)
        enabled: entry.busy === ""
        opacity: enabled ? 1 : 0.5
        Button {
          visible: entry.modelData.paired
          text: "Forget"
          bordered: true
          onClicked: root.act("forget", entry.modelData, "forgetting")
        }
        Button {
          visible: !entry.notifying
          text: entry.modelData.connected ? "Disconnect" : entry.modelData.paired ? "Connect" : "Pair"
          bordered: true
          onClicked: {
            if (entry.modelData.connected) root.act("disconnect", entry.modelData, "disconnecting")
            else root.act(entry.modelData.paired ? "connect" : "pair", entry.modelData, "connecting")
          }
        }
      }
    }
  }
}
