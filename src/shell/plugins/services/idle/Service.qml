import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland
import qs.Commons

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
  // for a refresh; the bar's cup shows `caffeine`.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova"
  readonly property string switchFile: runtimeDir + "/caffeine"
  property bool caffeine: false
  property bool switchRead: false
  // The apps keeping the screen awake through org.freedesktop.ScreenSaver
  // (nova-sessiond writes this file while any does, one
  // "app<TAB>reason" a line), as "app: reason".
  readonly property string inhibitorsFile: runtimeDir + "/idle-inhibitors"
  property var inhibitors: []
  // Someone's absence counts: the switch read, Caffeine off, and no app
  // keeping the screen awake.
  readonly property bool minding: switchRead && !caffeine && inhibitors.length === 0

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

  // The inhibitors file's text as "app: reason" entries.
  function setInhibitors(text) {
    var found = []
    for (const line of String(text || "").split("\n")) {
      const tab = line.indexOf("\t")
      const app = (tab < 0 ? line : line.substring(0, tab)).trim()
      const reason = tab < 0 ? "" : line.substring(tab + 1).trim()
      if (app !== "") found.push(reason !== "" ? app + ": " + reason : app)
    }
    if (found.join("\n") === inhibitors.join("\n")) return
    inhibitors = found
    log("inhibitors", found.length > 0 ? found.join("; ") : "none")
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

  // An IdleMonitor counts with the timeout it was enabled with, so each is
  // off for a moment as its time changes (nova idle lock, a new shell.json):
  // the new time counts from then.
  IdleMonitor {
    id: saverWatch
    property bool retiming: false
    enabled: idle.minding && idle.saverAfter > 0 && !retiming
    timeout: Math.max(1, idle.saverAfter)
    respectInhibitors: true
    onTimeoutChanged: {
      retiming = true
      retiming = false
    }
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
    property bool retiming: false
    enabled: idle.minding && idle.lockAfter > 0 && !retiming
    timeout: Math.max(1, idle.lockAfter)
    respectInhibitors: true
    onTimeoutChanged: {
      retiming = true
      retiming = false
    }
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

  // Both files are watched, with no process to look and no clock: a
  // WatchedFile watches its file and the folder it is in, which tells it
  // when the file is made, replaced or removed, and reads it again after
  // each change, once more after a change that came while it read. The
  // folder has to be there for that, so it is made first, once. The switch
  // is on while it reads; no inhibitors file is nothing held.
  property bool watching: false

  Process {
    running: true
    command: ["mkdir", "-p", idle.runtimeDir]
    onExited: idle.watching = true
  }

  WatchedFile {
    id: switchView
    path: idle.watching ? idle.switchFile : ""
    onLoaded: idle.setCaffeine(true)
    onLoadFailed: idle.setCaffeine(false)
  }

  WatchedFile {
    id: inhibitorsView
    path: idle.watching ? idle.inhibitorsFile : ""
    onLoaded: idle.setInhibitors(text())
    onLoadFailed: idle.setInhibitors("")
  }

  Component.onCompleted: log("service-ready")

  IpcHandler {
    target: "idle"

    // nova caffeine, after it flips the switch.
    function refresh(): string {
      if (!idle.watching) return "ok"
      switchView.reload()
      inhibitorsView.reload()
      return "ok"
    }

    // What keeps the screen awake now, one a line: Caffeine, then the apps.
    function inhibitors(): string {
      return (idle.caffeine ? ["Caffeine"] : []).concat(idle.inhibitors).join("\n")
    }
  }
}
