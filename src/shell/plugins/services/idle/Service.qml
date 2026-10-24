import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland

Item {
  id: root

  // Injected by nova-shell (the first-party service loader).
  property var shell: null

  // Caffeine's switch (nova caffeine): while the file is there, nothing here
  // starts the screensaver or locks. nova caffeine asks for a refresh when it
  // flips it, and a slow look now and then catches one that could not reach
  // the shell (a restart, say).
  readonly property string caffeinePath: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/caffeine"
  readonly property int defaultScreensaverSeconds: 180
  readonly property int defaultLockSeconds: 300
  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle
    ? shell.shellConfig.idle : ({})
  // idle.screensaver and idle.lock in shell.json: seconds unused before the
  // screensaver starts and before the screen locks, and 0 for never. The lock
  // plugin turns the displays off and back on.
  readonly property int screensaverTimeoutSeconds: secondsFromConfig(idleConfig.screensaver, defaultScreensaverSeconds)
  readonly property int lockTimeoutSeconds: secondsFromConfig(idleConfig.lock, defaultLockSeconds)
  readonly property bool screensaverEnabled: screensaverTimeoutSeconds > 0
  readonly property bool lockEnabled: lockTimeoutSeconds > 0
  readonly property bool idleEnabled: caffeineStateLoaded && !caffeine

  property bool caffeine: false
  property bool caffeineStateLoaded: false
  property bool caffeineProbeAgain: false
  // Caffeine on battery lasts until the battery is low, so a laptop left
  // with its lid shut does not run flat: then nova caffeine ends it.
  readonly property bool batteryLow: UPower.onBattery && !!UPower.displayDevice
    && UPower.displayDevice.isLaptopBattery && UPower.displayDevice.percentage <= 0.10
  // Started by this service since the last input, so input stops it again.
  property bool screensaverShown: false
  property string lastEvent: "starting"
  property string lastEventAt: ""

  function secondsFromConfig(value, fallback) {
    var n = Number(value)
    if (!isFinite(n) || n < 0) return fallback
    return Math.floor(n)
  }

  function logEvent(event, details) {
    var suffix = details === undefined || details === null || details === "" ? "" : ": " + String(details)
    root.lastEventAt = new Date().toISOString()
    root.lastEvent = event + suffix
    console.log("nova idle " + root.lastEventAt + " " + root.lastEvent)
  }

  function run(process, what) {
    if (process.running) {
      logEvent(what + "-skip", "already running")
      return
    }
    logEvent(what)
    process.running = true
  }

  function handleScreensaverIdleChanged() {
    logEvent("screensaver-monitor", screensaverMonitor.isIdle ? "idle" : "active")
    if (screensaverMonitor.isIdle) {
      if (!root.idleEnabled || !root.screensaverEnabled) return
      root.screensaverShown = true
      run(screensaverProcess, "screensaver")
    } else if (root.screensaverShown) {
      // A key ends the screensaver by itself; the mouse ends it here.
      root.screensaverShown = false
      run(screensaverStopProcess, "screensaver-stop")
    }
  }

  function handleLockIdleChanged() {
    logEvent("lock-monitor", lockMonitor.isIdle ? "idle" : "active")
    if (root.idleEnabled && root.lockEnabled && lockMonitor.isIdle) {
      root.screensaverShown = false
      run(lockProcess, "lock-system")
    }
  }

  // A request that arrives while a probe runs is answered by one more after
  // it, since that probe may have read the switch before it flipped.
  function refreshCaffeine() {
    if (caffeineProbe.running) caffeineProbeAgain = true
    else caffeineProbe.running = true
  }

  onBatteryLowChanged: if (batteryLow && caffeine) run(caffeineLowBatteryProcess, "caffeine-low-battery")

  function applyCaffeine(on) {
    var changed = !root.caffeineStateLoaded || root.caffeine !== on
    root.caffeine = on
    root.caffeineStateLoaded = true
    if (!changed) return
    logEvent("caffeine", on ? "on" : "off")
    if (on && root.screensaverShown) {
      root.screensaverShown = false
      run(screensaverStopProcess, "screensaver-stop")
    }
  }

  function statusJson() {
    return JSON.stringify({
      enabled: root.idleEnabled,
      caffeine: root.caffeine,
      caffeineStateLoaded: root.caffeineStateLoaded,
      caffeinePath: root.caffeinePath,
      idle: lockMonitor.isIdle,
      screensaver: root.screensaverTimeoutSeconds,
      lock: root.lockTimeoutSeconds,
      locking: lockProcess.running,
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt
    })
  }

  IdleMonitor {
    id: screensaverMonitor
    enabled: root.idleEnabled && root.screensaverEnabled
    timeout: Math.max(1, root.screensaverTimeoutSeconds)
    respectInhibitors: true
    onIsIdleChanged: root.handleScreensaverIdleChanged()
  }

  IdleMonitor {
    id: lockMonitor
    enabled: root.idleEnabled && root.lockEnabled
    timeout: Math.max(1, root.lockTimeoutSeconds)
    respectInhibitors: true
    onIsIdleChanged: root.handleLockIdleChanged()
  }

  // nova-screensaver auto leaves it be when the screen is locked or it is
  // already showing.
  Process {
    id: screensaverProcess
    command: ["nova-screensaver", "auto"]
  }

  Process {
    id: screensaverStopProcess
    command: ["nova-screensaver", "stop"]
  }

  Process {
    id: lockProcess
    command: ["nova-system-lock"]
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "lock exitCode=" + exitCode + " status=" + exitStatus) }
  }

  Process {
    id: caffeineProbe
    command: ["test", "-f", root.caffeinePath]
    onExited: function(exitCode) {
      root.applyCaffeine(exitCode === 0)
      if (root.caffeineProbeAgain) {
        root.caffeineProbeAgain = false
        running = true
      }
    }
  }

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.refreshCaffeine()
  }

  Process {
    id: caffeineLowBatteryProcess
    command: ["nova-caffeine", "low-battery"]
  }

  Component.onCompleted: {
    logEvent("service-ready")
    refreshCaffeine()
  }

  IpcHandler {
    target: "idle"

    function status(): string {
      return root.statusJson()
    }

    // nova caffeine, after it flips the switch.
    function refresh(): string {
      root.refreshCaffeine()
      return "ok"
    }
  }
}
