import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui as Ui
import "plugins/bar"

// Two screens without layer-shell windows. Calls go through the real IPC
// socket, with slots joining and leaving the same registry the bar uses.
ShellRoot {
  id: test

  property var targets: ["nova.audio", "nova.mobile-data", "nova.batterylife.bar",
    "nova.bluetooth", "nova.network", "nova.power", "nova.monitor", "nova.clock",
    "nova.weather", "nova.indicators", "nova.system-update"]
  property var steps: []
  property int step: 0
  property var current: null
  property string output: ""
  property string expectedScreen: "DP-2"

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  Item {
    id: fakeBar
    property var moduleSlots: []
    property string focusedOutput: "DP-2"
    function focusedScreenName() { return focusedOutput }
    function slotScreenName(slot) { return slot.screenName }
    function registerModuleSlot(slot) { moduleSlots = moduleSlots.concat([slot]) }
    function unregisterModuleSlot(slot) { moduleSlots = moduleSlots.filter(function(s) { return s !== slot }) }
  }

  BarIpc { id: ipc; bar: fakeBar }

  Component {
    id: slotComponent
    Item {
      id: slot
      required property string moduleName
      required property string screenName
      property alias activeItem: widget
      width: 20
      height: 20
      Component.onCompleted: fakeBar.registerModuleSlot(slot)
      Component.onDestruction: fakeBar.unregisterModuleSlot(slot)

      Ui.Panel {
        id: widget
        ipcTarget: slot.moduleName === "nova.batterylife" ? "nova.batterylife.bar" : ""
        property var calls: []
        function record(method) { calls = calls.concat([method]) }
        function open() { record("open") }
        function close() { record("close") }
        function toggle() { record("toggle") }
        function togglePanel() { record("togglePanel") }
        function refresh() { record("refresh") }
        function clear() { record("clear") }
        function edit() { record("edit") }
        function toggleBluetooth() { record("toggleBluetooth") }
        function toggleNetwork() { record("toggleNetwork") }
        function togglePercentage() { record("togglePercentage") }
        function cycleFormat() { record("cycleFormat") }
        function toggleWeekStart() { record("toggleWeekStart") }
        function brightnessIpc(percent) { record("brightness:" + percent); return "got " + percent }
        function stateIpc() { record("state"); return slot.screenName }
      }
    }
  }

  function slots(target) { return ipc.candidates(target).map(function(row) { return row.slot }) }

  function addCall(target, method, routed, all, args, response) {
    steps.push({
      command: ["call", "--", target, method].concat(args || []),
      before: function() {
        var items = slots(target)
        for (var i = 0; i < items.length; i++) items[i].activeItem.calls = []
      },
      after: function() {
        var items = slots(target)
        for (var i = 0; i < items.length; i++) {
          var expected = all || items[i].screenName === expectedScreen ? [routed] : []
          check(JSON.stringify(items[i].activeItem.calls) === JSON.stringify(expected),
            target + "." + method + " on " + items[i].screenName + ": " + items[i].activeItem.calls)
        }
        if (response !== undefined) check(output.trim() === response, target + "." + method + " reply: " + output.trim())
      }
    })
  }

  function run() {
    for (var i = 0; i < targets.length; i++) {
      var id = targets[i] === "nova.batterylife.bar" ? "nova.batterylife" : targets[i]
      slotComponent.createObject(fakeBar, { moduleName: id, screenName: "DP-1" })
      slotComponent.createObject(fakeBar, { moduleName: id, screenName: "DP-2" })
    }
    steps.push({ command: ["show"], after: function() {
      for (var i = 0; i < targets.length; i++) {
        var count = ipc.data.filter(function(item) { return item.target === targets[i] }).length
        check(count === 1, "one handler for " + targets[i])
        check(output.indexOf(targets[i]) !== -1, targets[i] + " is registered")
      }
    } })
    for (var t = 0; t < targets.length - 2; t++) {
      var target = targets[t]
      var toggle = target === "nova.clock" || target === "nova.weather" ? "togglePanel" : "toggle"
      addCall(target, "open", "open", false)
      addCall(target, "close", "close", false)
      addCall(target, "show", "open", false)
      addCall(target, "hide", "close", false)
      addCall(target, "toggle", toggle, false)
    }
    addCall("nova.weather", "edit", "edit", false)
    addCall("nova.clock", "refresh", "refresh", true)
    addCall("nova.indicators", "refresh", "refresh", true)
    addCall("nova.system-update", "refresh", "refresh", true)
    addCall("nova.system-update", "clear", "clear", true)
    addCall("nova.monitor", "state", "state", true, [], "DP-2")
    addCall("nova.monitor", "brightness", "brightness:42", false, ["42"], "got 42")
    var changes = [["nova.bluetooth", "toggleBluetooth"], ["nova.network", "toggleNetwork"],
      ["nova.power", "togglePercentage"], ["nova.clock", "cycleFormat"], ["nova.clock", "toggleWeekStart"]]
    for (var c = 0; c < changes.length; c++) addCall(changes[c][0], changes[c][1], changes[c][1], false)
    // A panel left open on the other monitor is the one hide and toggle reach.
    steps.push({ command: ["show"], before: function() {
      slots("nova.audio")[0].activeItem.controller.show()
      expectedScreen = "DP-1"
    } })
    addCall("nova.audio", "close", "close", false)
    addCall("nova.audio", "toggle", "toggle", false)
    steps.push({ command: ["show"], before: function() {
      slots("nova.audio")[0].activeItem.controller.hide()
      expectedScreen = "DP-2"
    } })
    addCall("nova.audio", "open", "open", false)
    steps.push({ command: ["show"], before: function() { fakeBar.focusedOutput = "DP-1"; expectedScreen = "DP-1" } })
    addCall("nova.audio", "open", "open", false)
    steps.push({ command: ["show"], before: function() {
      fakeBar.focusedOutput = "missing"
      slots("nova.audio")[0].width = 0
    } })
    addCall("nova.audio", "toggle", "toggle", false)
    steps.push({ command: ["show"], before: function() { fakeBar.focusedOutput = "" } })
    addCall("nova.audio", "open", "open", false)
    steps.push({ command: ["show"], before: function() {
      fakeBar.focusedOutput = "DP-2"
      var removed = fakeBar.moduleSlots.filter(function(slot) { return slot.screenName === "DP-2" })
      for (var i = 0; i < removed.length; i++) removed[i].destroy()
    }, after: function() { check(fakeBar.moduleSlots.length === targets.length, "unplugged slots leave the registry") } })
    addCall("nova.audio", "toggle", "toggle", false)
    addCall("nova.indicators", "refresh", "refresh", true)
    steps.push({ command: ["show"], before: function() {
      slotComponent.createObject(fakeBar, { moduleName: "nova.audio", screenName: "DP-2" })
      expectedScreen = "DP-2"
    } })
    addCall("nova.audio", "open", "open", false)
    next()
  }

  function next() {
    if (step === steps.length) {
      console.log("DONE")
      Qt.quit()
      return
    }
    current = steps[step++]
    if (current.before) current.before()
    output = ""
    client.command = ["qs", "ipc", "--pid", String(Quickshell.processId)].concat(current.command)
    client.running = true
  }

  Process {
    id: client
    stdout: StdioCollector { onStreamFinished: test.output = text }
    onExited: function(code) {
      test.check(code === 0, current.command.join(" ") + " exits " + code)
      if (current.after) current.after()
      Qt.callLater(test.next)
    }
  }

  Component.onCompleted: Qt.callLater(run)
}
