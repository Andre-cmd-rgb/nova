import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland

// What happens when no one is at the computer: the screensaver after
// idle.screensaver seconds without input (shell.json, 180 by default), the
// lock after idle.lock (300), 0 for never; the lock plugin turns the screens
// off and on again. Nothing of it while Caffeine is on. Each step goes to
// the journal as "nova idle <time> <step>".
Item {
  id: idle

  // Injected by the shell.
  property var shell: null

  readonly property var times: shell && shell.shellConfig && shell.shellConfig.idle ? shell.shellConfig.idle : ({})
  readonly property int saverAfter: seconds(times.screensaver, 180)
  readonly property int lockAfter: seconds(times.lock, 300)

  // Caffeine's switch, a file nova caffeine makes and removes and then asks
  // for a refresh; a look every minute catches a refresh that could not
  // reach the shell (a restart, say). The bar's cup shows `caffeine`.
  readonly property string switchFile: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/caffeine"
  property bool caffeine: false
  property bool switchRead: false
  // Someone's absence counts: the switch read, and Caffeine off.
  readonly property bool minding: switchRead && !caffeine

  // The screensaver this service started since the last input, which input
  // takes away again.
  property bool saverUp: false

  // Caffeine on battery lasts until the battery is low, so that a laptop left
  // with its lid shut does not run flat: then nova caffeine ends it.
  readonly property bool batteryLow: UPower.onBattery && !!UPower.displayDevice
    && UPower.displayDevice.isLaptopBattery && UPower.displayDevice.percentage <= 0.10
  onBatteryLowChanged: if (batteryLow && caffeine) caffeineEnds.go()

  // Whole seconds from shell.json, or the default for what is not a number
  // of them.
  function seconds(value, otherwise) {
    var count = Number(value)
    return isFinite(count) && count >= 0 ? Math.floor(count) : otherwise
  }

  function log(step, detail) {
    console.log("nova idle " + new Date().toISOString() + " " + step + (detail ? ": " + detail : ""))
  }

  function setCaffeine(on) {
    if (switchRead && caffeine === on) return
    caffeine = on
    switchRead = true
    log("caffeine", on ? "on" : "off")
    if (!on) return
    // The battery going low ends it, and that has already happened.
    if (batteryLow) caffeineEnds.go()
    if (saverUp) {
      saverUp = false
      saverOff.go()
    }
  }

  IdleMonitor {
    id: saverWatch
    enabled: idle.minding && idle.saverAfter > 0
    timeout: Math.max(1, idle.saverAfter)
    respectInhibitors: true
    onIsIdleChanged: {
      idle.log("screensaver-monitor", isIdle ? "idle" : "active")
      if (isIdle && idle.minding && idle.saverAfter > 0) {
        idle.saverUp = true
        saverOn.go()
      } else if (!isIdle && idle.saverUp) {
        // A key ends the screensaver by itself; the mouse ends it here.
        idle.saverUp = false
        saverOff.go()
      }
    }
  }

  IdleMonitor {
    id: lockWatch
    enabled: idle.minding && idle.lockAfter > 0
    timeout: Math.max(1, idle.lockAfter)
    respectInhibitors: true
    onIsIdleChanged: {
      idle.log("lock-monitor", isIdle ? "idle" : "active")
      if (!isIdle || !idle.minding || idle.lockAfter <= 0) return
      idle.saverUp = false
      locking.go()
    }
  }

  // A command of the service's, logged as <step>; one still running is not
  // started again.
  component Step: Process {
    required property string step

    function go() {
      if (running) {
        idle.log(step + "-skip", "already running")
        return
      }
      idle.log(step)
      running = true
    }
  }

  // nova-screensaver auto leaves it be under the lock, or while it shows.
  Step {
    id: saverOn
    step: "screensaver"
    command: ["nova-screensaver", "auto"]
  }

  Step {
    id: saverOff
    step: "screensaver-stop"
    command: ["nova-screensaver", "stop"]
  }

  Step {
    id: locking
    step: "lock-system"
    command: ["nova-system-lock"]
    onExited: (code, status) => idle.log("process-exit", "lock exitCode=" + code + " status=" + status)
  }

  Step {
    id: caffeineEnds
    step: "caffeine-low-battery"
    command: ["nova-caffeine", "low-battery"]
  }

  // Reads the switch. Asked while it reads, it reads once more after, as
  // the switch may have flipped after it looked.
  Process {
    id: switchProbe
    property bool askedAgain: false
    command: ["test", "-f", idle.switchFile]

    function ask() {
      if (running) askedAgain = true
      else running = true
    }

    onExited: code => {
      idle.setCaffeine(code === 0)
      if (!askedAgain) return
      askedAgain = false
      running = true
    }
  }

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: switchProbe.ask()
  }

  Component.onCompleted: {
    log("service-ready")
    switchProbe.ask()
  }

  IpcHandler {
    target: "idle"

    // nova caffeine, after it flips the switch.
    function refresh(): string {
      switchProbe.ask()
      return "ok"
    }
  }
}
