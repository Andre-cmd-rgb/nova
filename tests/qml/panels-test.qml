import QtQuick
import Quickshell
import Quickshell.Io
import "services"

// The shell's panels against a fake plugin of the kind Settings and the
// calendar are: a panel with open() and close() and no `opened`, loaded on
// summon and unloaded on hide. Its file is written into the scratch home.
ShellRoot {
  id: test

  readonly property string fakePath: Quickshell.env("HOME") + "/FakePanel.qml"
  property bool ran: false

  property var manifest: ({ id: "nova.fake", kinds: ["panel"], entryPoints: { panel: "FakePanel.qml" } })

  property Panels panels: Panels {
    registry: QtObject {
      readonly property var manifests: ({ "nova.fake": test.manifest })
      function isOn(id) { return id === "nova.fake" }
      function has(manifest, kind) { return (manifest.kinds || []).indexOf(kind) >= 0 }
      function entryUrl(manifest, kind) { return "file://" + test.fakePath }
    }
    shell: QtObject {
      readonly property var bar: null
    }
  }

  FileView {
    id: fake
    path: test.fakePath
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

  // Runs <then> once the fake has loaded, or at once when it has.
  function whenLoaded(then) {
    if (item()) then()
    else Qt.callLater(() => whenLoaded(then))
  }

  Component.onCompleted: {
    fake.setText("import QtQuick\nItem {\n  property var shell\n  property bool shown: false\n" +
      "  function open(payload) { shown = true }\n  function close() { shown = false }\n}\n")
  }

  function begin() {
    if (ran) return
    ran = true
    panels.sync()
    check("summon answers yes", panels.summon("nova.fake", "{}"), true)
    whenLoaded(() => {
      check("summoned, the panel shows", item().shown, true)
      check("  and is open", panels.isOpen("nova.fake"), true)
      check("call close answers ok", panels.call("nova.fake", "close", ""), "ok")
      check("closed by call, the shell knows it closed", panels.isOpen("nova.fake"), false)
      panels.toggle("nova.fake", "{}")
      whenLoaded(() => {
        check("toggled after, it opens again", item().shown, true)
        check("  and is open", panels.isOpen("nova.fake"), true)
        panels.toggle("nova.fake", "")
        check("toggled again, it is closed", panels.isOpen("nova.fake"), false)
        check("an unknown method answers unknown", panels.call("nova.fake", "nothing", ""), "unknown")
        console.log("DONE")
        Qt.quit()
      })
    })
  }
}
