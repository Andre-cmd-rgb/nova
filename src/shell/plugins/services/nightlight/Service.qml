import QtQuick
import Quickshell.Io

// The night light: hyprsunset's colour temperature, which the bar's switch
// shows and flips. nova-toggle-nightlight does the switching, for the bar as
// for the keys and the menu: it waits out a hyprsunset still starting, and
// has this service look again when it is done.
Item {
  id: service

  // The script's night and day, shown at once while it sets them. Under
  // 6000 K the screen counts as warmed, as the script counts it.
  readonly property int nightTemperature: 4000
  readonly property int dayTemperature: 6500
  readonly property int warmBelow: 6000

  // In kelvin; null while hyprsunset is not running or cannot say.
  property var temperature: null
  property bool known: false
  readonly property bool enabled: known && temperature != null && temperature < warmBelow

  // A switch asked for while one runs, "on" or "off"; the last one wins.
  property string queued: ""

  function show(kelvin) {
    temperature = kelvin
    known = true
  }

  function refresh() {
    if (!probe.running) probe.running = true
  }

  function setNightlight(on) {
    show(on ? nightTemperature : dayTemperature)
    var state = on ? "on" : "off"
    if (switcher.running) queued = state
    else switcher.ask(state)
  }

  // The other way from now; true when that is on.
  function toggle() {
    var on = !enabled
    setNightlight(on)
    return on
  }

  // `hyprctl hyprsunset temperature` answers with the number in some words;
  // a failed call means no hyprsunset to ask.
  Process {
    id: probe
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var digits = /[0-9]+/.exec(String(text == null ? "" : text))
        service.show(digits ? Number(digits[0]) : null)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) service.show(null)
    }
  }

  // One switch at a time; when it ends, the one queued meanwhile, or a look
  // at what hyprsunset now says.
  Process {
    id: switcher

    function ask(state) {
      command = ["nova-toggle-nightlight", state]
      running = true
    }

    onExited: {
      var next = service.queued
      service.queued = ""
      if (next) ask(next)
      else service.refresh()
    }
  }

  Component.onCompleted: refresh()

  IpcHandler {
    target: "nightlight"

    function status(): string {
      return JSON.stringify({ enabled: service.enabled, temperature: service.temperature })
    }

    function refresh(): void {
      service.refresh()
    }

    function enable(): string {
      service.setNightlight(true)
      return "enabled"
    }

    function disable(): string {
      service.setNightlight(false)
      return "disabled"
    }

    function toggle(): string {
      return service.toggle() ? "enabled" : "disabled"
    }
  }
}
