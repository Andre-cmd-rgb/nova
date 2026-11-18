import QtQuick
import Quickshell
import "plugins/bar/widgets"

// The bar's indicators widget, with its real indicator files, on a fake bar
// whose services are plain objects: a click on a dark one turns it on and
// lights it, a click on a lit one turns it off, and a state changed from
// elsewhere (a key, the terminal) lights or darkens it too.
ShellRoot {
  id: test

  property QtObject idle: QtObject { property bool caffeine: false }
  property QtObject nightlight: QtObject {
    property bool enabled: false
    function setNightlight(on) { enabled = on }
  }
  property QtObject notifications: QtObject {
    property bool doNotDisturb: false
    function setDoNotDisturb(on) { doNotDisturb = on }
  }

  property QtObject fakeBar: QtObject {
    readonly property int thickness: 30
    readonly property string fontFamily: "monospace"
    readonly property color textColour: "white"
    readonly property color urgent: "red"
    readonly property bool textFades: false
    readonly property bool peek: false
    property var ran: []
    property QtObject tip: QtObject {
      function ask(button, text) {}
      function withdraw(button) {}
    }
    property QtObject shell: QtObject {
      function serviceFor(id) {
        return ({ "nova.idle": test.idle, "nova.nightlight": test.nightlight, "nova.notifications": test.notifications })[id] ?? null
      }
    }
    function listButton(button, on) {}
    // What nova-caffeine toggle does, as the idle service then hears it.
    function run(command) {
      ran = ran.concat([command])
      if (command === "nova-caffeine toggle") test.idle.caffeine = !test.idle.caffeine
    }
  }

  property Item widget: Indicators {
    bar: test.fakeBar
    settings: ({ items: ["NightLight", "Dnd", "Caffeine"] })
  }

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  // The indicator in <row> ("active" or "inactive") whose dark tip is <tip>,
  // or null.
  function find(item, tip, row) {
    for (const child of item.children) {
      if (child.tipDark === tip && child.row === row) return child
      const below = find(child, tip, row)
      if (below) return below
    }
    return null
  }

  function lit(tip) {
    const shown = find(widget, tip, "active")
    return !!shown && shown.visible && shown.pressable
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check("nothing lit at first", widget.order, [])
    check("a dark one is there to click", find(widget, "Caffeine", "inactive")?.pressable, true)

    find(widget, "Caffeine", "inactive").click(Qt.LeftButton)
    check("Caffeine clicked: toggled", fakeBar.ran, ["nova-caffeine toggle"])
    check("Caffeine on: lit", widget.order, ["Caffeine"])
    check("Caffeine on: its lit copy shows", lit("Caffeine"), true)
    check("Caffeine on: its dark copy hides", find(widget, "Caffeine", "inactive").visible, false)

    find(widget, "Night Light", "inactive").click(Qt.LeftButton)
    check("Night Light clicked: on", nightlight.enabled, true)
    check("Night Light on: lit, nearest the centre", widget.order, ["NightLight", "Caffeine"])
    check("Night Light on: its lit copy shows", lit("Night Light"), true)

    find(widget, "Night Light", "active").click(Qt.LeftButton)
    check("lit Night Light clicked: off", nightlight.enabled, false)
    check("Night Light off: dark again", widget.order, ["Caffeine"])
    check("Night Light off: its dark copy is back", find(widget, "Night Light", "inactive").visible, true)

    idle.caffeine = false
    check("Caffeine off from elsewhere: dark", widget.order, [])

    notifications.doNotDisturb = true
    check("do not disturb on from elsewhere: lit", widget.order, ["Dnd"])
    find(widget, "Silence Notifications", "active").click(Qt.LeftButton)
    check("lit do not disturb clicked: off", notifications.doNotDisturb, false)
    check("do not disturb off: dark", widget.order, [])

    console.log("DONE")
    Qt.quit()
  }
}
