import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "BatteryModel.js" as BatteryModel

Item {
  id: root

  property var shell: null
  property string novaPath: Quickshell.env("NOVA_PATH")

  readonly property int batteryThreshold: 10

  PersistentProperties {
    id: persisted
    reloadableId: "nova-battery"
    property bool notifiedLowBattery: false
  }

  function batteryPercentage() {
    return BatteryModel.batteryPercentage(UPower.displayDevice)
  }

  function isDischarging() {
    return BatteryModel.isDischarging(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging)
  }

  function checkBattery() {
    var state = BatteryModel.shouldWarnLowBattery(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging, batteryThreshold, persisted.notifiedLowBattery)
    persisted.notifiedLowBattery = state.notifiedLowBattery
    if (state.notify) sendLowBatteryWarning(state.level)
  }

  function sendLowBatteryWarning(level) {
    if (warningProcess.running) return
    warningProcess.command = [
      "nova-battery-low",
      String(level)
    ]
    warningProcess.running = true
  }

  Process { id: warningProcess }

  // The power mode follows the power source: at login and on every plug and
  // unplug, put back the one last chosen for it (nova-power-profile restore).
  // A change that lands while a restore is still running gets one more run, so
  // a quick unplug-replug ends on the right side.
  property bool restorePending: false

  function restoreProfile() {
    if (profileProcess.running) restorePending = true
    else profileProcess.running = true
  }

  Process {
    id: profileProcess
    command: ["nova-power-profile", "restore"]
    onExited: {
      if (!root.restorePending) return
      root.restorePending = false
      Qt.callLater(function() { profileProcess.running = true })
    }
  }

  Component.onCompleted: restoreProfile()

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
}
