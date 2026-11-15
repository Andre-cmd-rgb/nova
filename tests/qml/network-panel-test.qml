// platform: wayland
import QtQuick
import Quickshell
import "plugins/panels/network"

// The network panel, the real Panel.qml on a fake bar, opened and driven by
// its keys and by a click. There is no system bus under the test, so
// Quickshell.Networking reports no NetworkManager and no devices: the panel
// is in the state of a computer with no network service, which is the one
// whose header and Settings row it has to get right.
ShellRoot {
  id: test

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
    property var ran: []
    property QtObject tip: QtObject {
      function ask(button, text) {}
      function withdraw(button) {}
    }
    property QtObject shell: QtObject {
      function serviceFor(id) { return null }
    }
    function listButton(button, on) {}
    function claimPopup(key, open) { popup = open ? key : null }
    function inWindow(item, window) { return false }
    function nextPanel(owner, step) { return false }
    function run(command) { ran = ran.concat([command]) }
  }

  property Panel panel: Panel { bar: test.fakeBar }

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  // The panel's PanelSurface, which its widget keeps among its data.
  function surface() {
    for (const child of panel.data) if (child.keys !== undefined && child.host !== undefined) return child
    return null
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

  function header() {
    return find(surface(), item => item.title !== undefined && item.note !== undefined)
  }

  // The MouseArea of the row that says <text>.
  function rowArea(text) {
    const words = find(surface(), item => item.text === text)
    for (let row = words; row; row = row.parent) {
      const area = find(row, item => item.hoverEnabled !== undefined && typeof item.clicked === "function")
      if (area) return area
    }
    return null
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    const card = surface()
    check("the panel has its surface", card !== null, true)
    check("closed at first", panel.opened, false)

    panel.open()
    check("opened: the surface is up", card.open, true)
    check("opened: the bar knows it is the panel open", fakeBar.popup === panel, true)
    check("the header's title with no NetworkManager", header()?.title, "Network")
    check("the header's note with no NetworkManager", header()?.note, "Not connected")

    const keys = card.keys
    keys.stepped(0, 1)
    keys.stepped(0, -1)
    keys.stepped(1, 0)
    keys.stepped(-1, 0)
    keys.stepped(0, 1)
    check("the cursor's moves leave the panel open", panel.opened, true)
    keys.struck("r")
    keys.struck("w")
    keys.struck("R")
    keys.struck("q")
    check("r, w and other letters leave the panel open and run nothing", [panel.opened, fakeBar.ran], [true, []])

    keys.activated(Qt.Key_Return)
    check("Return on Wi-Fi Settings: the panel closes", panel.opened, false)
    check("Return on Wi-Fi Settings: Settings opens at Wi-Fi", fakeBar.ran, ["nova-settings wifi"])

    fakeBar.ran = []
    panel.open()
    check("reopened: the surface is up", card.open, true)
    const area = rowArea("Wi-Fi Settings")
    check("the Wi-Fi Settings row is there to click", area !== null, true)
    area.clicked(null)
    check("a click on the Wi-Fi Settings row: the panel closes", panel.opened, false)
    check("a click on the Wi-Fi Settings row: Settings opens at Wi-Fi", fakeBar.ran, ["nova-settings wifi"])

    panel.open()
    card.close()
    check("the surface's own close closes the panel", panel.opened, false)
    check("closed: the bar's open panel is given back", fakeBar.popup, null)

    console.log("DONE")
    Qt.quit()
  }
}
