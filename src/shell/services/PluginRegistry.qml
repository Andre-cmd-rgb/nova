import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The plugins and what is on: the installed plugins, read from the index the
// package build writes (plugins/index.json, by tools/plugin-index), and the
// verbs that switch a plugin on or off and place, move and set up bar
// widgets in shell.json. Every plugin is Nova's own and ships in the
// package, so the index is read once at startup; there is nothing to scan or
// watch.
//
// shell.qml makes one and hands it to the plugins that need it, like
// BarWidgetRegistry and for the same reason.
QtObject {
  id: registry

  // The installed plugins' directory. shell.qml sets it once it has read the
  // user's shell.json, and the index loads then; until it has, loading holds
  // and every verb that writes shell.json answers "not ready", so that no
  // default is written over a file not read yet.
  property string pluginsDir: ""

  // Set by shell.qml, which owns shell.json: shellConfigProvider() gives the
  // config in effect, shellConfigMutator(change) calls change(config) with a
  // deep copy to edit in place and saves the result, and defaultsProvider()
  // gives Nova's default shell.json (see defaultBarPlace).
  property var shellConfigProvider: null
  property var shellConfigMutator: null
  property var defaultsProvider: null

  // { pluginId: manifest }, each manifest with __sourceDir added: its
  // directory.
  property var installedPlugins: ({})
  property int registryRevision: 0
  property bool loading: true
  // Why the last setEnabled said no, or "".
  property string lastEnableError: ""

  // Sent after the index loads and after each verb that changed shell.json.
  signal pluginsChanged()

  // The URL of the manifest's entry point for <kind>, or "" when it has none.
  function entryPointUrl(manifest, kind) {
    var points = Util.isPlainObject(manifest) && Util.isPlainObject(manifest.entryPoints) ? manifest.entryPoints : null
    var file = points ? points[kind] : ""
    if (!file || !manifest.__sourceDir) return ""
    return Util.fileUrl(manifest.__sourceDir + "/" + file)
  }

  function hasKind(manifest, kind) {
    return Boolean(manifest) && manifest.kinds.indexOf(kind) >= 0
  }

  // A plugin that cannot be switched off: the bar, which is the desktop, and
  // the lock, which autologin relies on coming up first.
  function alwaysOn(manifest) {
    return Boolean(manifest) && manifest.alwaysOn === true
  }

  // Plugins are on unless shell.json lists them in disabledPlugins. One whose
  // manifest says "enabledByDefault": false (Screen Time) is on only while
  // shell.json names it, in the bar layout or in plugins, so that taking it
  // off the bar switches it off.
  function onByDefault(manifest) {
    return Boolean(manifest) && manifest.enabledByDefault !== false
  }

  // Whether the plugin's components load. An alwaysOn plugin is on whatever
  // shell.json says; an id with no plugin is on while shell.json names it.
  function isEnabled(id) {
    var key = Util.canonicalWidgetId(String(id))
    var manifest = installedPlugins[key]
    var config = shellConfigProvider ? shellConfigProvider() : null
    if (manifest && alwaysOn(manifest)) return true
    if (manifest && isDisabled(config, key)) return false
    if (manifest && onByDefault(manifest)) return true
    return findEntryLocation(config, key).found
  }

  function isDisabled(config, id) {
    if (!Util.isPlainObject(config) || !Array.isArray(config.disabledPlugins)) return false
    return config.disabledPlugins.indexOf(Util.canonicalWidgetId(String(id))) >= 0
  }

  // Whether the widget sits in the bar. Not the same as isEnabled: a widget
  // off the bar stays loadable so that it can be put back, and a plugin that
  // is both a widget and something else (the menu) keeps working without its
  // button.
  function inBar(id) {
    var config = shellConfigProvider ? shellConfigProvider() : null
    return findEntryLocation(config, id).kind === "bar"
  }

  // The section the manifest asks for, or center.
  function defaultBarWidgetSection(manifest) {
    var wanted = manifest && Util.isPlainObject(manifest.barWidget) ? String(manifest.barWidget.defaultSection || "") : ""
    return wanted === "left" || wanted === "center" || wanted === "right" ? wanted : "center"
  }

  // The id of a bar layout entry, which is either { id, ...settings } or the
  // bare id.
  function barEntryId(entry) {
    return Util.canonicalWidgetId(String(Util.isPlainObject(entry) ? entry.id : (entry || "")))
  }

  // Where the widget is in the bar, looking only in <section> when one is
  // given: { found: true, kind: "bar", section, index }, or { found: false }.
  function findBarLocation(config, id, section) {
    var layout = Util.isPlainObject(config) && Util.isPlainObject(config.bar) ? config.bar.layout : null
    if (!Util.isPlainObject(layout)) return { found: false }
    var key = Util.canonicalWidgetId(String(id))
    var names = ["left", "center", "right"]
    for (var n = 0; n < names.length; n++) {
      if (section && section !== names[n]) continue
      var entries = layout[names[n]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        if (barEntryId(entries[i]) === key) return { found: true, kind: "bar", section: names[n], index: i }
      }
    }
    return { found: false }
  }

  // Where shell.json names the plugin: in the bar, else in plugins as
  // { found: true, kind: "plugin", index }, or { found: false }.
  function findEntryLocation(config, id) {
    if (!Util.isPlainObject(config)) return { found: false }
    var key = Util.canonicalWidgetId(String(id))
    var inLayout = findBarLocation(config, key, "")
    if (inLayout.found || !Array.isArray(config.plugins)) return inLayout
    for (var i = 0; i < config.plugins.length; i++) {
      var named = config.plugins[i]
      if (named && Util.canonicalWidgetId(named.id) === key) return { found: true, kind: "plugin", index: i }
    }
    return { found: false }
  }

  // Where a placement puts a widget: { section, index }, or { error }. Next
  // to the widget it names before or after, else at its index, else after
  // the section's anchor widget, else at the end. Its section is the one it
  // names, or <fallbackSection>, whose list this makes if the layout lacks
  // it.
  function barTarget(config, placement, fallbackSection) {
    var target = placement || {}
    var named = String(target.section || "")
    var section = named === "left" || named === "center" || named === "right" ? String(target.section) : fallbackSection

    var relativeId = String(target.before || target.after || "")
    if (relativeId) {
      var relative = findBarLocation(config, relativeId, section && target.section ? section : "")
      if (!relative.found) return { error: "could not find target widget " + relativeId }
      return { section: relative.section, index: target.after ? relative.index + 1 : relative.index }
    }

    var layout = config.bar.layout
    if (!Array.isArray(layout[section])) layout[section] = []
    var length = layout[section].length
    if (target.index !== undefined && target.index !== null)
      return { section: section, index: Math.min(Math.max(0, Math.floor(Number(target.index))), length) }

    var anchorIds = { left: "nova.workspaces", center: "nova.weather", right: "nova.tray" }
    var anchor = findBarLocation(config, anchorIds[section], section)
    return { section: section, index: anchor.found ? anchor.index + 1 : length }
  }

  // Whether a placement names a place at all; {} leaves it to the defaults.
  function namesPlace(placement) {
    if (!Util.isPlainObject(placement)) return false
    var fields = ["section", "index", "before", "after"]
    for (var i = 0; i < fields.length; i++) {
      var value = placement[fields[i]]
      if (value !== undefined && value !== null && value !== "") return true
    }
    return false
  }

  // Where Nova's default layout keeps a widget, in this bar: its section
  // there, before the first of its later neighbours there that this bar has,
  // or else after the nearest earlier one, or else at the section's end.
  // Null for a widget the default layout does not have.
  function defaultBarPlace(config, key) {
    var defaults = defaultsProvider ? defaultsProvider() : null
    var home = findBarLocation(defaults, key, "")
    if (!home.found) return null
    var neighbours = defaults.bar.layout[home.section]
    var near
    for (var after = home.index + 1; after < neighbours.length; after++) {
      near = findBarLocation(config, barEntryId(neighbours[after]), home.section)
      if (near.found) return { section: home.section, index: near.index }
    }
    for (var before = home.index - 1; before >= 0; before--) {
      near = findBarLocation(config, barEntryId(neighbours[before]), home.section)
      if (near.found) return { section: home.section, index: near.index + 1 }
    }
    return { section: home.section, index: config.bar.layout[home.section].length }
  }

  // Moves the widget within <config> to where <placement> says (barTarget),
  // from placement.fromSection[fromIndex] when given, else from wherever it
  // is (in fromSection, if named). "" when done, else what was wrong, and
  // the layout as it was.
  function moveBarEntry(config, id, placement) {
    var key = Util.canonicalWidgetId(String(id))
    var from

    if (placement.fromIndex !== undefined && placement.fromIndex !== null) {
      var fromSection = String(placement.fromSection || "")
      if (!fromSection) return "from-index requires from-section"
      var at = Math.floor(Number(placement.fromIndex))
      var list = config.bar.layout[fromSection]
      if (!Array.isArray(list) || at < 0 || at >= list.length) return "no widget at " + fromSection + "[" + at + "]"
      if (barEntryId(list[at]) !== key) return "widget at " + fromSection + "[" + at + "] is not " + key
      from = { found: true, section: fromSection, index: at }
    } else {
      from = findBarLocation(config, key, String(placement.fromSection || ""))
      if (!from.found) return "could not find widget " + key
    }

    var layout = config.bar.layout
    var moving = layout[from.section][from.index]
    layout[from.section].splice(from.index, 1)
    var to = barTarget(config, placement, from.section)
    if (to.error) {
      layout[from.section].splice(from.index, 0, moving)
      return to.error
    }
    layout[to.section].splice(to.index, 0, moving)
    return ""
  }

  // moveBarWidget, putBarWidget and setBarWidget, for IPC and settings,
  // answer "" when done and what was wrong otherwise.

  function moveBarWidget(id, placement) {
    if (loading) return "not ready"
    var error = ""
    shellConfigMutator(function(config) {
      ensureConfigShape(config)
      error = moveBarEntry(config, id, placement || {})
    })
    if (error) return error
    registryRevision++
    pluginsChanged()
    return ""
  }

  // The unattended verb: a widget already in the bar stays where its owner
  // put it, and a placement next to a widget this bar lacks gives way to the
  // default place.
  function putBarWidget(id, placement) {
    // IPC can ask before the index has loaded, and an id not read yet is not
    // one that does not exist.
    if (loading) return "not ready"
    if (inBar(id)) return ""
    var config = shellConfigProvider ? shellConfigProvider() : null
    var target = Util.isPlainObject(placement) ? Util.cloneJson(placement) : {}
    var relativeId = String(target.before || target.after || "")
    if (relativeId && !findBarLocation(config, relativeId, String(target.section || "")).found) {
      delete target.before
      delete target.after
    }
    return setEnabled(id, true, target) ? "" : (lastEnableError || "unknown")
  }

  // Sets <key> to <value> in the widget's layout entry: the one at
  // selector's (from)section[(from)index] when it gives an index, else the
  // widget wherever it is (in that section, if named).
  function setBarWidget(id, key, value, selector) {
    if (loading) return "not ready"
    var error = ""
    shellConfigMutator(function(config) {
      ensureConfigShape(config)
      var wanted = selector || {}
      var section = String(wanted.fromSection || wanted.section || "")
      var index = wanted.fromIndex !== undefined && wanted.fromIndex !== null ? wanted.fromIndex : wanted.index
      var place

      if (index === undefined || index === null) {
        place = findBarLocation(config, id, section)
      } else if (!section) {
        error = "index requires section"
        return
      } else {
        var at = Math.floor(Number(index))
        var list = config.bar.layout[section]
        if (!Array.isArray(list) || at < 0 || at >= list.length) {
          error = "no widget at " + section + "[" + at + "]"
          return
        }
        place = { found: true, section: section, index: at }
      }

      if (!place.found) {
        error = "could not find widget " + id
        return
      }
      var entry = config.bar.layout[place.section][place.index]
      if (barEntryId(entry) !== String(id)) error = "widget at " + place.section + "[" + place.index + "] is not " + id
      else if (!Util.isPlainObject(entry)) error = "widget entry must be an object"
      else entry[String(key)] = value
    })
    if (error) return error
    registryRevision++
    pluginsChanged()
    return ""
  }

  // Fills in what the verbs rely on: bar.layout with its three sections, and
  // plugins.
  function ensureConfigShape(config) {
    if (!Util.isPlainObject(config.bar)) config.bar = { layout: { left: [], center: [], right: [] } }
    if (!Util.isPlainObject(config.bar.layout)) config.bar.layout = { left: [], center: [], right: [] }
    var layout = config.bar.layout
    if (!Array.isArray(layout.left)) layout.left = []
    if (!Array.isArray(layout.center)) layout.center = []
    if (!Array.isArray(layout.right)) layout.right = []
    if (!Array.isArray(config.plugins)) config.plugins = []
  }

  // Takes <id> out of disabledPlugins, and the list out when it empties.
  function removeDisabled(config, id) {
    if (!Array.isArray(config.disabledPlugins)) return
    var rest = config.disabledPlugins.filter(function(entry) { return entry !== id })
    if (rest.length > 0) config.disabledPlugins = rest
    else delete config.disabledPlugins
  }

  function addDisabled(config, id) {
    if (isDisabled(config, id)) return
    if (Array.isArray(config.disabledPlugins)) config.disabledPlugins.push(id)
    else config.disabledPlugins = [id]
  }

  // Switches a plugin on or off; true when done, else false with the reason
  // in lastEnableError. A bar widget switched on goes where <placement>
  // says; with none, where Nova's default layout has it, else to the section
  // its manifest declares, else center. Any other plugin that is off by
  // default is named in plugins. Switched off, a widget leaves the bar, and
  // any other plugin that is on by default is listed in disabledPlugins.
  function setEnabled(id, value, placement) {
    var key = Util.canonicalWidgetId(String(id))
    lastEnableError = ""
    if (loading) {
      lastEnableError = "not ready"
      return false
    }
    if (!shellConfigMutator) {
      console.warn("PluginRegistry.setEnabled called before shellConfigMutator wired")
      return false
    }
    var manifest = installedPlugins[key]
    if (value && !manifest) {
      console.warn("PluginRegistry.setEnabled: unknown plugin " + key)
      return false
    }
    if (alwaysOn(manifest)) {
      if (!value) lastEnableError = manifest.name + " cannot be switched off"
      return Boolean(value)
    }

    var isBarWidget = hasKind(manifest, "bar-widget")
    shellConfigMutator(function(config) {
      ensureConfigShape(config)
      var relativeId = value && placement ? String(placement.before || placement.after || "") : ""
      if (relativeId && !findBarLocation(config, relativeId, String(placement.section || "")).found) {
        lastEnableError = "could not find target widget " + relativeId
        return
      }

      var onDefault = onByDefault(manifest)
      var location = findEntryLocation(config, key)
      if (!value) {
        if (location.kind === "bar") config.bar.layout[location.section].splice(location.index, 1)
        else if (location.kind === "plugin") config.plugins.splice(location.index, 1)
        // For a widget, leaving the layout is all there is to it; anything
        // else built in loads unless it is listed as off.
        if (onDefault && !isBarWidget) addDisabled(config, key)
        return
      }

      removeDisabled(config, key)
      if (!location.found && isBarWidget) {
        var place = (namesPlace(placement) ? null : defaultBarPlace(config, key))
          || barTarget(config, placement || {}, defaultBarWidgetSection(manifest))
        config.bar.layout[place.section].splice(place.index, 0, { id: key })
        return
      }
      if (!location.found && !onDefault) config.plugins.push({ id: key })
      if (isBarWidget && placement && Object.keys(placement).length > 0) moveBarEntry(config, key, placement)
    })
    if (lastEnableError) return false
    registryRevision++
    pluginsChanged()
    return true
  }

  // Reads index.json, [{ "dir": "<dir under plugins/>", "manifest": {...} }],
  // which the package build has checked. An entry without an id or a list
  // of kinds is passed over.
  function load(text) {
    var entries = []
    try {
      entries = JSON.parse(String(text || "[]"))
    } catch (e) {
      console.warn("PluginRegistry: the plugin index is not JSON: " + e)
    }
    var plugins = ({})
    var count = Array.isArray(entries) ? entries.length : 0
    for (var i = 0; i < count; i++) {
      var manifest = entries[i] ? entries[i].manifest : null
      if (!Util.isPlainObject(manifest) || !manifest.id || !Array.isArray(manifest.kinds)) continue
      manifest.__sourceDir = pluginsDir + "/" + String(entries[i].dir || "")
      plugins[manifest.id] = manifest
    }
    installedPlugins = plugins
    registryRevision++
    loading = false
    pluginsChanged()
  }

  property FileView index: FileView {
    path: registry.pluginsDir ? registry.pluginsDir + "/index.json" : ""
    printErrors: false
    onLoaded: registry.load(text())
    // With no index there is no lock, no polkit agent and no widget, so this
    // is an error, not a warning.
    onLoadFailed: function(error) {
      console.error("PluginRegistry: cannot read " + path + ": " + error)
      registry.load("")
    }
  }
}
