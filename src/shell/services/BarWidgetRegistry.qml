import QtQuick

// The bar widgets that can be placed, by id: shell.qml fills it from the
// enabled plugins and hands this one object to the bar and the other
// plugins. It is an instance, not a singleton, because a singleton imported
// by relative path gave each importer a copy of its own, and the shell never
// saw what the bar had put in.
QtObject {
  id: registry

  // { widgetId: { component: Component, metadata: var } }. Each change sets
  // a new object, so that a binding reading it is told.
  property var widgets: ({})
  property int revision: 0

  // Sent after each register or unregister, once widgets and revision have
  // their new values.
  signal changed()

  function register(id, component, metadata) {
    var key = String(id)
    if (key.length === 0) return
    var next = {}
    for (var name in widgets) next[name] = widgets[name]
    next[key] = { component: component, metadata: metadata || {} }
    widgets = next
    revision++
    changed()
  }

  function unregister(id) {
    var key = String(id)
    if (!widgets[key]) return
    var next = {}
    for (var name in widgets) {
      if (name !== key) next[name] = widgets[name]
    }
    widgets = next
    revision++
    changed()
  }

  function metadataFor(id) {
    var widget = widgets[String(id)]
    return widget ? widget.metadata : null
  }

  function availableIds() {
    return Object.keys(widgets)
  }

  function has(id) {
    return widgets[String(id)] !== undefined
  }
}
