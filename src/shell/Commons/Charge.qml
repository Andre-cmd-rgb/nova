pragma Singleton
import QtQuick
import Quickshell.Io
import Quickshell.Services.UPower
import "ChargeRule.js" as ChargeRule

// The battery's charge as every widget shows it: UPower's display device, read
// through ChargeRule, so that a battery resting full after its charge reads
// 100% on the bar, in its panel and in its notification alike. Whether a charge
// limit holds the battery is nova battery limit's to say; it is read once
// UPower shows a battery (never, on a desktop), at every plug and unplug, and
// when nova battery limit sets one (`nova-shell -q battery limitChanged`, from
// Settings or a terminal).
QtObject {
  id: charge

  readonly property var device: UPower.displayDevice
  readonly property bool present: !!(device && device.isPresent)
  readonly property bool plugged: present && !UPower.onBattery
  // Whether a charge limit is on, by the last read of it.
  property bool limited: false

  readonly property bool resting: present && ChargeRule.resting(device.percentage, plugged,
    device.state === UPowerDeviceState.FullyCharged, limited)
  // The charge, 0 to 1, and in whole percent; 0 with no battery.
  readonly property real level: present ? ChargeRule.level(device.percentage, plugged,
    device.state === UPowerDeviceState.FullyCharged, limited) : 0
  readonly property int percent: Math.round(level * 100)

  // Asked again while a read runs, it reads once more after: the one running
  // may have begun before the change.
  property bool askedAgain: false

  function readLimit() {
    if (limitRead.running) askedAgain = true
    else limitRead.running = true
  }

  function takeLimit(text) {
    try {
      limited = JSON.parse(text).on === true
    } catch (e) {
      limited = false
    }
  }

  property Process limitRead: Process {
    command: ["nova-battery-limit", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: charge.takeLimit(text)
    }
    onExited: {
      if (!charge.askedAgain) return
      charge.askedAgain = false
      Qt.callLater(charge.readLimit)
    }
  }

  property Connections plugs: Connections {
    target: UPower
    function onOnBatteryChanged() { if (charge.present) charge.readLimit() }
  }

  property IpcHandler ipc: IpcHandler {
    target: "battery"

    // nova battery limit, once it has set a limit or taken it away.
    function limitChanged(): string {
      charge.readLimit()
      return "ok"
    }
  }

  onPresentChanged: if (present) readLimit()
  Component.onCompleted: if (present) readLimit()
}
