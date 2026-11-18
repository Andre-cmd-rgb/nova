// platform: wayland
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/panels/audio"

// The audio panel, the real Panel.qml on a fake bar, opened and driven by its
// keys. With no system bus there is no PipeWire graph, so it is as on a
// computer with no sound device: no output, no input, no streams.
ShellRoot {
  id: test

  property Item stage: Item {}
  property var panel: null

  property QtObject fakeBar: QtObject {
    readonly property int thickness: 30
    readonly property string fontFamily: "monospace"
    readonly property color foreground: "white"
    readonly property color background: "black"
    readonly property color textColour: "white"
    readonly property color urgent: "red"
    readonly property bool textFades: false
    readonly property bool peek: false
    property var popup: null
    property var buttons: []
    property var summoned: []
    property QtObject tip: QtObject {
      function ask(button, text) {}
      function withdraw(button) {}
    }
    property QtObject shell: QtObject {
      function serviceFor(id) { return null }
      function summon(id, argument) { test.fakeBar.summoned = test.fakeBar.summoned.concat([id]) }
      function updateEntryInline(id, entry) {}
    }
    function listButton(button, on) {}
    function copiesOf(id) { return [] }
    function claimPopup(key, open) { popup = open ? key : null }
    function inWindow(item, window) { return false }
    function nextPanel(owner, step) { return false }
    function run(command) {}
  }

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  // The first Item under <item>, the surface's content included, for which
  // <test> holds, or null.
  function find(item, test) {
    const below = item.contentItem ? [item.contentItem] : item.children
    for (const child of below) {
      if (test(child)) return child
      const deeper = find(child, test)
      if (deeper) return deeper
    }
    return null
  }

  // <host>'s PanelSurface, which a panel keeps among its data.
  function surfaceOf(host) {
    for (const child of host.data) if (child.keys !== undefined && child.host !== undefined) return child
    return null
  }

  function headerOf(host) {
    return find(surfaceOf(host), item => item.title !== undefined && item.note !== undefined)
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    panel = audioMade.createObject(stage)
    check("closed at first", panel.opened, false)
    panel.open()
    check("opened: the surface is up", surfaceOf(panel).open, true)
    check("the header's title", headerOf(panel)?.title, "Audio")
    check("the header's note with no sink says so plainly", headerOf(panel)?.note, "No output")
    const keys = surfaceOf(panel).keys
    keys.stepped(0, 1)
    keys.stepped(0, 1)
    keys.stepped(0, -1)
    keys.stepped(1, 0)
    keys.stepped(-1, 0)
    keys.activated(Qt.Key_Return)
    keys.struck("m")
    keys.struck("M")
    check("the cursor, Return and m with nothing to act on leave the panel open", panel.opened, true)
    check("a wheel turn with no output asks for no OSD", [panel.wheeled(120), test.fakeBar.summoned][1], [])
    surfaceOf(panel).close()
    check("the surface's close closes the panel", panel.opened, false)
    panel.toggle()
    check("toggle opens it again", panel.opened, true)
    panel.close()
    check("close closes it", [panel.opened, test.fakeBar.popup], [false, null])
    finish()
  }

  Component {
    id: audioMade
    Panel { bar: test.fakeBar }
  }
}
