// platform: wayland
// stub: bin/nova-battery-info record
// stub: bin/nova-power-profile record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/panels/power"

// The power panel, the real Panel.qml on a fake bar. With no system bus there
// is no battery, and the widget is hidden and has no panel to open: this is
// what that state does. The panel with a battery cannot be reached, as UPower's
// display device is Quickshell's own and cannot be faked. nova-battery-info
// and nova-power-profile are stubs that note they were asked, so that nothing
// of the machine is read or changed.
ShellRoot {
  id: test

  property Item stage: Item {}
  property var panel: null

  property QtObject fakeBar: QtObject {
    readonly property bool vertical: false
    readonly property int thickness: 30
    readonly property string position: "top"
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

  FileView {
    id: calls
    path: Quickshell.env("HOME") + "/stub-calls"
    blockLoading: true
    printErrors: false
  }

  Component {
    id: made
    Panel { bar: test.fakeBar }
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    panel = made.createObject(stage)
    check("no battery: the widget is out of the bar", [panel.present, panel.visible], [false, false])
    check("no battery: no size", [panel.implicitWidth, panel.implicitHeight], [0, 0])
    panel.open()
    check("no battery: there is no panel to open", [panel.opened, surfaceOf(panel).open], [false, false])
    check("no battery: the bar has no open panel from it", test.fakeBar.popup, null)
    panel.toggle()
    check("no battery: toggling opens nothing either", panel.opened, false)
    panel.togglePercentage()
    check("no battery: the percentage setting still toggles", panel.settings.showPercentage, true)
    calls.reload()
    check("no battery: neither the battery nor the modes were read", calls.text(), "")
    finish()
  }
}
