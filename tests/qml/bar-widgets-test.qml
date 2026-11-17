import QtQuick
import Quickshell
import Quickshell.Io
import "services"

// The bar's widgets from the plugins (BarWidgets), against a fake registry
// with one widget: made while it is on, and left out when it is switched
// off while its component is still loading. A widget made stays makeable
// through a garbage collection: a slot built later (the bar remapped after
// a scale change, a layout changed) makes its widget from it then, and a
// component collected made nothing, which left the bar with the clock alone.
ShellRoot {
  id: test

  readonly property string widgetPath: Quickshell.env("HOME") + "/FakeWidget.qml"
  property bool on: true
  property bool ran: false

  property BarWidgets barWidgets: BarWidgets {
    registry: QtObject {
      readonly property var manifests: ({ "nova.fake": { id: "nova.fake", kinds: ["bar-widget"] } })
      function has(manifest, kind) { return manifest.kinds.indexOf(kind) >= 0 }
      function isOn(id) { return test.on }
      function entryUrl(manifest, kind) { return "file://" + test.widgetPath }
    }
  }

  FileView {
    id: widget
    path: test.widgetPath
    preload: false
    printErrors: false
    onSaved: test.begin()
  }

  function check(name, got, want) {
    console.log((got === want ? "ok   " : "FAIL ") + name + (got === want ? "" : ": got " + got + ", want " + want))
  }

  function made() {
    return barWidgets.widgets["nova.fake"] !== undefined
  }

  // Runs <then> once no widget is being made.
  function whenMade(then) {
    if (barWidgets.making["nova.fake"] === undefined) then()
    else Qt.callLater(() => whenMade(then))
  }

  Component.onCompleted: widget.setText("import QtQuick\nItem { property var bar }\n")

  function begin() {
    if (ran) return
    ran = true
    barWidgets.sync()
    check("on: being made", barWidgets.making["nova.fake"] !== undefined, true)
    on = false
    barWidgets.sync()
    whenMade(() => {
      check("switched off while it loaded: left out", made(), false)
      on = true
      barWidgets.sync()
      whenMade(() => {
        check("on again: made", made(), true)
        // A slot that loads it, then goes, as every slot does when the
        // bar is remapped after a scale change.
        const slot = slotMaker.createObject(stage, { source: barWidgets.widgets["nova.fake"].component })
        check("a slot loads it", slot.item !== null, true)
        slot.destroy()
        collector.start()
      })
    })
  }

  Item {
    id: stage
  }

  Component {
    id: slotMaker
    Loader {
      property Component source
      sourceComponent: source
    }
  }

  // The collection runs from here, where nothing holds the widgets, as the
  // engine's own does whenever it runs: from a function that has them in
  // hand, they would be kept for that alone.
  Timer {
    id: collector
    interval: 1
    onTriggered: { gc(); after.start() }
  }

  Timer {
    id: after
    interval: 1
    onTriggered: {
      const kept = test.barWidgets.widgets["nova.fake"].component
      test.check("a slot gone and a garbage collection leave its component, for the next slot", kept.status, Component.Ready)
      test.on = false
      test.barWidgets.sync()
      test.check("off: dropped", test.made(), false)
      console.log("DONE")
      Qt.quit()
    }
  }
}
