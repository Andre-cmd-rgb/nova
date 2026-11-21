import QtQuick
import Quickshell.Io
import "BarModel.js" as BarModel

// The IPC targets of the widgets on the bar, one of each for all the
// screens' bars: a call reaches the copy BarModel.reached picks, or every
// copy where each must hear it. A target answers while some bar shows its
// widget.
//
// Of the bar it reads `slots`, `screenOf(slot)` and `focusedOutput`.
Item {
  id: ipc

  required property var bar

  // The widget a target is of: the one of its name, but for the battery
  // life's, whose plugin has a target of that name of its own.
  function widgetOf(target) {
    return target === "nova.batterylife.bar" ? "nova.batterylife" : target
  }

  // The live copies of widget <id>, as BarModel.reached takes them.
  function copies(id) {
    return bar.slots.filter(slot => !!slot.widget && slot.widgetId === id)
      .map(slot => ({ slot: slot, screen: bar.screenOf(slot), open: slot.widget.opened === true }))
  }

  function reached(id) {
    const slot = BarModel.reached(copies(id), bar.focusedOutput)
    return slot ? slot.widget : null
  }

  // <method> of the copy reached, with <args>; its answer, or "" when it
  // has no such method.
  function one(target, method, args) {
    const widget = reached(widgetOf(target))
    return widget && typeof widget[method] === "function" ? widget[method].apply(widget, args || []) : ""
  }

  // <method> of every copy; the answer is the reached copy's.
  function each(target, method) {
    const id = widgetOf(target)
    const answering = reached(id)
    let answer = ""
    for (const copy of copies(id)) {
      const widget = copy.slot.widget
      if (typeof widget[method] !== "function") continue
      const said = widget[method]()
      if (widget === answering) answer = said
    }
    return answer
  }

  component Target: IpcHandler {
    enabled: ipc.copies(ipc.widgetOf(target)).length > 0
  }

  // open, close and toggle, with show and hide as other names for the first
  // two. The clock's and the weather's panel toggles are togglePanel: their
  // toggle is the label's.
  component PanelTarget: Target {
    function open(): void { ipc.one(target, "open") }
    function close(): void { ipc.one(target, "close") }
    function show(): void { ipc.one(target, "open") }
    function hide(): void { ipc.one(target, "close") }
    function toggle(): void { ipc.one(target, target === "nova.clock" || target === "nova.weather" ? "togglePanel" : "toggle") }
  }

  PanelTarget { target: "nova.audio" }
  PanelTarget { target: "nova.mobile-data" }
  PanelTarget { target: "nova.batterylife.bar" }

  // A switch of shared hardware or of shell.json is made once, by the copy
  // reached; the others follow the service or the settings it changed.
  PanelTarget {
    target: "nova.bluetooth"
    function toggleBluetooth(): void { ipc.one(target, "toggleBluetooth") }
  }

  PanelTarget {
    target: "nova.network"
    function toggleNetwork(): void { ipc.one(target, "toggleNetwork") }
  }

  PanelTarget {
    target: "nova.power"
    function togglePercentage(): void { ipc.one(target, "togglePercentage") }
  }

  PanelTarget {
    target: "nova.monitor"
    function brightness(percent: string): string { return ipc.one(target, "brightnessIpc", [percent]) }
    function state(): string { return ipc.each(target, "stateIpc") }
  }

  PanelTarget {
    target: "nova.clock"
    function refresh(): void { ipc.each(target, "refresh") }
    function cycleFormat(): void { ipc.one(target, "cycleFormat") }
    function toggleWeekStart(): void { ipc.one(target, "toggleWeekStart") }
  }

  PanelTarget {
    target: "nova.weather"
    function edit(): void { ipc.one(target, "edit") }
  }

  Target {
    target: "nova.indicators"
    function refresh(): void { ipc.each(target, "refresh") }
  }

  // Its asking is its service's, which every copy shows.
  Target {
    target: "nova.system-update"
    function refresh(): void { ipc.one(target, "refresh") }
    function clear(): void { ipc.one(target, "clear") }
  }
}
