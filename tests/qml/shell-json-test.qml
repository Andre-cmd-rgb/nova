import QtQuick
import Quickshell
import Quickshell.Io
import "services"

// shell.json as the shell works it out (ShellJson): a user's config with no
// bar has Nova's, the bar drawn, so that a change starts from that bar and
// does not empty it. Nova's shell.json here has a bar of its own, unlike the
// built-in fallback's.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property var novaBar: ({ position: "left", layout: { left: [{ id: "nova.menu" }], center: [], right: [] } })
  property var json: null

  Component {
    id: maker
    ShellJson {
      defaultsPath: test.home + "/nova-shell.json"
    }
  }

  // Nova's file, then the user's, then the ShellJson that reads them.
  FileView {
    id: nova
    path: test.home + "/nova-shell.json"
    preload: false
    printErrors: false
    onSaved: user.setText('{ "version": 1, "idle": { "lock": 600 } }\n')
  }

  FileView {
    id: user
    path: test.home + "/.config/nova/shell.json"
    preload: false
    printErrors: false
    onSaved: test.json = maker.createObject(test)
  }

  // A tick after ready: a save from inside ShellJson's own load would drop
  // the read Quickshell is still finishing (a warning). The shell saves only
  // on a user's action, never from there.
  Connections {
    target: test.json
    function onReadyChanged() { Qt.callLater(test.begin) }
  }

  function check(name, got, want) {
    console.log((got === want ? "ok   " : "FAIL ") + name + (got === want ? "" : ": got " + got + ", want " + want))
  }

  function same(a, b) {
    return JSON.stringify(a) === JSON.stringify(b)
  }

  Component.onCompleted: nova.setText(JSON.stringify({ version: 1, bar: novaBar }) + "\n")

  function begin() {
    check("the user's config is the one in effect", json.current.idle.lock, 600)
    check("  with Nova's bar, as it has none", same(json.current.bar, novaBar), true)
    check("a change saves", json.edit(config => { config.bar.position = "bottom" }), true)
    check("  the change made", json.current.bar.position, "bottom")
    check("  and Nova's widgets kept", same(json.current.bar.layout, novaBar.layout), true)
    check("Nova's bar itself untouched", json.defaults.bar.position, "left")
    console.log("DONE")
    Qt.quit()
  }
}
