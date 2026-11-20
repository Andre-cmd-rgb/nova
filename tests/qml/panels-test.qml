import QtQuick
import Quickshell
import Quickshell.Io
import "services"

// The shell's panels against two fake plugins written into the scratch home:
// one of the kind Settings and the calendar are, a panel with open() and
// close() and no `opened`, loaded on summon and unloaded on hide; and one
// kept loaded, as the menu is, which says whether it is open and closes its
// own window.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  property bool ran: false

  property var manifests: ({
    "nova.fake": { id: "nova.fake", kinds: ["panel"], entryPoints: { panel: "FakePanel.qml" } },
    "nova.kept": { id: "nova.kept", kinds: ["panel"], keepLoaded: true, entryPoints: { panel: "FakeKept.qml" } }
  })

  property QtObject bar: QtObject {
    property var popup: null
  }

  property Panels panels: Panels {
    registry: QtObject {
      readonly property var manifests: test.manifests
      function isOn(id) { return id in test.manifests }
      function has(manifest, kind) { return (manifest.kinds || []).indexOf(kind) >= 0 }
      function entryUrl(manifest, kind) { return "file://" + test.home + "/" + manifest.entryPoints[kind] }
    }
    shell: QtObject {
      readonly property var bar: test.bar
    }
  }

  FileView {
    id: fake
    path: test.home + "/FakePanel.qml"
    preload: false
    printErrors: false
    onSaved: kept.setText("import QtQuick\nItem {\n  property var shell\n  property bool opened: false\n" +
      "  function open(payload) { opened = true }\n  function close() { opened = false }\n}\n")
  }

  FileView {
    id: kept
    path: test.home + "/FakeKept.qml"
    preload: false
    printErrors: false
    onSaved: test.begin()
  }

  function check(name, got, want) {
    console.log((got === want ? "ok   " : "FAIL ") + name + (got === want ? "" : ": got " + got + ", want " + want))
  }

  function item() {
    return panels.itemOf("nova.fake")
  }

  // Runs <then> once the plugin's item has loaded, or at once when it has.
  function whenLoaded(then, id) {
    if (panels.itemOf(id || "nova.fake")) then()
    else Qt.callLater(() => whenLoaded(then, id))
  }

  // The collector's second, gone by.
  function collect() {
    panels.collector.stop()
    panels.collector.triggered()
  }

  Component.onCompleted: {
    fake.setText("import QtQuick\nItem {\n  property var shell\n  property bool shown: false\n" +
      "  function open(payload) { shown = true }\n  function close() { shown = false }\n}\n")
  }

  function begin() {
    if (ran) return
    ran = true
    panels.sync()
    // What a summon sent while the panel loaded, and the panel hidden first.
    panels.waiting["nova.fake"] = ["stale"]
    panels.forget("nova.fake")
    check("hidden before it loaded, what was sent goes with it", panels.waiting["nova.fake"], undefined)
    check("summon answers yes", panels.summon("nova.fake", "{}"), true)
    whenLoaded(() => {
      check("summoned, the panel shows", item().shown, true)
      check("  and is open", panels.isOpen("nova.fake"), true)
      check("call close answers ok", panels.call("nova.fake", "close", ""), "ok")
      check("closed by call, the shell knows it closed", panels.isOpen("nova.fake"), false)
      collect()
      panels.toggle("nova.fake", "{}")
      whenLoaded(() => {
        check("toggled after, it opens again", item().shown, true)
        check("  and is open", panels.isOpen("nova.fake"), true)
        panels.toggle("nova.fake", "")
        check("toggled again, it is closed", panels.isOpen("nova.fake"), false)
        check("  and what it held is collected a moment later", panels.collector.running, true)
        check("an unknown method answers unknown", panels.call("nova.fake", "nothing", ""), "unknown")
        reopened()
      })
    })
  }

  // A window opened within the second puts the collection off to its close:
  // a collection stops what is on screen.
  function reopened() {
    panels.summon("nova.fake", "{}")
    collect()
    check("a window opened in the second puts the collection off", panels.owed, true)
    whenLoaded(() => {
      collect()
      check("  for as long as it is open", panels.owed, true)
      panels.hide("nova.fake")
      check("  and its close brings it back", panels.collector.running, true)
      collect()
      check("  and it runs, with nothing open", panels.owed, false)
      barPanel()
    })
  }

  // The bar's panels and cards close without the shell's hide.
  function barPanel() {
    panels.owed = true
    bar.popup = "nova.audio"
    collect()
    check("a panel of the bar's open puts the collection off", panels.owed, true)
    bar.popup = null
    check("  and its close brings it back", panels.collector.running, true)
    collect()
    check("  and it runs", panels.owed, false)
    whenLoaded(keptPanel, "nova.kept")
  }

  // One kept loaded closes its own window, and its opened says so.
  function keptPanel() {
    panels.summon("nova.kept", "{}")
    check("a panel kept loaded and summoned is open", panels.isOpen("nova.kept"), true)
    panels.owed = true
    collect()
    check("  and puts the collection off", panels.owed, true)
    panels.itemOf("nova.kept").close()
    check("  until it closes its own window", panels.collector.running, true)
    collect()
    check("  when it runs", panels.owed, false)
    // There is nothing to collect when one kept loaded is hidden.
    panels.summon("nova.kept", "{}")
    panels.hide("nova.kept")
    check("a panel kept loaded and hidden asks for no collection", panels.collector.running, false)
    console.log("DONE")
    Qt.quit()
  }
}
