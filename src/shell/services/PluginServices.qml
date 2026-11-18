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
      if (!running[id] && !starting[id] && registry.has(manifest, "service") && registry.isOn(id)) start(id, manifest)
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

  // { id: true }, for the services whose component is still loading, so
  // that a sync meanwhile does not make a second one.
  property var starting: ({})

  // Makes the service from its entry point, synchronously when Qt can, and
  // hands it the shell and its manifest once made. The component is this
  // object's child: one without a parent is the garbage collector's, and a
  // service that loaded in the background could be lost before it was made.
  function start(id, manifest) {
    var url = registry.entryUrl(manifest, "service")
    if (!url) return
    var component = Qt.createComponent(url, Component.PreferSynchronous, pluginServices)
    function create() {
      delete pluginServices.starting[id]
      if (component.status !== Component.Ready) {
        console.warn("service plugin load failed for " + id + ": " + component.errorString())
        return
      }
      // Switched off while it loaded: left out, as sync would have.
      if (!pluginServices.registry.isOn(id)) return
      var service = component.createObject(pluginServices)
      if (!service) {
        console.warn("service plugin createObject returned null for " + id)
        return
      }
      if ("shell" in service) service.shell = pluginServices.shell
      if ("manifest" in service) service.manifest = manifest
      pluginServices.running = Object.assign({}, pluginServices.running, { [id]: service })
    }
    if (component.status === Component.Loading) {
      starting[id] = true
      component.statusChanged.connect(create)
    } else {
      create()
    }
  }
}
