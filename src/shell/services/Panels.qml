import QtQuick
import QtQml.Models
import Quickshell

// The panels, overlays and menus of the plugins that are on: a loader each,
// active from the plugin's summon to its hide, or always for one kept
// loaded, whose window and state then last from one opening to the next.
// A bar widget's panel (audio, network, power...) lives in the bar
// instead, which makes it again when it reloads, so the verbs pass those to
// the bar of the moment.
QtObject {
  id: panels

  required property var registry
  // What each panel is handed as `shell`, and where the bar and the
  // services are found.
  required property var shell

  // The plugins called up, as { id: true }. A new object at each change, so
  // that the loaders' bindings on it are told.
  property var called: ({})
  // What each summon sent, waiting for the plugin's item to load, as
  // { id: [payload, ...] }: two calls before it has loaded both reach its
  // open(), in order.
  property var waiting: ({})
  // The loaders whose item has loaded, { id: loader }.
  property var loaders: ({})
  // A loader is kept for each of these: [{ id, manifest, kind, keepLoaded }].
  property var panelList: []

  // The first of panel, overlay and menu that the plugin is, or "".
  function kindOf(manifest) {
    var kinds = manifest && Array.isArray(manifest.kinds) ? manifest.kinds : []
    return ["panel", "overlay", "menu"].find(function(kind) { return kinds.indexOf(kind) >= 0 }) || ""
  }

  // Whether the plugin's panel is the bar's: a bar widget that is not a
  // panel, overlay or menu as well (as the menu is).
  function barOwns(id) {
    var manifest = registry.manifests[id]
    return registry.has(manifest, "bar-widget") && !kindOf(manifest)
  }

  // The panel plugins that are on, each with a loader; one switched off
  // loses it, and with it whether it was called up and what was sent to
  // it: switched back on, it stays closed until it is called up again.
  function sync() {
    var list = []
    for (var id in registry.manifests) {
      var manifest = registry.manifests[id]
      var kind = kindOf(manifest)
      if (kind && registry.isOn(id)) list.push({ id: id, manifest: manifest, kind: kind, keepLoaded: manifest.keepLoaded === true })
    }
    panelList = list
    var present = ({})
    list.forEach(function(entry) { present[entry.id] = true })
    for (var queued in waiting) {
      if (!present[queued]) delete waiting[queued]
    }
    var stillCalled = ({})
    var dropped = false
    for (var name in called) {
      if (present[name]) stillCalled[name] = true
      else dropped = true
    }
    if (dropped) called = stillCalled
  }

  // Opens the plugin's panel and hands <payload> to its open() once it has
  // loaded; a bar widget's panel takes none. False for a plugin that is
  // unknown, switched off, a widget not in the bar, or has nothing to open.
  function summon(id, payload) {
    id = String(id || "")
    if (id === "") return false
    var manifest = registry.manifests[id]
    if (!manifest) return refuse("summon: unknown plugin " + id)
    // A plugin switched off has no loader: marking it called up would only
    // leave a mark that nothing shows, for toggle() to undo.
    if (!registry.isOn(id)) return refuse("summon: plugin not enabled, not summoning: " + id)
    if (barOwns(id)) return askBar("summonBarWidget", id) || refuse("summon: no live bar widget for: " + id)
    // A service or the bar has no loader either, and nothing would ever
    // take the payload.
    if (!kindOf(manifest)) return refuse("summon: nothing to open for " + id)
    called = Object.assign({}, called, { [id]: true })
    var queue = waiting[id] || (waiting[id] = [])
    queue.push(payload || "")
    // One kept loaded has its item already.
    deliver(id)
    return true
  }

  function hide(id) {
    id = String(id || "")
    if (id === "") return false
    if (barOwns(id)) return askBar("hideBarWidget", id) || refuse("hide: no live bar widget for: " + id)
    invoke(id, "close", null)
    forget(id)
    return true
  }

  // No longer called up: its loader unloads, unless it is kept loaded.
  function forget(id) {
    if (!called[id]) return
    var rest = Object.assign({}, called)
    delete rest[id]
    called = rest
  }

  // Whether the panel is open: as its item says, when it has loaded and
  // says (opened), else whether it was called up.
  function isOpen(id) {
    id = String(id || "")
    if (barOwns(id)) return askBar("isBarWidgetOpen", id)
    var item = itemOf(id)
    if (item && item.opened !== undefined) return item.opened === true
    return called[id] === true
  }

  function toggle(id, payload) {
    return isOpen(id) ? hide(id) : summon(id, payload)
  }

  // The answer of the loaded item's <method>(arg), for the IPC: "ok" for
  // none, "unknown" when it has not loaded or has no such method, "error"
  // when it throws. A close asked for this way is forgotten as a hide's is,
  // so that the shell knows the panel closed: Settings and the calendar keep
  // no `opened`, and were left marked open, for the next toggle to "hide".
  function call(id, method, arg) {
    id = String(id || "")
    var answer = invoke(id, method, arg)
    if (method === "close" && answer !== "unknown") forget(id)
    return answer
  }

  function invoke(id, method, arg) {
    var item = itemOf(id)
    if (!item || typeof item[method] !== "function") return "unknown"
    try {
      var answer = item[method](arg)
      return answer === undefined || answer === null ? "ok" : String(answer)
    } catch (e) {
      console.warn("plugin " + id + " " + method + "() threw: " + e)
      return "error"
    }
  }

  function itemOf(id) {
    return loaders[id] ? loaders[id].item : null
  }

  // What the bar of the moment answers to <method>(id), for a bar
  // widget's panel.
  function askBar(method, id) {
    var bar = shell.bar
    return !!bar && typeof bar[method] === "function" && bar[method](id) === true
  }

  // Logs why a verb says no, and says it.
  function refuse(why) {
    console.warn(why)
    return false
  }

  // Hands the item what summon() sent while it loaded; the payloads go
  // then, whether it has an open() or not.
  function deliver(id) {
    var item = itemOf(id)
    var queue = waiting[id]
    if (!item || !queue || queue.length === 0) return
    delete waiting[id]
    if (typeof item.open !== "function") return
    for (var payload of queue) {
      try {
        item.open(payload)
      } catch (e) {
        console.warn("plugin " + id + " open() threw: " + e)
      }
    }
  }

  // Entries matched by id: a panel that stays keeps its loader, and stays
  // open, while another comes or goes (Screen Time switched on in
  // Settings).
  property Instantiator loaderSet: Instantiator {
    model: ScriptModel {
      values: panels.panelList
      objectProp: "id"
    }

    delegate: QtObject {
      id: panel

      required property var modelData
      readonly property string plugin: modelData.id
      readonly property string url: panels.registry.entryUrl(modelData.manifest, modelData.kind)

      property Loader loader: Loader {
        source: panel.url
        active: panel.url !== "" && (panel.modelData.keepLoaded || panels.called[panel.plugin] === true)
        asynchronous: true
        onLoaded: {
          if (!item) return
          if ("shell" in item) item.shell = panels.shell
          if ("manifest" in item) item.manifest = panel.modelData.manifest
          // A panel that goes with a service of the same plugin reads its
          // state from it.
          if ("service" in item) item.service = panels.shell.serviceFor(panel.plugin)
          panels.loaders[panel.plugin] = this
          panels.deliver(panel.plugin)
        }
        onStatusChanged: {
          if (status !== Loader.Error) return
          // A Loader given a source keeps the component it made of it as
          // sourceComponent, which holds the reason: that goes in the log,
          // where a panel that will not open says nothing.
          console.warn("panel plugin " + panel.plugin + " failed to load: " + (sourceComponent ? sourceComponent.errorString() : ""))
          // Hidden after this handler: one opened again after failing fails
          // at once, while its <active> is still being set, and hiding it
          // here would set <active> inside its own update, a binding loop.
          // Each gets a closure of its own, as Qt.callLater runs a function
          // given twice before it runs only once.
          var id = panel.plugin
          Qt.callLater(function() { panels.hide(id) })
        }
        Component.onDestruction: delete panels.loaders[panel.plugin]
      }
    }
  }
}
