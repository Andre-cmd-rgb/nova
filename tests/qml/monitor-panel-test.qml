// platform: wayland
// stub: bin/nova-monitor-state monitor-state
// stub: bin/nova-brightness-display record
// stub: bin/nova-display-text-size record
// stub: bin/nova-hyprland-monitor-scaling record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/panels/monitor"

// The display panel, the real Panel.qml on a fake bar, fed what
// nova-monitor-state would say (the lines in $HOME/monitor-state): first a
// screen with no backlight, then one with a backlight at 60%. The commands the
// panel sets things with are stubs that note what they were asked, and
// hyprctl is the runner's, so that no display of this machine is changed.
ShellRoot {
  id: test

  property Item stage: Item {}
  property var panel: null
  property string waitingFor: ""

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
    id: state
    path: Quickshell.env("HOME") + "/monitor-state"
    printErrors: false
    onSaved: test.fed()
  }

  FileView {
    id: calls
    path: Quickshell.env("HOME") + "/stub-calls"
    blockLoading: true
    printErrors: false
  }

  Timer {
    id: wait
    property var next: null
    property var ready: null
    property int tries: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (ready()) { stop(); next() }
      else if (++tries > 100) { stop(); check("what the test waited for happened", false, true); test.finish() }
    }
  }

  // Calls <next> once <ready> holds, looking every 50 ms.
  function until(ready, next) {
    wait.ready = ready
    wait.next = next
    wait.tries = 0
    wait.start()
  }

  // What the helper says: the brightness (or "unavailable"), four lines the
  // panel does not read, the focused display, its scale, and the displays.
  function say(brightness) {
    return brightness + "\n\n\n\n\neDP-1\n1\n[{\"name\":\"eDP-1\",\"enabled\":true,\"focused\":true,\"width\":1920,\"height\":1080}]\n"
  }

  property var after: null
  Component {
    id: made
    Panel { bar: test.fakeBar }
  }

  Component.onCompleted: {
    after = fixed
    state.setText(say("unavailable"))
  }

  function fed() {
    const next = after
    after = null
    if (next) next()
  }

  function fixed() {
    panel = made.createObject(stage)
    until(() => panel.focusName === "eDP-1", () => {
      check("a screen with no backlight: the widget is in the bar", panel.visible, true)
      panel.open()
      check("opened: the surface is up", surfaceOf(panel).open, true)
      check("the header's title", headerOf(panel)?.title, "Display")
      check("with no backlight the note says the brightness is fixed", headerOf(panel)?.note, "Fixed brightness")
      const keys = surfaceOf(panel).keys
      keys.stepped(0, 1)
      keys.stepped(0, 1)
      keys.stepped(0, -1)
      keys.stepped(1, 0)
      keys.stepped(-1, 0)
      keys.activated(Qt.Key_Return)
      check("keys on a screen with no backlight leave the panel open", panel.opened, true)
      panel.close()
      after = lit
      state.setText(say("60"))
    })
  }

  function lit() {
    // A look asked while the last one is still running is not made, so it is
    // asked again until the new answer is in.
    until(() => { panel.refresh(); return panel.lit }, () => {
      panel.open()
      check("with a backlight there is no note: the slider says the brightness", headerOf(panel)?.note, "")
      const keys = surfaceOf(panel).keys
      keys.stepped(1, 0)
      check("the first key only shows the cursor: the brightness stays", panel.level, 60)
      keys.stepped(1, 0)
      check("l raises the brightness by 5", panel.level, 65)
      keys.stepped(-1, 0)
      keys.stepped(-1, 0)
      check("h lowers it by 5 a step", panel.level, 55)
      check("and the note stays empty", headerOf(panel)?.note, "")
      until(() => { calls.reload(); return calls.text().indexOf("55%") >= 0 }, () => {
        check("the brightness is set through nova-brightness-display, on the focused screen",
          calls.text().trim().split("\n").pop(), "nova-brightness-display --no-osd --monitor eDP-1 55%")
        surfaceOf(panel).close()
        check("the surface's close closes the panel", panel.opened, false)
        finish()
      })
    })
  }
}
