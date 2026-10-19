import QtQuick
import Quickshell.Io
import Quickshell.Services.UPower

// The part that keeps the record. It asks the CLI for a sample on a cadence,
// and again whenever the power source changes, so the boundary between one
// discharge run and the next is written down at the moment it happens rather
// than up to a minute late.
//
// Deliberately thin: nothing is aggregated here and nothing is held in memory
// between samples. A shell restart costs one sample, and every question about
// the data is answered by the CLI instead.
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/batterylife")).replace(/^file:\/\//, ""))

  // Settings live in the CLI's config file — one place to change them, and no
  // second copy in shell.json that could disagree with it.
  property int batteryInterval: 60
  property int acInterval: 300

  readonly property bool onBattery: UPower.onBattery
  readonly property int interval: (onBattery ? batteryInterval : acInterval) * 1000

  signal sampled()

  function sample() {
    // A sample still in flight is a sample: asking twice writes two rows a
    // few milliseconds apart, which is noise in every average downstream.
    if (sampleProc.running) return
    sampleProc.running = true
  }

  Component.onCompleted: {
    loadSettings()
    sample()
  }

  function loadSettings() {
    if (!batteryProc.running) batteryProc.running = true
    if (!acProc.running) acProc.running = true
  }

  Process {
    id: sampleProc
    command: [root.helper, "sample"]
    onExited: root.sampled()
  }

  Process {
    id: batteryProc
    command: [root.helper, "config", "SAMPLE_INTERVAL"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = parseInt(String(text).trim(), 10)
        if (isFinite(value) && value >= 10) root.batteryInterval = value
      }
    }
  }

  Process {
    id: acProc
    command: [root.helper, "config", "AC_INTERVAL"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = parseInt(String(text).trim(), 10)
        if (isFinite(value) && value >= 10) root.acInterval = value
      }
    }
  }

  // Plugging in or pulling the plug ends one run and starts another. Both
  // sides want a reading: the one that closes the run, and the one that opens
  // the next at a known charge.
  Connections {
    target: UPower
    function onOnBatteryChanged() { root.sample() }
  }

  Timer {
    interval: root.interval
    running: true
    repeat: true
    onTriggered: root.sample()
  }

  // A resume is the one moment a sample is worth more than usual: the charge
  // reading either side of a suspend is the only evidence of what it cost,
  // and the timer above cannot have fired while the machine was down.
  //
  // Detected the same way the rest of this machine's power tooling does it —
  // by the wall clock moving further than the interval that was slept — since
  // nothing here is privileged enough to hear about it from logind.
  property real lastTick: 0
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now() / 1000
      if (root.lastTick > 0 && now - root.lastTick > 30) root.sample()
      root.lastTick = now
    }
  }

  // Settings are read from disk rather than watched; a ten-minute refresh is
  // soon enough for a value someone changes by hand every few months.
  Timer {
    interval: 600000
    running: true
    repeat: true
    onTriggered: root.loadSettings()
  }
}
