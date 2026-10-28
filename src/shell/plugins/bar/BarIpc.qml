import QtQuick
import Quickshell.Io
import "BarModel.js" as Model

// One set of targets for all bar surfaces. Slots register with the bar as
// they appear and disappear, so unplugging a monitor leaves no stale routes.
Item {
  id: root

  required property var bar

  function candidates(target) {
    var slots = bar.moduleSlots
    var rows = []
    for (var i = 0; i < slots.length; i++) {
      var slot = slots[i]
      if (!slot || !slot.activeItem) continue
      var id = slot.activeItem.ipcTarget || slot.moduleName
      if (id !== target) continue
      rows.push({ slot: slot, screenName: bar.slotScreenName(slot), opened: slot.activeItem.opened === true })
    }
    return rows
  }

  function focused(target) {
    var slot = Model.pickPanelSlot(candidates(target), bar.focusedScreenName())
    return slot ? slot.activeItem : null
  }

  function callFocused(target, method, args) {
    var item = focused(target)
    if (item && typeof item[method] === "function") return item[method].apply(item, args || [])
    return ""
  }

  function callAll(target, method) {
    var rows = candidates(target)
    var chosen = focused(target)
    var result = ""
    for (var i = 0; i < rows.length; i++) {
      var item = rows[i].slot.activeItem
      if (typeof item[method] !== "function") continue
      var value = item[method]()
      if (item === chosen) result = value
    }
    return result
  }

  component PanelHandler: IpcHandler {
    enabled: root.candidates(target).length > 0

    function open(): void { root.callFocused(target, "open") }
    function close(): void { root.callFocused(target, "close") }
    function show(): void { root.callFocused(target, "open") }
    function hide(): void { root.callFocused(target, "close") }
    function toggle(): void {
      root.callFocused(target, target === "nova.clock" || target === "nova.weather" ? "togglePanel" : "toggle")
    }
  }

  PanelHandler { target: "nova.audio" }
  PanelHandler { target: "nova.mobile-data" }
  PanelHandler { target: "nova.batterylife.bar" }

  // These change shared hardware or shell.json. Run the change once; the
  // service signals and inline settings update every screen's copy.
  PanelHandler {
    target: "nova.bluetooth"
    function toggleBluetooth(): void { root.callFocused(target, "toggleBluetooth") }
  }

  PanelHandler {
    target: "nova.network"
    function toggleNetwork(): void { root.callFocused(target, "toggleNetwork") }
  }

  PanelHandler {
    target: "nova.power"
    function togglePercentage(): void { root.callFocused(target, "togglePercentage") }
  }

  PanelHandler {
    target: "nova.monitor"
    function brightness(percent: string): string { return root.callFocused(target, "brightnessIpc", [percent]) }
    function state(): string { return root.callAll(target, "stateIpc") }
  }

  PanelHandler {
    target: "nova.clock"
    function refresh(): void { root.callAll(target, "refresh") }
    function cycleFormat(): void { root.callFocused(target, "cycleFormat") }
    function toggleWeekStart(): void { root.callFocused(target, "toggleWeekStart") }
  }

  PanelHandler {
    target: "nova.weather"
    function edit(): void { root.callFocused(target, "edit") }
  }

  IpcHandler {
    target: "nova.indicators"
    enabled: root.candidates(target).length > 0
    function refresh(): void { root.callAll(target, "refresh") }
  }

  IpcHandler {
    target: "nova.system-update"
    enabled: root.candidates(target).length > 0
    function refresh(): void { root.callAll(target, "refresh") }
    function clear(): void { root.callAll(target, "clear") }
  }
}
