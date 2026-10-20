import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Instance, not a singleton — see BarWidgetRegistry for rationale.
//
// Every plugin is Nova's own and ships in the package. The package build
// collects their manifests into one file, plugins/index.json (tools/plugin-index),
// and the registry reads it once at startup: no directory to scan, nothing to
// watch, no plugin from anywhere else.
QtObject {
  id: registry

  // Set by shell.qml once the config hooks below are wired; the index loads then.
  property string pluginsDir: ""

  // Wired by shell.qml so the registry can read the canonical shell.json
  // without owning file IO itself. shellConfigProvider returns the current
  // effective shell config; shellConfigMutator takes a function that receives
  // a deep-cloned config it can mutate in place and persists the result.
  property var shellConfigProvider: null
  property var shellConfigMutator: null

  // { pluginId: manifest }, each with __sourceDir stamped in.
  property var installedPlugins: ({})
  property int registryRevision: 0
  property bool loading: true
  property string lastEnableError: ""

  signal pluginsChanged()
  signal ready()

  // ---------------------------------------------------------------- helpers

  function entryPointUrl(manifest, kind) {
    var entry = Util.isPlainObject(manifest) && Util.isPlainObject(manifest.entryPoints)
      ? manifest.entryPoints[kind] : ""
    return entry && manifest.__sourceDir ? Util.fileUrl(manifest.__sourceDir + "/" + entry) : ""
  }

  function hasKind(manifest, kind) {
    return !!manifest && manifest.kinds.indexOf(kind) !== -1
  }

  // Enabled = the plugin's component loads. Everything is on by default, so
  // shell.json only records the deviation: a switched-off plugin in
  // `disabledPlugins[]`. A manifest that says "enabledByDefault": false
  // (Screen Time) is the exception: it is on only while shell.json names it,
  // in the bar layout or in `plugins[]`, so taking it off the bar switches it
  // off entirely. The bar itself is always on.
  function onByDefault(manifest) {
    return !!manifest && manifest.enabledByDefault !== false
  }

  function isEnabled(id) {
    var key = Util.canonicalWidgetId(String(id))
    var manifest = installedPlugins[key]
    var config = shellConfigProvider ? shellConfigProvider() : null
    if (manifest) {
      if (hasKind(manifest, "bar")) return true
      if (isDisabled(config, key)) return false
      if (onByDefault(manifest)) return true
    }
    return findEntryLocation(config, key).found
  }

  function isDisabled(config, id) {
    return Util.isPlainObject(config) && Array.isArray(config.disabledPlugins)
      && config.disabledPlugins.indexOf(Util.canonicalWidgetId(String(id))) !== -1
  }

  // A bar widget is on when it sits in the bar. That is a different question
  // from isEnabled(), which decides whether the widget's component is loaded
  // at all — a built-in stays loadable so it can be put back, and so a plugin
  // that is both a widget and a menu (nova.menu) cannot be locked out of the
  // shell by taking its button off the bar.
  function inBar(id) {
    var config = shellConfigProvider ? shellConfigProvider() : null
    return findEntryLocation(config, id).kind === "bar"
  }

  function defaultBarWidgetSection(manifest) {
    var metadata = manifest && Util.isPlainObject(manifest.barWidget) ? manifest.barWidget : null
    var section = metadata ? String(metadata.defaultSection || "") : ""
    return ["left", "center", "right"].indexOf(section) !== -1 ? section : "center"
  }

  function barEntryId(entry) {
    return Util.canonicalWidgetId(String(Util.isPlainObject(entry) ? entry.id : entry || ""))
  }

  function findBarLocation(config, id, section) {
    if (!Util.isPlainObject(config) || !Util.isPlainObject(config.bar)
        || !Util.isPlainObject(config.bar.layout)) return { found: false }
    var key = Util.canonicalWidgetId(String(id))
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      if (section && sections[s] !== section) continue
      var entries = config.bar.layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        if (barEntryId(entries[i]) === key)
          return { found: true, kind: "bar", section: sections[s], index: i }
      }
    }
    return { found: false }
  }

  function findEntryLocation(config, id) {
    if (!Util.isPlainObject(config)) return { found: false }
    var key = Util.canonicalWidgetId(String(id))
    var barLocation = findBarLocation(config, key, "")
    if (barLocation.found) return barLocation
    if (Array.isArray(config.plugins)) {
      for (var j = 0; j < config.plugins.length; j++) {
        if (config.plugins[j] && Util.canonicalWidgetId(config.plugins[j].id) === key) return { found: true, kind: "plugin", index: j }
      }
    }
    return { found: false }
  }

  function barTarget(config, placement, fallbackSection) {
    var target = placement || {}
    var section = ["left", "center", "right"].indexOf(String(target.section || "")) !== -1
      ? String(target.section) : fallbackSection
    var relativeId = String(target.before || target.after || "")
    if (relativeId) {
      var relative = findBarLocation(config, relativeId, section && target.section ? section : "")
      if (!relative.found) return { error: "could not find target widget " + relativeId }
      return {
        section: relative.section,
        index: relative.index + (target.after ? 1 : 0)
      }
    }

    if (!Array.isArray(config.bar.layout[section])) config.bar.layout[section] = []
    if (target.index !== undefined && target.index !== null) {
      var requested = Math.max(0, Math.floor(Number(target.index)))
      return { section: section, index: Math.min(requested, config.bar.layout[section].length) }
    }

    var anchors = { left: "nova.workspaces", center: "nova.weather", right: "nova.tray" }
    var anchor = findBarLocation(config, anchors[section], section)
    return {
      section: section,
      index: anchor.found ? anchor.index + 1 : config.bar.layout[section].length
    }
  }

  function moveBarEntry(config, id, placement) {
    var key = Util.canonicalWidgetId(String(id))
    var source
    if (placement.fromIndex !== undefined && placement.fromIndex !== null) {
      var fromSection = String(placement.fromSection || "")
      if (!fromSection) return "from-index requires from-section"
      var entries = config.bar.layout[fromSection]
      var fromIndex = Math.floor(Number(placement.fromIndex))
      if (!Array.isArray(entries) || fromIndex < 0 || fromIndex >= entries.length)
        return "no widget at " + fromSection + "[" + fromIndex + "]"
      if (barEntryId(entries[fromIndex]) !== key)
        return "widget at " + fromSection + "[" + fromIndex + "] is not " + key
      source = { found: true, section: fromSection, index: fromIndex }
    } else {
      source = findBarLocation(config, key, String(placement.fromSection || ""))
      if (!source.found) return "could not find widget " + key
    }

    var entry = config.bar.layout[source.section][source.index]
    config.bar.layout[source.section].splice(source.index, 1)
    var target = barTarget(config, placement, source.section)
    if (target.error) {
      config.bar.layout[source.section].splice(source.index, 0, entry)
      return target.error
    }
    config.bar.layout[target.section].splice(target.index, 0, entry)
    return ""
  }

  function moveBarWidget(id, placement) {
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

  // put is the unattended verb: where enable errors, it falls back, and it
  // leaves a widget that is already on the bar where its owner put it.
  function putBarWidget(id, placement) {
    if (inBar(id)) return ""
    // The index loads in the background and IPC answers before it has, so an
    // id it has not read yet is not one that does not exist.
    if (loading) return "not ready"
    var config = shellConfigProvider ? shellConfigProvider() : null
    var target = Util.isPlainObject(placement) ? Util.cloneJson(placement) : {}
    var relativeId = String(target.before || target.after || "")
    if (relativeId && !findBarLocation(config, relativeId, String(target.section || "")).found) {
      delete target.before
      delete target.after
    }
    if (setEnabled(id, true, target)) return ""
    return lastEnableError || "unknown"
  }

  function setBarWidget(id, key, value, selector) {
    var error = ""
    shellConfigMutator(function(config) {
      ensureConfigShape(config)
      var location
      var requested = selector || {}
      var section = String(requested.fromSection || requested.section || "")
      var index = requested.fromIndex !== undefined && requested.fromIndex !== null
        ? requested.fromIndex : requested.index
      if (index !== undefined && index !== null) {
        if (!section) {
          error = "index requires section"
          return
        }
        var entries = config.bar.layout[section]
        var numericIndex = Math.floor(Number(index))
        if (!Array.isArray(entries) || numericIndex < 0 || numericIndex >= entries.length) {
          error = "no widget at " + section + "[" + numericIndex + "]"
          return
        }
        location = { found: true, section: section, index: numericIndex }
      } else {
        location = findBarLocation(config, id, section)
      }
      if (!location.found) {
        error = "could not find widget " + id
        return
      }
      if (barEntryId(config.bar.layout[location.section][location.index]) !== String(id)) {
        error = "widget at " + location.section + "[" + location.index + "] is not " + id
        return
      }
      var entry = config.bar.layout[location.section][location.index]
      if (!Util.isPlainObject(entry)) {
        error = "widget entry must be an object"
        return
      }
      entry[String(key)] = value
    })
    if (error) return error
    registryRevision++
    pluginsChanged()
    return ""
  }

  function ensureConfigShape(config) {
    if (!Util.isPlainObject(config.bar)) config.bar = { layout: { left: [], center: [], right: [] } }
    if (!Util.isPlainObject(config.bar.layout)) config.bar.layout = { left: [], center: [], right: [] }
    var sections = ["left", "center", "right"]
    for (var i = 0; i < sections.length; i++) {
      if (!Array.isArray(config.bar.layout[sections[i]])) config.bar.layout[sections[i]] = []
    }
    if (!Array.isArray(config.plugins)) config.plugins = []
  }

  function removeDisabled(config, id) {
    if (!Array.isArray(config.disabledPlugins)) return
    config.disabledPlugins = config.disabledPlugins.filter(function(entry) { return entry !== id })
    if (config.disabledPlugins.length === 0) delete config.disabledPlugins
  }

  function addDisabled(config, id) {
    if (isDisabled(config, id)) return
    if (!Array.isArray(config.disabledPlugins)) config.disabledPlugins = []
    config.disabledPlugins.push(id)
  }

  // Bar widgets go to the default section their manifest declares, falling
  // back to center; anything else that is off by default goes into plugins[].
  function setEnabled(id, value, placement) {
    var key = Util.canonicalWidgetId(String(id))
    lastEnableError = ""
    if (!shellConfigMutator) {
      console.warn("PluginRegistry.setEnabled called before shellConfigMutator wired")
      return false
    }
    var manifest = installedPlugins[key]
    if (value && !manifest) {
      console.warn("PluginRegistry.setEnabled: unknown plugin " + key)
      return false
    }
    // The bar has no off, and no other bar to give way to.
    if (hasKind(manifest, "bar")) return true
    var isBarWidget = hasKind(manifest, "bar-widget")
    shellConfigMutator(function(config) {
      ensureConfigShape(config)

      if (value && placement && (placement.before || placement.after)) {
        var relativeId = String(placement.before || placement.after)
        if (!findBarLocation(config, relativeId, String(placement.section || "")).found) {
          lastEnableError = "could not find target widget " + relativeId
          return
        }
      }

      var onDefault = onByDefault(manifest)
      var location = findEntryLocation(config, key)

      if (value) {
        removeDisabled(config, key)
        if (!location.found && isBarWidget) {
          var target = barTarget(config, placement || {}, defaultBarWidgetSection(manifest))
          config.bar.layout[target.section].splice(target.index, 0, { id: key })
          return
        }
        if (!location.found && !onDefault) config.plugins.push({ id: key })
        if (isBarWidget && placement && Object.keys(placement).length)
          moveBarEntry(config, key, placement)
        return
      }

      if (location.kind === "bar") config.bar.layout[location.section].splice(location.index, 1)
      else if (location.kind === "plugin") config.plugins.splice(location.index, 1)

      // Dropping the layout entry is the whole story for a widget. Anything
      // else built-in loads by default, so switching it off has to be stated.
      if (onDefault && !isBarWidget) addDisabled(config, key)
    })
    if (lastEnableError) return false
    registryRevision++
    pluginsChanged()
    return true
  }

  // ---------------------------------------------------------------- loading

  // index.json: [{ "dir": "<dir under plugins/>", "manifest": { ... } }, ...],
  // validated when the package is built.
  function load(text) {
    var entries = []
    try {
      entries = JSON.parse(String(text || "[]"))
    } catch (e) {
      console.warn("PluginRegistry: the plugin index is not JSON: " + e)
    }
    var plugins = ({})
    for (var i = 0; Array.isArray(entries) && i < entries.length; i++) {
      var manifest = entries[i] ? entries[i].manifest : null
      if (!Util.isPlainObject(manifest) || !manifest.id || !Array.isArray(manifest.kinds)) continue
      manifest.__sourceDir = pluginsDir + "/" + String(entries[i].dir || "")
      plugins[manifest.id] = manifest
    }
    installedPlugins = plugins
    registryRevision++
    loading = false
    pluginsChanged()
    ready()
  }

  property FileView index: FileView {
    path: registry.pluginsDir ? registry.pluginsDir + "/index.json" : ""
    printErrors: false
    onLoaded: registry.load(text())
    onLoadFailed: function(error) {
      console.warn("PluginRegistry: cannot read " + path + ": " + error)
      registry.load("")
    }
  }
}
