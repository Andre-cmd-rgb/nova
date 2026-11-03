import QtQuick
import Quickshell.Io
import "NightlightModel.js" as NightlightModel

// The night light: hyprsunset's colour temperature, which the bar's
// indicator shows and switches. nova-toggle-nightlight does the switching
// for the bar as for the keys and the menu, keeping it through a hyprsunset
// that is still starting, and has this service look again when it is done.
Item {
  id: root

  // nova-toggle-nightlight's night and day, shown at once while it sets them.
  readonly property int nightTemperature: 4000
  readonly property int dayTemperature: 6500

  property bool stateLoaded: false
  // In kelvin; null while hyprsunset is not running or cannot say.
  property var temperature: null
  readonly property bool enabled: stateLoaded && NightlightModel.isNightlight(temperature)

  // A switch asked for while another runs: "on", "off", or none. The last
  // one asked for wins.
  property string queued: ""

  function refresh() {
    if (!probe.running) probe.running = true
  }

  function setNightlight(on) {
    temperature = on ? nightTemperature : dayTemperature
    stateLoaded = true
    var state = on ? "on" : "off"
    if (switcher.running) {
      queued = state
      return
    }
    switcher.command = ["nova-toggle-nightlight", state]
    switcher.running = true
  }

  function toggle() {
    setNightlight(!enabled)
  }

  Process {
    id: probe
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.temperature = NightlightModel.temperatureFromOutput(text)
        root.stateLoaded = true
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) return
      root.temperature = null
      root.stateLoaded = true
    }
  }

  Process {
    id: switcher
    onExited: {
      if (!root.queued) {
        root.refresh()
        return
      }
      command = ["nova-toggle-nightlight", root.queued]
      root.queued = ""
      running = true
    }
  }

  Component.onCompleted: refresh()

  IpcHandler {
    target: "nightlight"

    function status(): string {
      return JSON.stringify({ enabled: root.enabled, temperature: root.temperature })
    }

    function refresh(): void {
      root.refresh()
    }

    function enable(): string {
      root.setNightlight(true)
      return "enabled"
    }

    function disable(): string {
      root.setNightlight(false)
      return "disabled"
    }

    function toggle(): string {
      var enabling = !root.enabled
      root.setNightlight(enabling)
      return enabling ? "enabled" : "disabled"
    }
  }
}
