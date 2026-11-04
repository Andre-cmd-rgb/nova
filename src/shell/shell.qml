import QtQuick
import Quickshell
import Quickshell.Io

import qs.Commons

import "plugins/bar"
import "services"
import "services/Layout.js" as Layout

// Nova's shell, the process the session runs as nova-shell. Its parts:
//
//   ShellJson       shell.json, Nova's and the user's: the config in effect
//   PluginRegistry  the installed plugins, which are on, and the verbs
//   PluginServices  a running object for each service that is on
//   Panels          a loader for each panel, overlay and menu that is on
//   BarWidgets      a component for each bar widget that is on
//   AppLibrary      the menu's apps
//
// and the bar. This file wires them together, and holds what the plugins
// reach of the shell (they are handed it as `shell`) and the IPC targets
// "shell" and "image-selector".
ShellRoot {
  id: nova

  readonly property string pluginsDir: Quickshell.env("NOVA_PATH") + "/shell/plugins"

  // --------------------------------------------------- what plugins reach

  readonly property AppLibrary appLibrary: AppLibrary { }

  // The config in effect, and its bar part.
  readonly property var shellConfig: shellJson.current
  readonly property var barConfig: shellConfig.bar

  readonly property var bar: barItem

  function serviceFor(id) {
    return pluginServices.serviceFor(id)
  }

  function summon(id, payload) {
    return panels.summon(id, payload)
  }

  function hide(id) {
    return panels.hide(id)
  }

  // Calls change(config) with a copy of the config in effect to change, and
  // saves it.
  function mutateShellConfig(change) {
    shellJson.edit(function(config) { change(config) })
  }

  // Writes a plugin's settings into its entries in shell.json (see
  // Layout.writeSettings). Saves, and answers true, only when an entry
  // changes, so that a binding that keeps sending the same settings does
  // not keep writing the file.
  function updateEntryInline(pluginId, settings) {
    return shellJson.edit(function(config) {
      return Layout.writeSettings(config, String(pluginId || ""), settings)
    })
  }

  // --------------------------------------------------------- the parts

  readonly property ShellJson shellJson: ShellJson { }

  readonly property PluginRegistry registry: PluginRegistry {
    settings: nova.shellJson
    pluginsDir: nova.shellJson.ready ? nova.pluginsDir : ""
  }

  readonly property BarWidgets barWidgets: BarWidgets {
    registry: nova.registry
  }

  readonly property Panels panels: Panels {
    registry: nova.registry
    shell: nova
  }

  PluginServices {
    id: pluginServices
    registry: nova.registry
    shell: nova
  }

  // In this order: the services first, the lock among them, so that it is
  // up before anything else is shown.
  Connections {
    target: nova.registry
    function onUpdated() {
      pluginServices.sync()
      nova.panels.sync()
      nova.barWidgets.sync()
    }
  }

  Bar {
    id: barItem
    barWidgetRegistry: nova.barWidgets
    barConfig: nova.barConfig
    shell: nova
  }

  Component.onCompleted: {
    var paths = {
      novaPath: Quickshell.env("NOVA_PATH"),
      shellDir: Quickshell.shellDir,
      pluginsDir: pluginsDir,
      defaultsPath: shellJson.defaultsPath,
      userConfigPath: shellJson.userPath
    }
    console.log("nova-shell paths", Object.keys(paths).map(name => name + "=" + paths[name]).join(" "))
  }

  // ---------------------------------------------------------------- IPC

  // A verb's answer: "ok" when done, else what was wrong, and JSON among its
  // words that does not parse "invalid <what>: <the error>".
  function ipcAnswer(what, verb) {
    try {
      return verb() || "ok"
    } catch (e) {
      return "invalid " + what + ": " + e
    }
  }

  // nova-theme's way in (src/theme/src/picker.rs): the picker's request as
  // words, the rows in base64, so that their tabs and newlines survive the
  // command line.
  IpcHandler {
    target: "image-selector"

    function open(imageDirs: string, rowsBase64: string, selectedImage: string, selectionFile: string, doneFile: string, showLabels: string, filterable: string): string {
      var imageRows = Util.decodeBase64(rowsBase64)
      var request = { imageDirs, imageRows, selectedImage, selectionFile, doneFile, showLabels, filterable }
      return nova.panels.summon("nova.image-picker", JSON.stringify(request)) ? "ok" : "unknown"
    }
  }

  // nova-shell's verbs.
  IpcHandler {
    target: "shell"

    function ping(): string {
      return "ok"
    }

    function reloadConfig(): string {
      nova.shellJson.reload()
      return "ok"
    }

    function setPluginEnabled(plugin: string, on: string): string {
      return nova.registry.setOn(plugin, on === "true") || "ok"
    }

    // Switches the widget on, but leaves it where it is when it is on the
    // bar already: a caller that cannot know whether it ran before does not
    // move a widget its owner placed.
    function putBarWidget(plugin: string, placement: string): string {
      return nova.ipcAnswer("placement", () => nova.registry.put(plugin, JSON.parse(placement || "{}")))
    }

    function moveBarWidget(plugin: string, placement: string): string {
      return nova.ipcAnswer("placement", () => nova.registry.move(plugin, JSON.parse(placement || "{}")))
    }

    function setBarWidget(plugin: string, key: string, value: string, selector: string): string {
      return nova.ipcAnswer("widget setting", () => nova.registry.setOption(plugin, key, JSON.parse(value), JSON.parse(selector || "{}")))
    }

    // The installed plugins as JSON, by name, then id: each with its id,
    // name, kinds, whether it is on, and whether it can be switched off (so
    // that a caller offering the verbs need not work that out). On, for a
    // widget, is in the bar: what switching it on or off changes, not
    // whether its component loads.
    function listPlugins(): string {
      var registry = nova.registry
      var rows = Object.keys(registry.manifests).map(id => {
        var manifest = registry.manifests[id]
        var fixed = registry.fixed(manifest)
        var on = registry.has(manifest, "bar-widget") ? registry.inBar(id) : registry.isOn(id)
        return { id: id, name: manifest.name, kinds: manifest.kinds, enabled: fixed || on, canDisable: !fixed }
      })
      var label = row => String(row.name || row.id)
      rows.sort((a, b) => label(a) !== label(b) ? (label(a) < label(b) ? -1 : 1) : String(a.id).localeCompare(String(b.id)))
      return JSON.stringify(rows)
    }

    function summon(plugin: string, payload: string): string {
      return nova.panels.summon(plugin, payload) ? "ok" : "unknown"
    }

    function hide(plugin: string): void {
      nova.panels.hide(plugin)
    }

    function toggle(plugin: string, payload: string): void {
      nova.panels.toggle(plugin, payload)
    }

    // Toggles the panel of the widget at <index> in a bar <section>: a
    // hotkey can mean "the third panel on the right", and keep meaning it
    // when the bar is rearranged. Answers the id toggled, or "unknown" when
    // no panel is there.
    function togglePanelAt(section: string, index: string): string {
      var plugin = typeof nova.bar.panelWidgetIdAt === "function" ? nova.bar.panelWidgetIdAt(section, index) : ""
      if (plugin) nova.panels.toggle(plugin, "{}")
      return plugin || "unknown"
    }

    // A method of a loaded plugin.
    function call(plugin: string, method: string, arg: string): string {
      return nova.panels.call(plugin, method, arg)
    }
  }
}
