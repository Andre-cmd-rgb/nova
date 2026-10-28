import QtQuick
import Quickshell
import Quickshell.Networking

Item {
  id: root

  // The panel already uses this native NetworkManager subscription. One
  // service for the session keeps a bar on every screen from notifying twice.
  property var networking: Networking
  readonly property var devices: networking.devices ? networking.devices.values : []
  readonly property int connectivity: networking.connectivity
  readonly property var connection: wifiConnection()
  property string notifiedConnection: ""

  function wifiConnection() {
    var wifi = null
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (!device || !device.connected) continue
      // Match the panel's preference for wired when both links are up.
      if (device.type === DeviceType.Wired) return null
      if (device.type !== DeviceType.Wifi || !device.networks) continue
      var networks = device.networks.values
      for (var j = 0; j < networks.length; j++) {
        var network = networks[j]
        if (network && network.connected) {
          wifi = { key: JSON.stringify([device.name, network.name]), name: network.name || "Wi-Fi" }
          break
        }
      }
    }
    return wifi
  }

  function notificationCommand(name) {
    return ["nova-notification-send", "-u", "normal", "-g", "󰖩",
      "Sign in to " + name, "Click to open the Wi-Fi sign-in page.",
      "--exec", "nova-launch-browser", "http://ping.archlinux.org/nm-check.txt"]
  }

  function notifyPortal(name) {
    Quickshell.execDetached(notificationCommand(name))
  }

  function checkPortal() {
    var key = connection ? connection.key : ""
    // Limited/none/unknown may flicker while the same portal still owns the
    // link. Only a full connection or a different link permits another toast.
    if (connectivity === NetworkConnectivity.Full || key !== notifiedConnection)
      notifiedConnection = ""
    if (!connection || connectivity !== NetworkConnectivity.Portal || notifiedConnection === key) return
    notifiedConnection = key
    notifyPortal(connection.name)
  }

  // Coalesce the device and connectivity updates from the same D-Bus change.
  onConnectionChanged: Qt.callLater(checkPortal)
  onConnectivityChanged: Qt.callLater(checkPortal)
  Component.onCompleted: Qt.callLater(checkPortal)
}
