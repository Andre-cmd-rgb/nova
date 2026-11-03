import QtQuick
import Quickshell.Io
import "BarModel.js" as BarModel

// The IPC targets of the widgets on the bar, one of each for all the
// screens' bars: a call reaches the copy BarModel.pickPanelSlot picks, or
// every copy where each must hear it. A target answers while some bar shows
// its widget, which a widget names by its id or by its ipcTarget.
Item {
  id: ipc

  required property var bar

  function candidates(target) {
    return bar.moduleSlots.filter(function(slot) {
      return slot && slot.activeItem && (slot.activeItem.ipcTarget || slot.moduleName) === target
    }).map(function(slot) {
      return { slot: slot, screenName: bar.slotScreenName(slot), opened: slot.activeItem.opened === true }
    })
  }

  function chosen(target) {
    var slot = BarModel.pickPanelSlot(candidates(target), bar.focusedScreenName())
    return slot ? slot.activeItem : null
  }

  // Calls `method` on the chosen copy, and answers with what it returns.
  function callOne(target, method, args) {
    var item = chosen(target)
    return item && typeof item[method] === "function" ? item[method].apply(item, args || []) : ""
  }

  // Calls `method` on every copy, and answers with the chosen copy's answer.
  function callEach(target, method) {
    var answer = ""
    var one = chosen(target)
    candidates(target).forEach(function(row) {
      var item = row.slot.activeItem
      if (typeof item[method] !== "function") return
      var value = item[method]()
      if (item === one) answer = value
    })
    return answer
  }

  // open, close and toggle, with show and hide as other names for the first
  // two. The clock's and the weather's panel toggles are togglePanel: their
  // toggle is the label's.
  component PanelTarget: IpcHandler {
    enabled: ipc.candidates(target).length > 0

    function open(): void { ipc.callOne(target, "open") }
    function close(): void { ipc.callOne(target, "close") }
    function show(): void { ipc.callOne(target, "open") }
    function hide(): void { ipc.callOne(target, "close") }
    function toggle(): void { ipc.callOne(target, target === "nova.clock" || target === "nova.weather" ? "togglePanel" : "toggle") }
  }

  PanelTarget { target: "nova.audio" }
  PanelTarget { target: "nova.mobile-data" }
  PanelTarget { target: "nova.batterylife.bar" }

  // A switch of shared hardware or of shell.json is made once, by the chosen
  // copy; the others follow the service or the settings it changed.
  PanelTarget {
    target: "nova.bluetooth"
    function toggleBluetooth(): void { ipc.callOne(target, "toggleBluetooth") }
  }

  PanelTarget {
    target: "nova.network"
    function toggleNetwork(): void { ipc.callOne(target, "toggleNetwork") }
  }

  PanelTarget {
    target: "nova.power"
    function togglePercentage(): void { ipc.callOne(target, "togglePercentage") }
  }

  PanelTarget {
    target: "nova.monitor"
    function brightness(percent: string): string { return ipc.callOne(target, "brightnessIpc", [percent]) }
    function state(): string { return ipc.callEach(target, "stateIpc") }
  }

  PanelTarget {
    target: "nova.clock"
    function refresh(): void { ipc.callEach(target, "refresh") }
    function cycleFormat(): void { ipc.callOne(target, "cycleFormat") }
    function toggleWeekStart(): void { ipc.callOne(target, "toggleWeekStart") }
  }

  PanelTarget {
    target: "nova.weather"
    function edit(): void { ipc.callOne(target, "edit") }
  }

  IpcHandler {
    target: "nova.indicators"
    enabled: ipc.candidates(target).length > 0
    function refresh(): void { ipc.callEach(target, "refresh") }
  }

  IpcHandler {
    target: "nova.system-update"
    enabled: ipc.candidates(target).length > 0
    function refresh(): void { ipc.callEach(target, "refresh") }
    function clear(): void { ipc.callEach(target, "clear") }
  }
}
