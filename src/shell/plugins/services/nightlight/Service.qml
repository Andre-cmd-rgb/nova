import QtQuick
import Quickshell.Io

// The night light, hyprsunset's warmer screen, for the bar's switch.
// nova-toggle-nightlight does the switching, for the bar as for the keys and
// the menu: it waits out a hyprsunset still starting, and then has this
// service ask hyprsunset again (refresh).
Item {
  id: nightlight

  // hyprsunset's colour temperature in kelvin, or what a switch is setting
  // it to; null while hyprsunset is not running or cannot say. Under 6000 K
  // the screen counts as warmed, as nova-toggle-nightlight counts it.
  property var kelvin: null
  readonly property bool enabled: kelvin != null && kelvin < 6000

  // The state asked for while a switch runs, "on" or "off": the last one.
  property string waiting: ""

  // The bar's switch. It shows the night (4000 K) or the day (6500 K) at
  // once, as nova-toggle-nightlight sets them.
  function setNightlight(on) {
    kelvin = on ? 4000 : 6500
    var state = on ? "on" : "off"
    if (switching.running) waiting = state
    else switching.start(state)
  }

  function refresh() {
    if (!asking.running) asking.running = true
  }

  // hyprsunset answers with the number among some words; a failed call
  // means no hyprsunset to ask.
  Process {
    id: asking
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var number = String(text == null ? "" : text).match(/\d+/)
        nightlight.kelvin = number ? Number(number[0]) : null
      }
    }
    onExited: code => {
      if (code !== 0) nightlight.kelvin = null
    }
  }

  // When a switch ends: the one asked for meanwhile, or else a look at what
  // hyprsunset now says.
  Process {
    id: switching

    function start(state) {
      command = ["nova-toggle-nightlight", state]
      running = true
    }

    onExited: {
      var next = nightlight.waiting
      nightlight.waiting = ""
      if (next) start(next)
      else nightlight.refresh()
    }
  }

  Component.onCompleted: refresh()

  IpcHandler {
    target: "nightlight"

    function refresh(): void {
      nightlight.refresh()
    }
  }
}
