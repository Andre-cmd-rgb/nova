import QtQuick
import Quickshell.Io
import qs.Commons
import "Layout.js" as Layout

// Nova's plugins: which are installed, from the index the package build
// writes (plugins/index.json, by tools/plugin-index), and which of them are
// on, by shell.json; and the verbs that switch one on or off and place, move
// and set up bar widgets. Every plugin ships in the package, so the index is
// read once, and nothing is scanned or watched. shell.qml makes the one
// registry.
QtObject {
  id: registry

  // shell.json (ShellJson): `current` is the config in effect, `defaults`
  // Nova's own, and edit(change) changes the former and saves it.
  required property var settings

  // The installed plugins' directory. shell.qml sets it once it has read
  // both shell.json files, and the index loads then. Until it has, `ready`
  // is false and every verb answers "not ready", so that nothing is written
  // from a config made without them.
  property string pluginsDir: ""
  property bool ready: false

  // { id: manifest }, in the index's order.
  property var manifests: ({})
  // { id: the plugin's directory }.
  property var dirs: ({})

  // Sent once the index has loaded, and whenever the config in effect
  // changes: what is on may have changed with it.
  signal updated()

  property Connections settingsWatch: Connections {
    target: registry.settings
    function onCurrentChanged() { registry.updated() }
  }

  function has(manifest, kind) {
    return !!manifest && manifest.kinds.indexOf(kind) >= 0
  }

  // The file:// URL of the plugin's entry point for <kind>, or "".
  function entryUrl(manifest, kind) {
    var file = manifest && Util.isPlainObject(manifest.entryPoints) ? manifest.entryPoints[kind] : ""
    var dir = manifest ? dirs[manifest.id] : ""
    return file && dir ? Util.fileUrl(dir + "/" + file) : ""
  }

  // A plugin that has no off: the bar, which is the desktop, and the lock,
  // which autologin counts on coming up first.
  function fixed(manifest) {
    return !!manifest && manifest.alwaysOn === true
  }

  // Whether the plugin's parts load. Plugins are on unless shell.json lists
  // them in disabledPlugins; one whose manifest says "enabledByDefault":
  // false (Screen Time) is on only while shell.json names it, in the bar or
  // in plugins, so that taking it off the bar switches it off. A fixed one
  // is on whatever shell.json says, an id with no plugin off.
  function isOn(id) {
    var manifest = manifests[String(id)]
    if (!manifest) return false
    if (fixed(manifest)) return true
    var config = settings.current
    if (Layout.isOff(config, id)) return false
    return manifest.enabledByDefault !== false || Layout.locate(config, id) !== null
  }

  // Whether the widget is in the bar: not the same as on, as a widget off
  // the bar still loads, to be put back, and a plugin that is a widget and
  // more (the menu) works on without its button.
  function inBar(id) {
    return Layout.find(settings.current, id, "") !== null
  }

  // The section a widget's manifest asks for, else the center.
  function askedSection(manifest) {
    var asked = manifest && Util.isPlainObject(manifest.barWidget) ? String(manifest.barWidget.defaultSection || "") : ""
    return Layout.SECTIONS.indexOf(asked) >= 0 ? asked : "center"
  }

  // ------------------------------------------------------------- the verbs
  //
  // Each answers "" when done and what was wrong otherwise, and saves
  // shell.json only when done.

  function move(id, placement) {
    if (!ready) return "not ready"
    if (settings.blocked) return settings.blocked
    var error = ""
    settings.edit(function(config) {
      Layout.shape(config)
      error = Layout.move(config, id, placement || {})
      return error === ""
    })
    return error
  }

  // The unattended verb: a widget in the bar already stays where its owner
  // put it, and a placement next to a widget this bar lacks gives way to
  // the default place.
  function put(id, placement) {
    // The IPC can ask before the index has loaded, and an id not read yet is
    // not one that does not exist.
    if (!ready) return "not ready"
    if (inBar(id)) return ""
    var wish = Util.isPlainObject(placement) ? Object.assign({}, placement) : {}
    var neighbour = String(wish.before || wish.after || "")
    if (neighbour && !Layout.find(settings.current, neighbour, String(wish.section || ""))) {
      delete wish.before
      delete wish.after
    }
    return setOn(id, true, wish)
  }

  function setOption(id, key, value, selector) {
    if (!ready) return "not ready"
    if (settings.blocked) return settings.blocked
    var error = ""
    settings.edit(function(config) {
      Layout.shape(config)
      error = Layout.setOption(config, id, key, value, selector)
      return error === ""
    })
    return error
  }

  // Switches a plugin on or off. A bar widget switched on goes where
  // <placement> says; with none, where Nova's default layout has it, else
  // to the section its manifest asks for. Any other plugin off by default
  // is named in plugins. Switched off, a widget leaves the bar, and any
  // other plugin on by default is listed in disabledPlugins.
  function setOn(id, on, placement) {
    if (!ready) return "not ready"
    if (settings.blocked) return settings.blocked
    var key = String(id)
    var manifest = manifests[key]
    if (on && !manifest) {
      console.warn("PluginRegistry.setEnabled: unknown plugin " + key)
      return "unknown"
    }
    if (fixed(manifest)) return on ? "" : manifest.name + " cannot be switched off"
    var error = ""
    settings.edit(function(config) {
      Layout.shape(config)
      if (on) error = switchOn(config, key, manifest, placement)
      else switchOff(config, key, manifest)
      return error === ""
    })
    return error
  }

  function switchOn(config, key, manifest, placement) {
    var neighbour = placement ? String(placement.before || placement.after || "") : ""
    if (neighbour && !Layout.find(config, neighbour, String(placement.section || "")))
      return "could not find target widget " + neighbour
    var widget = has(manifest, "bar-widget")
    var named = Layout.locate(config, key) !== null
    Layout.unmarkOff(config, key)
    if (widget && !named) {
      var spot = (Layout.namesPlace(placement) ? null : Layout.homePlace(config, settings.defaults, key))
        || Layout.place(config, placement || {}, askedSection(manifest))
      config.bar.layout[spot.section].splice(spot.index, 0, { id: key })
      return ""
    }
    if (!named && manifest.enabledByDefault === false) config.plugins.push({ id: key })
    if (widget && placement && Object.keys(placement).length > 0) Layout.move(config, key, placement)
    return ""
  }

  // <manifest> is null for an id no plugin has, which is taken off the bar
  // and out of plugins all the same.
  function switchOff(config, key, manifest) {
    var spot = Layout.locate(config, key)
    if (spot) spot.list.splice(spot.index, 1)
    // A widget is off once it is out of the bar; anything else built in is
    // on until it is listed as off.
    if (manifest && manifest.enabledByDefault !== false && !has(manifest, "bar-widget")) Layout.markOff(config, key)
  }

  // ---------------------------------------------------------- the index

  // index.json is [{ "dir": "<dir under plugins/>", "manifest": {...} }],
  // checked by the package build. An entry without an id or a list of
  // kinds is passed over.
  function load(text) {
    var entries = []
    try {
      entries = JSON.parse(String(text || "[]"))
    } catch (e) {
      console.warn("PluginRegistry: the plugin index is not JSON: " + e)
    }
    var found = ({})
    var where = ({})
    for (var entry of Array.isArray(entries) ? entries : []) {
      var manifest = entry ? entry.manifest : null
      if (!Util.isPlainObject(manifest) || !manifest.id || !Array.isArray(manifest.kinds)) continue
      found[manifest.id] = manifest
      where[manifest.id] = pluginsDir + "/" + String(entry.dir || "")
    }
    dirs = where
    manifests = found
    ready = true
    updated()
  }

  property FileView index: FileView {
    path: registry.pluginsDir ? registry.pluginsDir + "/index.json" : ""
    printErrors: false
    onLoaded: registry.load(text())
    // With no index there is no lock, no polkit agent and no widget: an
    // error, not a warning.
    onLoadFailed: function(error) {
      console.error("PluginRegistry: cannot read " + path + ": " + error)
      registry.load("")
    }
  }
}
