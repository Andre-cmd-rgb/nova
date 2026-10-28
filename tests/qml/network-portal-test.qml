import QtQuick
import Quickshell
import Quickshell.Networking
import "plugins/services/network" as Portal

// Native NetworkManager state, supplied as fixtures: no real radio, bus or
// notification is touched. The service runs once regardless of bar count.
ShellRoot {
  id: test
  property var notices: []

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  QtObject {
    id: wifi
    property string name: "Café: $HOME; 'Wi-Fi'"
    property bool connected: true
  }

  QtObject {
    id: radio
    property string name: "wlan0"
    property int type: DeviceType.Wifi
    property bool connected: true
    property var networks: ({ values: [wifi] })
  }

  QtObject {
    id: wired
    property int type: DeviceType.Wired
    property bool connected: false
  }

  QtObject {
    id: network
    property int connectivity: NetworkConnectivity.Portal
    property var devices: ({ values: [radio, wired] })
  }

  Portal.Service {
    id: portal
    networking: network
    function notifyPortal(name) { test.notices = test.notices.concat([notificationCommand(name)]) }
  }

  Component.onCompleted: Qt.callLater(function() { Qt.callLater(run) })

  function run() {
    check(notices.length === 1, "already behind a portal at startup: one notification")
    var command = notices[0] || []
    check(command[0] === "nova-notification-send" && command[2] === "normal", "Nova's notification helper, at normal urgency")
    check(command[5] === "Sign in to " + wifi.name, "the network name stays one literal argument")
    check(JSON.stringify(command.slice(-3)) === '["--exec","nova-launch-browser","http://ping.archlinux.org/nm-check.txt"]', "one click opens the default browser at the check URI")

    portal.checkPortal()
    network.connectivity = NetworkConnectivity.Limited
    portal.checkPortal()
    network.connectivity = NetworkConnectivity.None
    portal.checkPortal()
    network.connectivity = NetworkConnectivity.Unknown
    portal.checkPortal()
    network.connectivity = NetworkConnectivity.Portal
    portal.checkPortal()
    check(notices.length === 1, "duplicates and limited/none/unknown flicker do not repeat a toast")

    network.connectivity = NetworkConnectivity.Full
    portal.checkPortal()
    network.connectivity = NetworkConnectivity.Portal
    portal.checkPortal()
    check(notices.length === 2, "full connectivity rearms the same network")

    wifi.name = "Train"
    portal.checkPortal()
    check(notices.length === 3 && notices[2][5] === "Sign in to Train", "another network can ask immediately")
    wifi.connected = false
    portal.checkPortal()
    check(notices.length === 3, "a disconnected station stays quiet")
    wifi.connected = true
    portal.checkPortal()
    check(notices.length === 4, "rejoining the same network is a new connection")

    wired.connected = true
    portal.checkPortal()
    check(notices.length === 4 && portal.connection === null, "wired takes precedence, with no portal toast")
    wired.connected = false
    network.devices = { values: [] }
    portal.checkPortal()
    check(notices.length === 4, "no devices, no toast")

    network.devices = { values: [radio] }
    var quietStates = [NetworkConnectivity.Full, NetworkConnectivity.Limited, NetworkConnectivity.None, NetworkConnectivity.Unknown]
    for (var i = 0; i < quietStates.length; i++) {
      network.connectivity = quietStates[i]
      wifi.name = "Quiet " + i
      portal.checkPortal()
    }
    check(notices.length === 4, "fresh connections in full/limited/none/unknown do not notify")
    network.connectivity = NetworkConnectivity.Portal
    wifi.name = ""
    portal.checkPortal()
    check(notices.length === 5 && notices[4][5] === "Sign in to Wi-Fi", "a hidden name has a short fallback")
    radio.name = "wlan1"
    portal.checkPortal()
    check(notices.length === 6, "another radio is a different connection")

    // This last change is handled by the service's subscription alone.
    wifi.name = "Hotel"
    Qt.callLater(finish)
  }

  function finish() {
    check(notices.length === 7 && notices[6][5] === "Sign in to Hotel", "native property changes notify without a poll")
    network.connectivity = NetworkConnectivity.Full
    Qt.callLater(reenterPortal)
  }

  function reenterPortal() {
    network.connectivity = NetworkConnectivity.Portal
    Qt.callLater(verifyReentry)
  }

  function verifyReentry() {
    check(notices.length === 8, "native connectivity changes rearm and notify without a poll")
    console.log("DONE")
    Qt.quit()
  }
}
