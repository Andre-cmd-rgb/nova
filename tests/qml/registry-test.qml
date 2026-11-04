import QtQuick
import Quickshell
import "services"

// The plugin registry against the real, generated plugin index, a config held
// in memory and Nova's default layout: what is on, where enabling puts a
// widget, and what each verb writes into shell.json.
ShellRoot {
  id: test

  property var config: ({
    version: 1,
    bar: {
      layout: {
        left: [{ id: "nova.menu" }, { id: "nova.workspaces" }],
        center: [{ id: "nova.indicators" }, { id: "nova.clock" }],
        right: [{ id: "nova.tray" }, { id: "nova.network" }, { id: "nova.audio" }]
      }
    },
    plugins: []
  })
  // The right of data/defaults/shell.json, and a center without the weather.
  property var defaults: ({
    version: 1,
    bar: {
      layout: {
        left: [{ id: "nova.menu" }, { id: "nova.workspaces" }],
        center: [{ id: "nova.indicators" }, { id: "nova.clock" }],
        right: [{ id: "nova.tray" }, { id: "nova.bluetooth" }, { id: "nova.mobile-data" }, { id: "nova.network" },
          { id: "nova.audio" }, { id: "nova.power" }]
      }
    }
  })
  property bool ran: false

  property PluginRegistry registry: PluginRegistry {
    settings: QtObject {
      readonly property var current: test.config
      readonly property var defaults: test.defaults
      function edit(change) {
        var copy = JSON.parse(JSON.stringify(test.config))
        change(copy)
        test.config = copy
      }
    }
    onUpdated: if (ready && !test.ran) test.run()
  }

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function ids(section) {
    return config.bar.layout[section].map(function(entry) { return entry.id }).join(" ")
  }

  function run() {
    ran = true
    var plugins = registry.manifests
    check(Object.keys(plugins).length === Number(Quickshell.env("TEST_PLUGIN_COUNT")),
      "every plugin in the index is installed")
    check(String(registry.entryUrl(plugins["nova.clock"], "barWidget"))
      === "file://" + Quickshell.env("TEST_PLUGINS") + "/panels/clock/BarWidget.qml",
      "an entry point resolves inside its plugin's directory")
    check(registry.entryUrl(plugins["nova.clock"], "panel") === "", "a kind without an entry point has no URL")

    check(registry.isOn("nova.bar") && registry.isOn("nova.idle") && registry.isOn("nova.weather"),
      "built-ins are on without being named")
    check(!registry.isOn("nova.screentime"), "Screen Time is off until it is named")
    check(registry.inBar("nova.clock") && !registry.inBar("nova.weather"), "inBar is the bar layout")

    check(registry.setOn("nova.screentime", true) === "" && ids("right") === "nova.tray nova.screentime nova.network nova.audio",
      "enabling a widget puts it in its section, after the anchor: " + ids("right"))
    check(registry.isOn("nova.screentime") && registry.inBar("nova.screentime"), "an enabled widget is on and in the bar")
    check(registry.setOn("nova.screentime", false) === "" && !registry.isOn("nova.screentime")
      && ids("right") === "nova.tray nova.network nova.audio", "disabling Screen Time takes it off the bar and off")

    check(registry.setOn("nova.idle", false) === "" && !registry.isOn("nova.idle")
      && JSON.stringify(config.disabledPlugins) === '["nova.idle"]', "switching off a built-in is recorded")
    check(registry.setOn("nova.idle", true) === "" && registry.isOn("nova.idle") && config.disabledPlugins === undefined,
      "switching it back on removes the record")

    check(registry.put("nova.weather", { section: "center", after: "nova.clock" }) === ""
      && ids("center") === "nova.indicators nova.clock nova.weather", "put places a widget: " + ids("center"))
    check(registry.put("nova.weather", { section: "center", before: "nova.indicators" }) === ""
      && ids("center") === "nova.indicators nova.clock nova.weather", "put leaves a placed widget alone")
    check(registry.put("nova.power", { after: "nova.nowhere" }) === ""
      && ids("right") === "nova.tray nova.network nova.audio nova.power",
      "put falls back to the default place when its anchor is missing: " + ids("right"))

    check(registry.setOn("nova.bluetooth", true, { before: "nova.nowhere" }) === "could not find target widget nova.nowhere"
      && !registry.inBar("nova.bluetooth"),
      "enable with a missing anchor fails and changes nothing")
    check(registry.move("nova.weather", { section: "right", before: "nova.audio" }) === ""
      && ids("right") === "nova.tray nova.network nova.weather nova.audio nova.power"
      && ids("center") === "nova.indicators nova.clock", "move: " + ids("right"))
    check(registry.setOption("nova.clock", "format", "HH:mm", {}) === ""
      && config.bar.layout.center[1].format === "HH:mm", "setBarWidget writes the entry's setting")

    // Turned back on with no place given, a widget goes where the default
    // layout has it, not after the weather.
    check(registry.setOn("nova.bluetooth", true) === ""
      && ids("right") === "nova.tray nova.bluetooth nova.network nova.weather nova.audio nova.power",
      "a widget comes back before its next default neighbour: " + ids("right"))
    check(registry.setOn("nova.bluetooth", false) === "" && registry.put("nova.bluetooth", {}) === ""
      && ids("right") === "nova.tray nova.bluetooth nova.network nova.weather nova.audio nova.power",
      "off and on again, it is back in the same place: " + ids("right"))
    check(registry.setOn("nova.microphone", true) === ""
      && ids("right") === "nova.tray nova.microphone nova.bluetooth nova.network nova.weather nova.audio nova.power",
      "one the default layout lacks goes to its manifest's section: " + ids("right"))
    check(registry.setOn("nova.bluetooth", false) === "" && registry.put("nova.bluetooth", { section: "left" }) === ""
      && ids("left") === "nova.menu nova.workspaces nova.bluetooth", "a section asked for wins over the default place: " + ids("left"))

    var before = JSON.stringify(config)
    check(registry.setOn("nova.bar", false) !== "" && registry.isOn("nova.bar") && JSON.stringify(config) === before,
      "the bar has no off")
    check(registry.setOn("nova.lock", false) === "Lock Screen cannot be switched off"
      && registry.isOn("nova.lock") && JSON.stringify(config) === before, "nor has the lock")
    config.disabledPlugins = ["nova.lock"]
    check(registry.isOn("nova.lock"), "the lock stays on even when shell.json lists it as off")
    console.log("DONE")
    Qt.quit()
  }

  // Before the index has loaded, nothing that writes shell.json goes through.
  Component.onCompleted: {
    var before = JSON.stringify(config)
    check(registry.setOn("nova.weather", false) === "not ready"
      && registry.put("nova.weather", {}) === "not ready"
      && registry.move("nova.clock", { section: "left" }) === "not ready"
      && registry.setOption("nova.clock", "format", "HH:mm", {}) === "not ready"
      && JSON.stringify(config) === before, "every verb waits for the index")
    registry.pluginsDir = Quickshell.env("TEST_PLUGINS")
  }
}
