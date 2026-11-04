import QtQuick

// The services of the plugins that are on, one running object each, by
// plugin id. A service starts as soon as its plugin is on, and at once: the
// lock is one, and comes up in the same turn as the rest at startup. One
// switched off is destroyed.
Item {
  id: pluginServices
  visible: false

  required property var registry
  // What each service is handed as `shell`.
  required property var shell

  // { id: service }. A new object at each change, so that a binding on
  // serviceFor() is told.
  property var running: ({})

  function serviceFor(id) {
    return running[String(id)] || null
  }

  function sync() {
    for (var id in registry.manifests) {
      var manifest = registry.manifests[id]
      if (!running[id] && registry.has(manifest, "service") && registry.isOn(id)) start(id, manifest)
    }
    var kept = ({})
    var stopped = false
    for (var name in running) {
      if (registry.isOn(name)) {
        kept[name] = running[name]
      } else {
        running[name].destroy()
        stopped = true
      }
    }
    if (stopped) running = kept
  }

  // Makes the service from its entry point, synchronously when Qt can, and
  // hands it the shell and its manifest once made.
  function start(id, manifest) {
    var url = registry.entryUrl(manifest, "service")
    if (!url) return
    var component = Qt.createComponent(url, Component.PreferSynchronous)
    function create() {
      if (component.status !== Component.Ready) {
        console.warn("service plugin load failed for " + id + ": " + component.errorString())
        return
      }
      var service = component.createObject(pluginServices)
      if (!service) {
        console.warn("service plugin createObject returned null for " + id)
        return
      }
      if ("shell" in service) service.shell = pluginServices.shell
      if ("manifest" in service) service.manifest = manifest
      pluginServices.running = Object.assign({}, pluginServices.running, { [id]: service })
    }
    if (component.status === Component.Loading) component.statusChanged.connect(create)
    else create()
  }
}
