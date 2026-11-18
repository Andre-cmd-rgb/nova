// platform: wayland
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/panels/clock" as Clock

// The clock's bar widget with its month panel, the real BarWidget.qml and
// Panel.qml on a fake bar: the label, the panel opened and closed, its keys
// turning the month, and the clicks that change the format or ask for a time
// zone.
ShellRoot {
  id: test

  property Item stage: Item {}
  property var clock: null

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
    Clock.BarWidget { bar: test.fakeBar }
  }

  // The widget's own button, which the bar would click.
  function button() {
    return find(clock, item => typeof item.click === "function" && item.textWidth !== undefined)
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    clock = made.createObject(stage)
    check("the bar shows a label", clock.label.length > 0, true)
    check("closed at first", clock.opened, false)
    clock.open()
    check("opened: the surface is up", surfaceOf(clock).open, true)
    check("opened: the bar knows it is the panel open", test.fakeBar.popup === clock, true)
    const sheet = surfaceOf(clock).keys
    check("it opens on today's month", sheet.onToday, true)
    sheet.stepped(1, 0)
    check("Right turns to the next month", [sheet.shown - sheet.todayMonth, sheet.onToday], [1, false])
    sheet.stepped(0, 1)
    check("Down turns a year on", sheet.shown - sheet.todayMonth, 13)
    sheet.activated(Qt.Key_Return)
    check("Return comes back to today", sheet.onToday, true)
    sheet.struck("]")
    sheet.struck("]")
    sheet.struck("[")
    check("] and [ turn a month a time", sheet.shown - sheet.todayMonth, 1)
    sheet.struck("t")
    check("t comes back to today", sheet.onToday, true)
    sheet.struck("c")
    check("c with no calendar leaves the panel open", clock.opened, true)
    const before = clock.weekStart
    sheet.struck("w")
    check("w switches the day weeks start on", clock.weekStart !== before, true)
    surfaceOf(clock).close()
    check("the surface's close closes the panel", clock.opened, false)

    const label = clock.label
    button().click(Qt.RightButton)
    check("a right click goes on to the next format", clock.label !== label, true)
    button().click(Qt.MiddleButton)
    check("a middle click asks for a time zone", test.fakeBar.ran, ["nova-menu-timezone"])
    button().click(Qt.LeftButton)
    check("a click opens the panel", clock.opened, true)
    button().click(Qt.LeftButton)
    check("a second click closes it", clock.opened, false)
    finish()
  }
}
