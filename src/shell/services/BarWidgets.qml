import QtQuick

// The bar's widgets from the plugins: for each bar-widget plugin that is on,
// a component made from its barWidget entry point. The bar fills its slots
// from `widgets` alone, which shell.qml hands it as its barWidgetRegistry.
// This is an object the shell makes, not a singleton: a singleton imported
// by relative path gave each importer a copy of its own, and the bar never
// saw what the shell had put in.
QtObject {
  id: barWidgets

  required property var registry

  // { id: { component } }, for the widgets made. A new object at each
  // change, so that the bar's bindings on it are told.
  property var widgets: ({})
  // { id: url }, for the widgets being made.
  property var making: ({})

  // Makes the widgets of the plugins switched on, and drops those of the
  // plugins switched off.
  function sync() {
    var wanted = ({})
    for (var id in registry.manifests) {
      var manifest = registry.manifests[id]
      if (registry.has(manifest, "bar-widget") && registry.isOn(id)) wanted[id] = true
    }
    for (var key in wanted) {
      // A second component for a widget made, or being made, would make it
      // again in its slot: two of it running for a moment, each taking the
      // widget's IPC target.
      if (!widgets[key] && !making[key]) make(key, registry.entryUrl(registry.manifests[key], "barWidget"))
    }
    var kept = ({})
    var dropped = false
    for (var made in widgets) {
      if (wanted[made]) kept[made] = widgets[made]
      else dropped = true
    }
    if (dropped) widgets = kept
  }

  // Qt.createComponent loads in the background; the widget is in `making`
  // until it has, so that the syncs while the shell starts do not load it
  // twice.
  function make(id, url) {
    making[id] = url
    var component = Qt.createComponent(url, Component.Asynchronous)
    function settle() {
      if (component.status === Component.Ready) {
        delete barWidgets.making[id]
        // Switched off while it loaded: left out, as sync would have.
        if (!barWidgets.registry.isOn(id)) return
        barWidgets.widgets = Object.assign({}, barWidgets.widgets, { [id]: { component: component } })
      } else if (component.status === Component.Error) {
        console.warn("Plugin widget " + id + " failed: " + component.errorString())
        // Free for the next sync to try again.
        delete barWidgets.making[id]
      }
    }
    if (component.status === Component.Loading) component.statusChanged.connect(settle)
    else settle()
  }
}
