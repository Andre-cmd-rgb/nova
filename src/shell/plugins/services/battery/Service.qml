import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "BatteryModel.js" as BatteryModel

// The battery's two jobs in the shell: a warning when it runs low, and the
// power mode that follows the power source.
Item {
  id: root

  // Discharging at or under this percentage, the battery is low.
  readonly property int lowLevel: 10
  property bool restorePending: false

  // Kept across a reload of the shell, which then does not warn again about
  // the same low battery.
  PersistentProperties {
    id: persisted
    reloadableId: "nova-battery"
    property bool notifiedLowBattery: false
  }

  // Looked at every 30 s and whenever the power source changes.
  function checkBattery() {
    var check = BatteryModel.shouldWarnLowBattery(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging, lowLevel, persisted.notifiedLowBattery)
    persisted.notifiedLowBattery = check.notifiedLowBattery
    if (!check.notify || warning.running) return
    warning.command = ["nova-battery-low", String(check.level)]
    warning.running = true
  }

  // The power mode last chosen for the power source now in use, put back at
  // login and at every plug and unplug (nova-power-profile restore). A change
  // during a restore gets one more run after it, so a quick unplug and plug
  // ends on the right side.
  function restoreProfile() {
    if (profile.running) restorePending = true
    else profile.running = true
  }

  Process { id: warning }

  Process {
    id: profile
    command: ["nova-power-profile", "restore"]
    onExited: {
      if (!root.restorePending) return
      root.restorePending = false
      Qt.callLater(function() { profile.running = true })
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkBattery()
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      root.checkBattery()
      root.restoreProfile()
    }
  }

  Component.onCompleted: restoreProfile()
}
