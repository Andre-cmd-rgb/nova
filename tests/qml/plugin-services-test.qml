import QtQuick
import Quickshell
import "services"

// The services of the plugins that are on: one running object each, made
// once however often it is synced, and destroyed when its plugin is switched
// off. The battery's service stands in; the registry is a fake.
ShellRoot {
  id: test

  property var off: ({})

  property QtObject registry: QtObject {
    property var manifests: ({
      "nova.one": { id: "nova.one", kinds: ["service"] },
      "nova.two": { id: "nova.two", kinds: ["service"] },
      "nova.panel": { id: "nova.panel", kinds: ["panel"] }
    })
    function has(manifest, kind) { return manifest.kinds.indexOf(kind) >= 0 }
    function isOn(id) { return !test.off[id] }
    function entryUrl(manifest, kind) { return Qt.resolvedUrl("plugins/services/battery/Service.qml") }
  }

  property PluginServices services: PluginServices {
    registry: test.registry
    shell: test
  }

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  Component.onCompleted: Qt.callLater(() => {
    services.sync()
    const one = services.serviceFor("nova.one")
    check("a service is made for each plugin that is on", [!!one, !!services.serviceFor("nova.two")], [true, true])
    check("a plugin with no service has none", services.serviceFor("nova.panel"), null)
    services.sync()
    check("synced again, the same service stays", services.serviceFor("nova.one") === one, true)
    test.off = { "nova.one": true }
    services.sync()
    check("a plugin switched off loses its service", [services.serviceFor("nova.one"), !!services.serviceFor("nova.two")], [null, true])
    test.off = {}
    services.sync()
    const again = services.serviceFor("nova.one")
    check("switched on again, a new one", !!again && again !== one, true)
    console.log("DONE")
    Qt.quit()
  })
}
