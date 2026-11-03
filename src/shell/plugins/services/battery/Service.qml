import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// What the shell does about the battery: a warning when it runs low, and the
// power mode that goes with the power source.
Item {
  id: service

  // Discharging at or under this percentage, the battery is low.
  readonly property int lowLevel: 10

  // Whether the battery was low at the last look, kept through a reload of
  // the shell so the same low battery is not warned about twice.
  PersistentProperties {
    id: persisted
    reloadableId: "nova-battery"
    property bool notifiedLowBattery: false
  }

  // UPower's display device is the battery as a whole; with none, there is
  // nothing to warn about. A warning comes once each time it goes low.
  function checkBattery() {
    var device = UPower.displayDevice
    var level = device && device.isPresent ? Math.round(Number(device.percentage || 0) * 100) : -1
    var low = level >= 0 && UPower.onBattery && device.state === UPowerDeviceState.Discharging && level <= lowLevel
    var warn = low && !persisted.notifiedLowBattery
    persisted.notifiedLowBattery = low
    if (warn && !warning.running) warning.warn(level)
  }

  Process {
    id: warning

    function warn(level) {
      command = ["nova-battery-low", String(level)]
      running = true
    }
  }

  // The power mode last chosen for the source now in use, put back at login
  // and at every plug and unplug. A change while that runs gets one more run
  // after it, so a quick unplug and plug ends on the right side.
  Process {
    id: profile
    command: ["nova-power-profile", "restore"]
    property bool again: false

    function restore() {
      if (running) again = true
      else running = true
    }

    onExited: {
      if (!again) return
      again = false
      Qt.callLater(function() { profile.running = true })
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: service.checkBattery()
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      service.checkBattery()
      profile.restore()
    }
  }

  Component.onCompleted: profile.restore()
}
