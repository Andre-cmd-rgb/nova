import QtQuick
import QtQml.Models
import Quickshell
import Quickshell.Io

import qs.Commons

import "plugins/bar"
import "services"

// Nova's shell, the process the session runs as nova-shell. It reads
// shell.json, loads what is enabled of the plugins (the bar and its
// widgets, the services, and the panels, overlays and menus when they are
// called for), hands each the shared services, and answers the IPC targets
// "shell" and "image-selector".
ShellRoot {
  id: shell

  // The shared services. Each plugin is handed them as properties: a
  // singleton imported by relative path gives each importer a copy of its
  // own, and the copies quietly disagree.
  property PluginRegistry pluginRegistry: PluginRegistry { }
  property BarWidgetRegistry barWidgetRegistry: BarWidgetRegistry { }
  property AppLibrary appLibrary: AppLibrary { }

  property string home: Quickshell.env("HOME")

  // Where Nova is installed, from the session's environment; the plugins
  // are in shell/plugins under it.
  property string novaPath: Quickshell.env("NOVA_PATH")
  readonly property string shellPath: novaPath + "/shell"
  readonly property string pluginsDir: shellPath + "/plugins"
  readonly property string defaultsPath: novaPath + "/default/shell.json"
  readonly property string userConfigPath: home + "/.config/nova/shell.json"

  // What the shell starts with when Nova's default shell.json cannot be
  // read: enough for a working bar, no more.
  readonly property var builtinShellConfig: ({
    version: 1,
    idle: {
      lock: 300
    },
    bar: {
      position: "top",
      transparent: false,
      centerAnchor: "nova.clock",
      layout: {
        left: [{ id: "nova.menu" }, { id: "nova.workspaces" }],
        center: [{ id: "nova.clock", format: "dddd HH:mm" }],
        right: [{ id: "nova.audio" }]
      }
    },
    plugins: []
  })

  property var defaultsConfig: builtinShellConfig
  // The config in effect (applyShellConfig).
  property var shellConfig: builtinShellConfig

  // A new config can switch plugins on or off.
  onShellConfigChanged: pluginRegistry.pluginsChanged()

  // The config in effect is the user's shell.json when it is a valid one,
  // an object with version 1, and otherwise the defaults; the two are not
  // merged.
  function applyShellConfig() {
    var chosen = Util.isPlainObject(defaultsConfig) ? defaultsConfig : builtinShellConfig
    var text = userConfigFile.text() || ""
    if (text.trim()) {
      try {
        var user = JSON.parse(text)
        if (Util.isPlainObject(user)) {
          if (user.version === 1) chosen = user
          else console.warn("shell.json missing version: 1, using defaults")
        }
      } catch (e) {
        console.warn("shell.json parse failed, using defaults:", e)
      }
    }
    shellConfig = chosen
  }

  // Nova's default shell.json, or the built-in config when it is empty, not
  // JSON, or not an object with version 1.
  function loadDefaults(raw) {
    var text = String(raw || "").trim()
    var parsed = null
    if (text) {
      try {
        parsed = JSON.parse(text)
      } catch (e) {
        console.warn("default shell.json parse failed, using builtin:", e)
      }
    }
    defaultsConfig = Util.isPlainObject(parsed) && parsed.version === 1 ? parsed : builtinShellConfig
    defaultsRead = true
    configRead()
  }

  // Makes <nextConfig> the config in effect, and writes it to the user's
  // shell.json.
  function persistShellConfig(nextConfig) {
    var saved = JSON.parse(JSON.stringify(nextConfig))
    saved.version = 1
    shellConfig = saved
    userConfigFile.setText(JSON.stringify(saved, null, 2) + "\n")
  }

  readonly property var barConfig: shellConfig && Util.isPlainObject(shellConfig.bar) ? shellConfig.bar : builtinShellConfig.bar

  FileView {
    id: defaultsFile
    path: shell.defaultsPath
    watchChanges: true
    printErrors: false
    onLoaded: shell.loadDefaults(text())
    onLoadFailed: function(error) {
      console.warn("default shell.json load failed: " + error + " path=" + shell.defaultsPath)
      shell.loadDefaults("")
    }
    onFileChanged: reload()
  }

  FileView {
    id: userConfigFile
    path: shell.userConfigPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: shell.userConfigRead()
    onLoadFailed: function(error) { shell.userConfigRead() }
    onFileChanged: reload()
  }

  function userConfigRead() {
    userRead = true
    configRead()
  }

  // Whether each shell.json has been read, or found missing or unreadable.
  property bool defaultsRead: false
  property bool userRead: false

  // Once both shell.json files have been read, and again whenever one is
  // read anew, the config in effect is worked out. Only then does the plugin
  // index load: before, the registry answers "not ready" to whatever would
  // write shell.json, which would otherwise start from a config made
  // without them.
  function configRead() {
    if (!defaultsRead || !userRead) return
    applyShellConfig()
    pluginRegistry.pluginsDir = pluginsDir
  }

  Component.onCompleted: {
    console.log("nova-shell paths",
      "novaPath=" + novaPath,
      "shellDir=" + Quickshell.shellDir,
      "pluginsDir=" + pluginsDir,
      "defaultsPath=" + defaultsPath,
      "userConfigPath=" + userConfigPath)
    pluginRegistry.shellConfigProvider = function() { return shell.shellConfig }
    pluginRegistry.shellConfigMutator = function(change) { shell.mutateShellConfig(change) }
    pluginRegistry.defaultsProvider = function() { return shell.defaultsConfig }
  }

  // Calls mutator(config) with a copy of the config in effect to edit, and
  // saves the result.
  function mutateShellConfig(mutator) {
    var draft = JSON.parse(JSON.stringify(shellConfig || builtinShellConfig))
    mutator(draft)
    persistShellConfig(draft)
  }

  // Hands a plugin's item the shell and its manifest, when it has a
  // property of that name.
  function provideShared(item, manifest) {
    if ("shell" in item) item.shell = shell
    if ("manifest" in item) item.manifest = manifest
  }

  // The bar, once loaded, for the plugins that place themselves by it
  // (notifications, panels) and for the verbs that reach its widgets.
  property var bar: null

  Loader {
    id: barLoader
    // Inside Bar { } the name `shell` is the bar's own property, which hides
    // this file's root, so the root goes in under another name.
    readonly property var host: shell
    sourceComponent: Bar {
      barWidgetRegistry: barLoader.host.barWidgetRegistry
      barConfig: barLoader.host.barConfig
      shell: barLoader.host
    }
    onLoaded: shell.bar = item
  }

  // ---------------------------------------------------------------- services
  //
  // A running instance of each enabled plugin of kind "service", by plugin
  // id. Bindings read it through serviceFor(), so every change sets a new
  // object.

  Item {
    id: serviceHost
    visible: false
  }

  property var _services: ({})

  function serviceFor(pluginId) {
    return _services[String(pluginId)] || null
  }

  // The plugin's service, started if it is not yet: null when it has none,
  // when it fails to load, or while it is still loading.
  function ensureService(pluginId) {
    var key = String(pluginId)
    if (_services[key]) return _services[key]
    var manifest = pluginRegistry.installedPlugins[key]
    var url = pluginRegistry.hasKind(manifest, "service") ? pluginRegistry.entryPointUrl(manifest, "service") : ""
    if (!url) return null

    var component = Qt.createComponent(url, Component.PreferSynchronous)
    function start() {
      if (component.status !== Component.Ready) {
        console.warn("service plugin load failed for " + key + ": " + component.errorString())
        return
      }
      var service = component.createObject(serviceHost)
      if (!service) {
        console.warn("service plugin createObject returned null for", key)
        return
      }
      shell.provideShared(service, manifest)
      var running = ({})
      for (var name in shell._services) running[name] = shell._services[name]
      running[key] = service
      shell._services = running
    }
    if (component.status === Component.Loading) {
      component.statusChanged.connect(start)
      return null
    }
    start()
    return _services[key] || null
  }

  // Starts the services of the enabled plugins, and stops those of plugins
  // switched off.
  function _syncServices() {
    var plugins = pluginRegistry.installedPlugins
    for (var id in plugins) {
      if (pluginRegistry.hasKind(plugins[id], "service") && pluginRegistry.isEnabled(id)) ensureService(id)
    }
    for (var runningId in _services) {
      if (pluginRegistry.isEnabled(runningId)) continue
      var service = _services[runningId]
      if (service && typeof service.destroy === "function") service.destroy()
      var rest = ({})
      for (var name in _services) {
        if (name !== runningId) rest[name] = _services[name]
      }
      _services = rest
    }
  }

  Connections {
    target: shell.pluginRegistry
    function onPluginsChanged() { shell._syncServices() }
  }

  // Writes a plugin's settings into its entry in shell.json: the bar layout
  // entries with its id, or else its entry in plugins. <settings> is the
  // whole of them; an id among them is ignored. Writes, and answers true,
  // only when an entry changes, so that a binding that keeps sending the
  // same settings does not keep rewriting the file.
  function updateEntryInline(moduleName, settings) {
    var id = String(moduleName || "")
    var draft = JSON.parse(JSON.stringify(shellConfig || builtinShellConfig))
    if (!Util.isPlainObject(draft.bar)) draft.bar = { layout: { left: [], center: [], right: [] } }
    if (!Util.isPlainObject(draft.bar.layout)) draft.bar.layout = { left: [], center: [], right: [] }
    if (!Array.isArray(draft.plugins)) draft.plugins = []

    function rewritten() {
      var entry = { id: id }
      for (var key in settings) {
        if (key !== "id") entry[key] = settings[key]
      }
      return entry
    }

    var changed = false
    var inLayout = false
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = draft.bar.layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        if (!entries[i] || String(entries[i].id || "") !== id) continue
        inLayout = true
        var entry = rewritten()
        if (JSON.stringify(entries[i]) === JSON.stringify(entry)) continue
        entries[i] = entry
        changed = true
      }
    }
    for (var j = 0; !inLayout && j < draft.plugins.length; j++) {
      if (!draft.plugins[j] || draft.plugins[j].id !== id) continue
      var named = rewritten()
      if (JSON.stringify(draft.plugins[j]) === JSON.stringify(named)) continue
      draft.plugins[j] = named
      changed = true
    }
    if (!changed) return false
    persistShellConfig(draft)
    return true
  }

  // ------------------------------------------------------------------ panels

  // The panel, overlay and menu plugins called up, as { pluginId: true }.
  // Each change sets a new object, so that the loaders below are told.
  property var openPanelIds: ({})

  // What each summon() sent, by plugin id, waiting for the plugin to load:
  // a list, so that two calls before it has loaded both reach its open(),
  // in order.
  property var pendingPayloads: ({})

  // Whether the plugin's panel is a bar widget's (audio, network, power...).
  // Those live in the bar, which makes them again when it reloads, so the
  // verbs go to the bar of the moment. A widget that is a panel, overlay or
  // menu as well (the menu) is the loaders' instead.
  function isBarWidgetPanelPlugin(pluginId) {
    var manifest = pluginRegistry.installedPlugins[String(pluginId || "")]
    if (!manifest || !Array.isArray(manifest.kinds)) return false
    var kinds = manifest.kinds
    return kinds.indexOf("bar-widget") >= 0
      && kinds.indexOf("panel") < 0 && kinds.indexOf("overlay") < 0 && kinds.indexOf("menu") < 0
  }

  // Opens the plugin's panel, passing <payloadJson> to its open() once it
  // has loaded; a bar widget's panel takes none. False for a plugin that is
  // unknown, switched off, a widget not in the bar, or has nothing to open.
  function summon(pluginId, payloadJson) {
    var id = String(pluginId || "")
    if (!id) return false
    if (!pluginRegistry.installedPlugins[id]) {
      console.warn("summon: unknown plugin", id)
      return false
    }
    // A plugin switched off has no loader: marking it open would only leave
    // an open that nothing shows, for toggle() to undo.
    if (!pluginRegistry.isEnabled(id)) {
      console.warn("summon: plugin not enabled, not summoning:", id)
      return false
    }
    if (isBarWidgetPanelPlugin(id)) {
      var summoned = bar && typeof bar.summonBarWidget === "function" && bar.summonBarWidget(id)
      if (!summoned) console.warn("summon: no live bar widget for:", id)
      return summoned === true
    }
    // A plugin with no panel, overlay or menu (a service, the bar) has no
    // loader either, and nothing would ever take the payload.
    if (!panelKind(pluginRegistry.installedPlugins[id])) {
      console.warn("summon: nothing to open for", id)
      return false
    }

    var open = ({})
    for (var name in openPanelIds) open[name] = openPanelIds[name]
    open[id] = true
    openPanelIds = open

    var queued = ({})
    for (var waiting in pendingPayloads) queued[waiting] = pendingPayloads[waiting].slice()
    if (!queued[id]) queued[id] = []
    queued[id].push(payloadJson || "")
    pendingPayloads = queued

    // A plugin kept loaded has its item already.
    deliverIfLoaded(id)
    return true
  }

  function hide(pluginId) {
    var id = String(pluginId || "")
    if (!id) return false
    if (isBarWidgetPanelPlugin(id)) {
      var hidden = bar && typeof bar.hideBarWidget === "function" && bar.hideBarWidget(id)
      if (!hidden) console.warn("hide: no live bar widget for:", id)
      return hidden === true
    }
    invokeIfLoaded(id, "close", null)
    if (!openPanelIds[id]) return true
    var open = ({})
    for (var name in openPanelIds) {
      if (name !== id) open[name] = openPanelIds[name]
    }
    openPanelIds = open
    return true
  }

  // Whether the panel is open: as the plugin says, when it has loaded and
  // says (opened), and otherwise whether it was called up.
  function isPluginOpen(pluginId) {
    var id = String(pluginId || "")
    if (isBarWidgetPanelPlugin(id))
      return bar && typeof bar.isBarWidgetOpen === "function" ? bar.isBarWidgetOpen(id) : false
    var loader = panelLoaders[id]
    if (loader && loader.item && loader.item.opened !== undefined) return loader.item.opened === true
    return openPanelIds[id] === true
  }

  function toggle(pluginId, payloadJson) {
    var id = String(pluginId || "")
    return isPluginOpen(id) ? hide(id) : summon(id, payloadJson)
  }

  // The loader of each panel plugin whose item has loaded, by plugin id.
  property var panelLoaders: ({})

  function registerPanelLoader(pluginId, loader) {
    var loaders = ({})
    for (var name in panelLoaders) loaders[name] = panelLoaders[name]
    loaders[pluginId] = loader
    panelLoaders = loaders
    deliverIfLoaded(pluginId)
  }

  function unregisterPanelLoader(pluginId) {
    if (!panelLoaders[pluginId]) return
    var loaders = ({})
    for (var name in panelLoaders) {
      if (name !== pluginId) loaders[name] = panelLoaders[name]
    }
    panelLoaders = loaders
  }

  // Passes the plugin's waiting payloads to its open(), when its item has
  // loaded; they are dropped then whether it has an open() or not.
  function deliverIfLoaded(pluginId) {
    var loader = panelLoaders[pluginId]
    if (!loader || !loader.item) return
    var queue = pendingPayloads[pluginId]
    if (!Array.isArray(queue) || queue.length === 0) return
    if (typeof loader.item.open === "function") {
      queue.forEach(function(payload) {
        try {
          loader.item.open(payload)
        } catch (e) {
          console.warn("plugin " + pluginId + " open() threw:", e)
        }
      })
    }
    var rest = ({})
    for (var name in pendingPayloads) {
      if (name !== pluginId) rest[name] = pendingPayloads[name].slice()
    }
    pendingPayloads = rest
  }

  function invokeIfLoaded(pluginId, method, arg) {
    var loader = panelLoaders[pluginId]
    if (!loader || !loader.item || typeof loader.item[method] !== "function") return
    try {
      loader.item[method](arg)
    } catch (e) {
      console.warn("plugin " + pluginId + " " + method + "() threw:", e)
    }
  }

  // The answer of the loaded plugin's <method>(arg), for IPC: "ok" for
  // none, "unknown" when it has not loaded or has no such method, "error"
  // when it throws.
  function callIfLoaded(pluginId, method, arg) {
    var id = String(pluginId || "")
    var loader = panelLoaders[id]
    if (!loader || !loader.item || typeof loader.item[method] !== "function") return "unknown"
    try {
      var answer = loader.item[method](arg)
      return answer === undefined || answer === null ? "ok" : String(answer)
    } catch (e) {
      console.warn("plugin " + id + " " + method + "() threw:", e)
      return "error"
    }
  }

  // The enabled panel, overlay and menu plugins, a loader each below, as
  // { id, manifest, kind, keepLoaded }; kind is the first of panel, overlay
  // and menu that the plugin is.
  property var panelEntries: []

  // The first of panel, overlay and menu that the plugin is, or "".
  function panelKind(manifest) {
    var kinds = manifest && Array.isArray(manifest.kinds) ? manifest.kinds : []
    return kinds.indexOf("panel") >= 0 ? "panel"
      : kinds.indexOf("overlay") >= 0 ? "overlay"
      : kinds.indexOf("menu") >= 0 ? "menu" : ""
  }

  function computePanelEntries() {
    var entries = []
    var plugins = pluginRegistry.installedPlugins
    for (var id in plugins) {
      var manifest = plugins[id]
      var kind = panelKind(manifest)
      if (!kind || !pluginRegistry.isEnabled(id)) continue
      entries.push({ id: id, manifest: manifest, kind: kind, keepLoaded: manifest.keepLoaded === true })
    }
    return entries
  }

  Connections {
    target: shell.pluginRegistry
    function onPluginsChanged() { shell.panelEntries = shell.computePanelEntries() }
  }

  // A loader for each panel entry, active while its plugin is called up, or
  // always for one kept loaded; the item it holds keeps the plugin's window
  // and state from one opening to the next. Every write of shell.json
  // announces pluginsChanged, and the entries are matched by id: a panel
  // that stays keeps its loader, and stays open, while another comes or
  // goes (Screen Time switched on in Settings).
  Instantiator {
    model: ScriptModel {
      values: shell.panelEntries
      objectProp: "id"
    }
    active: true

    delegate: QtObject {
      id: panelEntry
      required property var modelData
      readonly property string pluginId: modelData.id
      readonly property var manifest: modelData.manifest
      readonly property string entryKind: modelData.kind
      readonly property bool keepLoaded: modelData.keepLoaded === true
      readonly property string sourceUrl: shell.pluginRegistry.entryPointUrl(manifest, entryKind)

      property Loader panelLoader: Loader {
        source: panelEntry.sourceUrl
        active: panelEntry.sourceUrl !== "" && (panelEntry.keepLoaded || shell.openPanelIds[panelEntry.pluginId] === true)
        asynchronous: true
        onLoaded: {
          if (!item) return
          shell.provideShared(item, panelEntry.manifest)
          // A panel that goes with a service of the same plugin reads its
          // state from it.
          if ("service" in item) item.service = shell.serviceFor(panelEntry.pluginId)
          shell.registerPanelLoader(panelEntry.pluginId, this)
        }
        onStatusChanged: {
          if (status !== Loader.Error) return
          // A Loader given a source keeps the component it made of it as
          // sourceComponent, which holds the reason: that goes in the log,
          // where a panel that will not open says nothing.
          var detail = sourceComponent ? sourceComponent.errorString() : ""
          console.warn("panel plugin " + panelEntry.pluginId + " failed to load:", detail)
          // Hidden after this handler: a panel opened again after failing
          // fails at once, while its <active> is still being set, and hiding
          // it here would set <active> inside its own update, a binding
          // loop. Each gets a closure of its own, as Qt.callLater runs a
          // function given twice before it runs only once.
          var id = panelEntry.pluginId
          Qt.callLater(function () { shell.hide(id) })
        }
        Component.onDestruction: shell.unregisterPanelLoader(panelEntry.pluginId)
      }
    }
  }

  // ------------------------------------------------------------- bar widgets

  // The enabled bar-widget plugins, kept in BarWidgetRegistry, from which
  // the bar fills its slots: each registered by its manifest id with a
  // component made from its barWidget entry point.
  Connections {
    target: shell.pluginRegistry
    function onPluginsChanged() { shell.syncPluginWidgets() }
  }

  // { widgetId: { url, component } }: each widget's component, by the URL
  // it was made from; component is null while it is still loading.
  property var pluginWidgetComponents: ({})

  function syncPluginWidgets() {
    var plugins = pluginRegistry.installedPlugins
    var enabled = ({})

    for (var pluginId in plugins) {
      var manifest = plugins[pluginId]
      if (!manifest || !manifest.kinds || manifest.kinds.indexOf("bar-widget") === -1) continue
      if (!pluginRegistry.isEnabled(pluginId)) continue

      var key = String(manifest.id)
      enabled[key] = true
      var made = pluginWidgetComponents[key]
      var url = pluginRegistry.entryPointUrl(manifest, "barWidget")
      // Loading, or made and registered: a second load would make a second
      // component, and a slot given a new component makes its widget again,
      // two of it running for a moment, each taking the widget's IPC target.
      if (made && made.url === url && (!made.component || barWidgetRegistry.has(key))) continue
      loadPluginWidget(key, url)
    }

    // Widgets of plugins gone or switched off leave the registry.
    var registered = barWidgetRegistry.availableIds()
    for (var i = 0; i < registered.length; i++) {
      var id = registered[i]
      if (!pluginWidgetComponents[id] || enabled[id]) continue
      barWidgetRegistry.unregister(id)
      setPluginWidgetComponent(id, null)
    }
  }

  // Sets the widget's entry in pluginWidgetComponents; null takes it out.
  function setPluginWidgetComponent(registryKey, entry) {
    var components = ({})
    for (var name in pluginWidgetComponents) {
      if (name !== registryKey) components[name] = pluginWidgetComponents[name]
    }
    if (entry) components[registryKey] = entry
    pluginWidgetComponents = components
  }

  // Makes the widget's component from <url>, and registers it once it has
  // loaded.
  function loadPluginWidget(registryKey, url) {
    // The key is taken before the component exists: Qt.createComponent
    // loads in the background, and the syncs while the shell starts could
    // not otherwise tell a load in progress from none.
    setPluginWidgetComponent(registryKey, { url: url, component: null })

    var component = Qt.createComponent(url, Component.Asynchronous)
    function settle() {
      if (component.status === Component.Ready) {
        shell.barWidgetRegistry.register(registryKey, component)
        shell.setPluginWidgetComponent(registryKey, { url: url, component: component })
      } else if (component.status === Component.Error) {
        console.warn("Plugin widget " + registryKey + " failed: " + component.errorString())
        // Free for the next sync to try again.
        shell.setPluginWidgetComponent(registryKey, null)
      }
    }
    if (component.status === Component.Loading) component.statusChanged.connect(settle)
    else settle()
  }

  // ------------------------------------------------------------- image picker

  // nova-theme's way in: opens the picker on its rows (base64).
  IpcHandler {
    target: "image-selector"

    function open(imageDirs: string,
                  imageRowsB64: string,
                  selectedImage: string,
                  selectionFile: string,
                  doneFile: string,
                  showLabels: string,
                  filterable: string): string {
      var request = {
        imageDirs: imageDirs,
        imageRows: Util.decodeBase64(imageRowsB64),
        selectedImage: selectedImage,
        selectionFile: selectionFile,
        doneFile: doneFile,
        showLabels: showLabels,
        filterable: filterable
      }
      return shell.summon("nova.image-picker", JSON.stringify(request)) ? "ok" : "unknown"
    }
  }

  // -------------------------------------------------------------- shell IPC

  // nova-shell's verbs. Those that change shell.json answer "ok" or what
  // was wrong.
  IpcHandler {
    target: "shell"

    function ping(): string {
      return "ok"
    }

    function reloadConfig(): string {
      userConfigFile.reload()
      return "ok"
    }

    function setPluginEnabled(id: string, enabled: string): string {
      var done = shell.pluginRegistry.setEnabled(id, enabled === "true")
      return done ? "ok" : (shell.pluginRegistry.lastEnableError || "unknown")
    }

    // Enables the widget, but leaves it where it is when it is on the bar
    // already: a caller that cannot know whether it ran before does not move
    // a widget its owner placed.
    function putBarWidget(id: string, placementJson: string): string {
      try {
        return shell.pluginRegistry.putBarWidget(id, JSON.parse(placementJson || "{}")) || "ok"
      } catch (e) {
        return "invalid placement: " + e
      }
    }

    function moveBarWidget(id: string, placementJson: string): string {
      try {
        return shell.pluginRegistry.moveBarWidget(id, JSON.parse(placementJson || "{}")) || "ok"
      } catch (e) {
        return "invalid placement: " + e
      }
    }

    function setBarWidget(id: string, key: string, valueJson: string, selectorJson: string): string {
      try {
        var value = JSON.parse(valueJson)
        var selector = JSON.parse(selectorJson || "{}")
        return shell.pluginRegistry.setBarWidget(id, key, value, selector) || "ok"
      } catch (e) {
        return "invalid widget setting: " + e
      }
    }

    // The installed plugins as JSON, sorted by name, then id: each with its
    // id, name, kinds, whether it is on, and whether it can be switched off.
    function listPlugins(): string {
      var registry = shell.pluginRegistry
      var plugins = registry.installedPlugins
      var listed = []
      for (var id in plugins) {
        var kinds = plugins[id].kinds
        var fixed = registry.alwaysOn(plugins[id])
        listed.push({
          id: id,
          name: plugins[id].name,
          kinds: kinds,
          // On, for a widget, is in the bar: what switching it on or off
          // changes, not whether its component can load.
          enabled: fixed || (kinds.indexOf("bar-widget") !== -1 ? registry.inBar(id) : registry.isEnabled(id)),
          // Said here so that a caller offering the verbs need not work it
          // out (the bar and the lock).
          canDisable: !fixed
        })
      }
      listed.sort(function(a, b) {
        var nameA = String(a.name || a.id)
        var nameB = String(b.name || b.id)
        if (nameA !== nameB) return nameA < nameB ? -1 : 1
        return String(a.id).localeCompare(String(b.id))
      })
      return JSON.stringify(listed)
    }

    function summon(id: string, payloadJson: string): string {
      return shell.summon(id, payloadJson) ? "ok" : "unknown"
    }

    function hide(id: string): void {
      shell.hide(id)
    }

    function toggle(id: string, payloadJson: string): void {
      shell.toggle(id, payloadJson)
    }

    // Toggles the panel of the widget at <index> in a bar <section>: a
    // hotkey can mean "the third panel on the right", and keep meaning it
    // when the bar is rearranged. Answers the id it toggled, or "unknown"
    // when no panel is there.
    function togglePanelAt(section: string, index: string): string {
      var bar = shell.bar
      var id = bar && typeof bar.panelWidgetIdAt === "function" ? bar.panelWidgetIdAt(section, index) : ""
      if (!id) return "unknown"
      shell.toggle(id, "{}")
      return id
    }

    // A method of a loaded plugin (callIfLoaded).
    function call(id: string, method: string, arg: string): string {
      return shell.callIfLoaded(id, method, arg)
    }
  }
}
