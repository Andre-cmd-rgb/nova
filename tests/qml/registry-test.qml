import QtQuick
import Quickshell
import "services"

// The plugin registry against the real, generated plugin index and a config
// held in memory: what is on, where enabling puts a widget, and what each verb
// writes into shell.json.
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
  property bool ran: false

  property PluginRegistry registry: PluginRegistry {
    shellConfigProvider: function() { return test.config }
    shellConfigMutator: function(mutate) {
      var copy = JSON.parse(JSON.stringify(test.config))
      mutate(copy)
      test.config = copy
    }
    onPluginsChanged: if (!loading && !test.ran) test.run()
  }

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function ids(section) {
    return config.bar.layout[section].map(function(entry) { return entry.id }).join(" ")
  }

  function run() {
    ran = true
    var plugins = registry.installedPlugins
    check(Object.keys(plugins).length === Number(Quickshell.env("TEST_PLUGIN_COUNT")),
      "every plugin in the index is installed")
    check(String(registry.entryPointUrl(plugins["nova.clock"], "barWidget"))
      === "file://" + Quickshell.env("TEST_PLUGINS") + "/panels/clock/BarWidget.qml",
      "an entry point resolves inside its plugin's directory")
    check(registry.entryPointUrl(plugins["nova.clock"], "panel") === "", "a kind without an entry point has no URL")

    check(registry.isEnabled("nova.bar") && registry.isEnabled("nova.lock") && registry.isEnabled("nova.weather"),
      "built-ins are on without being named")
    check(!registry.isEnabled("nova.screentime"), "Screen Time is off until it is named")
    check(registry.inBar("nova.clock") && !registry.inBar("nova.weather"), "inBar is the bar layout")

    check(registry.setEnabled("nova.screentime", true) && ids("right") === "nova.tray nova.screentime nova.network nova.audio",
      "enabling a widget puts it in its section, after the anchor: " + ids("right"))
    check(registry.isEnabled("nova.screentime") && registry.inBar("nova.screentime"), "an enabled widget is on and in the bar")
    check(registry.setEnabled("nova.screentime", false) && !registry.isEnabled("nova.screentime")
      && ids("right") === "nova.tray nova.network nova.audio", "disabling Screen Time takes it off the bar and off")

    check(registry.setEnabled("nova.lock", false) && !registry.isEnabled("nova.lock")
      && JSON.stringify(config.disabledPlugins) === '["nova.lock"]', "switching off a built-in is recorded")
    check(registry.setEnabled("nova.lock", true) && registry.isEnabled("nova.lock") && config.disabledPlugins === undefined,
      "switching it back on removes the record")

    check(registry.putBarWidget("nova.weather", { section: "center", after: "nova.clock" }) === ""
      && ids("center") === "nova.indicators nova.clock nova.weather", "put places a widget: " + ids("center"))
    check(registry.putBarWidget("nova.weather", { section: "center", before: "nova.indicators" }) === ""
      && ids("center") === "nova.indicators nova.clock nova.weather", "put leaves a placed widget alone")
    check(registry.putBarWidget("nova.power", { after: "nova.nowhere" }) === ""
      && ids("center") === "nova.indicators nova.clock nova.weather nova.power",
      "put falls back to the default place when its anchor is missing: " + ids("center"))

    check(!registry.setEnabled("nova.bluetooth", true, { before: "nova.nowhere" })
      && registry.lastEnableError === "could not find target widget nova.nowhere" && !registry.inBar("nova.bluetooth"),
      "enable with a missing anchor fails and changes nothing")
    check(registry.moveBarWidget("nova.weather", { section: "right", before: "nova.audio" }) === ""
      && ids("right") === "nova.tray nova.network nova.weather nova.audio"
      && ids("center") === "nova.indicators nova.clock nova.power", "move: " + ids("right"))
    check(registry.setBarWidget("nova.clock", "format", "HH:mm", {}) === ""
      && config.bar.layout.center[1].format === "HH:mm", "setBarWidget writes the entry's setting")

    var before = JSON.stringify(config)
    check(registry.setEnabled("nova.bar", false) && registry.isEnabled("nova.bar") && JSON.stringify(config) === before,
      "the bar has no off")
    console.log("DONE")
    Qt.quit()
  }

  Component.onCompleted: registry.pluginsDir = Quickshell.env("TEST_PLUGINS")
}
