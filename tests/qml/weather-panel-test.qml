// platform: wayland
// stub: bin/curl record
// stub: bin/nova-weather-location record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/panels/weather" as Weather

// The weather's bar widget with its panel, the real BarWidget.qml and
// Panel.qml on a fake bar, with no forecast: curl and the location helper are
// stubs that answer nothing, so that no request leaves the machine. The
// widget is then hidden, and its panel opens and closes all the same, with
// its keys and the click that sends the weather as a notification.
ShellRoot {
  id: test

  property Item stage: Item {}
  property var weather: null

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
    property var ran: []
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
    function run(command) { ran = ran.concat([command]) }
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

  Component {
    id: made
    Weather.BarWidget { bar: test.fakeBar }
  }

  function button() {
    return find(weather, item => typeof item.click === "function" && item.slot !== undefined)
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    weather = made.createObject(stage)
    check("with no forecast the widget is out of the bar", weather.visible, false)
    check("closed at first", weather.opened, false)
    weather.open()
    check("opened: the surface is up", surfaceOf(weather).open, true)
    check("opened: the bar knows it is the panel open", test.fakeBar.popup === weather, true)
    const keys = surfaceOf(weather).keys
    check("the panel has its keys", keys !== null, true)
    keys.stepped(0, 1)
    keys.stepped(1, 0)
    keys.stepped(0, -1)
    keys.stepped(-1, 0)
    keys.activated(Qt.Key_Return)
    check("the cursor and Return leave the panel open", weather.opened, true)
    surfaceOf(weather).close()
    check("the surface's close closes the panel", weather.opened, false)
    button().click(Qt.RightButton)
    check("a right click sends the weather as a notification", test.fakeBar.ran, ["nova-notification-send \"$(nova-weather-status)\""])
    button().click(Qt.LeftButton)
    check("a click opens the panel", weather.opened, true)
    button().click(Qt.LeftButton)
    check("a second click closes it", weather.opened, false)
    weather.edit()
    check("edit opens the panel", weather.opened, true)
    weather.close()
    check("close closes it", weather.opened, false)
    finish()
  }
}
