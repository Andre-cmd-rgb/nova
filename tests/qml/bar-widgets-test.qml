import QtQuick
import Quickshell
import Quickshell.Io
import "services"

// The bar's widgets from the plugins (BarWidgets), against a fake registry
// with one widget: made while it is on, and left out when it is switched
// off while its component is still loading.
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
        on = false
        barWidgets.sync()
        check("off: dropped", made(), false)
        console.log("DONE")
        Qt.quit()
      })
    })
  }
}
