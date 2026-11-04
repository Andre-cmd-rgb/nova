import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// The battery as the shell minds it: a warning when it runs low, and the
// power mode that goes with the power source.
Item {
  id: battery

  // Whether it was low at the last look, so that it is warned of once each
  // time it goes low; kept through a reload of the shell.
  PersistentProperties {
    id: memory
    reloadableId: "nova-battery"
    property bool wasLow: false
  }

  // A look every 30 s, and as the power source changes. UPower's display
  // device is the batteries as one, and there is none on a desktop; it is
  // low draining at 10% or under.
  function look() {
    var pack = UPower.displayDevice
    var charge = pack && pack.isPresent ? Math.round(Number(pack.percentage || 0) * 100) : -1
    var low = charge >= 0 && charge <= 10 && UPower.onBattery && pack.state === UPowerDeviceState.Discharging
    var news = low && !memory.wasLow
    memory.wasLow = low
    if (!news || warning.running) return
    warning.command = ["nova-battery-low", String(charge)]
    warning.running = true
  }

  Process { id: warning }

  // The power mode last chosen for the source in use, put back at login and
  // at every plug and unplug. Asked again while it runs, it runs once more
  // after, so a quick unplug and plug ends on the right side.
  Process {
    id: powerMode
    property bool askedAgain: false
    command: ["nova-power-profile", "restore"]

    function restore() {
      if (running) askedAgain = true
      else running = true
    }

    onExited: {
      if (!askedAgain) return
      askedAgain = false
      Qt.callLater(() => powerMode.running = true)
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: battery.look()
  }

  // A plug or an unplug.
  Connections {
    target: UPower

    function onOnBatteryChanged() {
      battery.look()
      powerMode.restore()
    }
  }

  Component.onCompleted: powerMode.restore()
}
