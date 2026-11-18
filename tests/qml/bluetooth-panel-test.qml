// platform: wayland
// stub: bin/rfkill rfkill
// stub: bin/nova-bluetooth-power record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/panels/bluetooth"

// The Bluetooth panel, the real Panel.qml on a fake bar. There is no system
// bus under the test, so Quickshell.Bluetooth has no adapter: the panel is
// as on a computer without Bluetooth, or with the radio's rfkill switch set
// so that the adapter has gone from the bus. `rfkill event` and
// nova-bluetooth-power are stubs: the first tells the panel of a switch set
// (the lines in $HOME/rfkill-event), the second notes that it was asked.
ShellRoot {
  id: test

  property var panel: null
  property var blocked: null
  property Item stage: Item {}

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

  FileView {
    id: events
    path: Quickshell.env("HOME") + "/rfkill-event"
    printErrors: false
    onSaved: test.second()
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

  Component.onCompleted: Qt.callLater(first)

  function first() {
    panel = made.createObject(stage)
    check("no adapter: the widget is out of the bar", panel.visible, false)
    panel.open()
    check("no adapter: the panel opens", surfaceOf(panel).open, true)
    check("no adapter: the header's title", headerOf(panel)?.title, "Bluetooth")
    check("no adapter: the header's note says so plainly", headerOf(panel)?.note, "No adapter")
    const keys = surfaceOf(panel).keys
    keys.stepped(0, 1)
    keys.stepped(0, -1)
    keys.stepped(1, 0)
    keys.stepped(-1, 0)
    keys.activated(Qt.Key_Return)
    keys.erased()
    keys.struck("b")
    check("no adapter: the cursor, Return, x and b leave the panel open", panel.opened, true)
    surfaceOf(panel).close()
    check("no adapter: the surface's close closes the panel", panel.opened, false)
    panel.destroy()
    events.setText("idx 0 type 2 op 0 soft 1 hard 0\n")
  }

  // With the switch set, rfkill says so when the panel starts.
  function second() {
    blocked = made.createObject(stage)
    later(1000, third)
  }

  Timer {
    id: wait
    property var next: null
    onTriggered: next()
  }

  function later(ms, next) {
    wait.next = next
    wait.interval = ms
    wait.restart()
  }

  function third() {
    check("the radio's switch set: the widget stays, for the switch", blocked.visible, true)
    blocked.open()
    check("the radio's switch set: the header's note says it is off", headerOf(blocked)?.note, "Turned Off")
    surfaceOf(blocked).keys.struck("b")
    check("b with the radio off: the note says it is turning on, at once", headerOf(blocked)?.note, "Turning On…")
    later(500, fourth)
  }

  function fourth() {
    calls.reload()
    check("b with the radio off asks nova-bluetooth-power to turn it on", calls.text().trim(), "nova-bluetooth-power on")
    blocked.close()
    finish()
  }
}
