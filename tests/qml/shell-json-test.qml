import QtQuick
import Quickshell
import Quickshell.Io
import "services"
import "services/Layout.js" as Layout

// shell.json as the shell works it out (ShellJson): a user's config with no
// bar has Nova's, the bar drawn, so that a change starts from that bar and
// does not empty it. Nova's shell.json here has a bar of its own, unlike the
// built-in fallback's. A file from before Screen Time's widget was a plugin
// of its own is read as it is meant now, and saved so.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property var novaBar: ({ transparent: false, layout: { left: [{ id: "nova.menu" }], center: [], right: [] } })
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
    onSaved: if (!test.json) test.json = maker.createObject(test)
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
    check("a change saves", json.edit(config => { config.bar.transparent = true }), true)
    check("  the change made", json.current.bar.transparent, true)
    check("  and Nova's widgets kept", same(json.current.bar.layout, novaBar.layout), true)
    check("Nova's bar itself untouched", json.defaults.bar.transparent, false)
    // The bar is always at the top: an edge an older config names is dropped
    // when the config is saved.
    check("an old config's edge is not kept", json.edit(config => { config.bar.position = "bottom" }), true)
    check("  it is gone from what is in effect", json.current.bar.position, undefined)
    upgrades()
  }

  readonly property var olderLayout: ({ left: [], center: [], right: [{ id: "nova.tray" }, { id: "nova.screentime", showTotal: false, indicator: true }, { id: "nova.network" }] })

  // Before 1.0.0-rc.15 Screen Time's entry in the bar was its widget and its
  // switch at once. nova-shell-config carries the same migration in jq: its
  // test (tests/unit/cli/bar.bats) takes these same cases to the same ends,
  // so that the two rules are held to one behaviour, not only one map.
  function upgrades() {
    const older = { version: 1, bar: { layout: olderLayout }, plugins: [] }
    const read = Layout.upgraded(older)
    check("an older Screen Time entry is its widget's place, switched off, with its settings",
      JSON.stringify(read.bar.layout.right), '[{"id":"nova.tray"},{"id":"nova.screentime-today","showTotal":false,"off":true},{"id":"nova.network"}]')
    check("  and Screen Time records on", JSON.stringify(read.plugins), '[{"id":"nova.screentime"}]')
    check("  the file read left as it was", older.bar.layout.right[1].id, "nova.screentime")
    const stopped = Layout.upgraded({ version: 1, bar: { layout: { right: [{ id: "nova.screentime", off: true }] } } })
    check("one switched off: the widget's place, off, and Screen Time off",
      JSON.stringify([stopped.bar.layout.right, stopped.plugins]), '[[{"id":"nova.screentime-today","off":true}],[]]')
    const both = Layout.upgraded({ version: 1, bar: { layout: { right: [{ id: "nova.screentime" }, { id: "nova.screentime-today" }] } }, plugins: [{ id: "nova.screentime" }] })
    check("one beside the widget already: the widget stays, once, and Screen Time is named once",
      JSON.stringify([both.bar.layout.right, both.plugins]), '[[{"id":"nova.screentime-today"}],[{"id":"nova.screentime"}]]')
    const bare = Layout.upgraded({ version: 1, bar: { layout: { right: ["nova.screentime"] } } })
    check("a bare-string entry is on too: the widget's place, off, and Screen Time on",
      JSON.stringify([bare.bar.layout.right, bare.plugins]), '[[{"id":"nova.screentime-today","off":true}],[{"id":"nova.screentime"}]]')
    const now = { version: 1, bar: { layout: { right: [{ id: "nova.tray" }] } }, plugins: [] }
    check("a config of today is not copied", Layout.upgraded(now) === now, true)
    user.setText(JSON.stringify(older) + "\n")
    waiter.start()
  }

  // What is on disk, read as it is now.
  FileView {
    id: onDisk
    path: test.home + "/.config/nova/shell.json"
    blockAllReads: true
    printErrors: false
  }

  // The older file is written from outside right after the shell's own two
  // saves, so it can land while the shell reads its own save back, and a
  // FileView that is reading does not hear of it (Commons/WatchedFile.qml
  // says how; ShellJson's file is a plain one). What is tested here is how
  // the file is read, not that the change is heard, so the shell is asked to
  // read again until it has.
  Timer {
    id: waiter
    property int left: 100
    interval: 50
    repeat: true
    onTriggered: {
      if (!(test.json.current.plugins || []).length && --left > 0) {
        test.json.reload()
        return
      }
      stop()
      test.check("the shell reads an older file as it is meant now",
        JSON.stringify([test.json.current.bar.layout.right[1], test.json.current.plugins]), '[{"id":"nova.screentime-today","showTotal":false,"off":true},[{"id":"nova.screentime"}]]')
      test.json.edit(config => { config.bar.transparent = true })
      written.start()
    }
  }

  Timer {
    id: written
    property int left: 100
    interval: 50
    repeat: true
    onTriggered: {
      onDisk.reload()
      if (!onDisk.text().includes("screentime-today") && --left > 0) return
      stop()
      let saved = {}
      try { saved = JSON.parse(onDisk.text()) } catch (notYet) { }
      test.check("  and saves it so at the next change", JSON.stringify([saved.bar?.layout?.right?.[1]?.id, saved.plugins]), '["nova.screentime-today",[{"id":"nova.screentime"}]]')
      console.log("DONE")
      Qt.quit()
    }
  }
}
