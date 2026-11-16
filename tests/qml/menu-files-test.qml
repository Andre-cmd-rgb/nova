// platform: wayland
// stub: bin/uwsm-app record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/menu"
import "plugins/menu/MenuModel.js" as MenuModel

// The menu's file search: the rows the found files make, their glyphs, the
// folder under each and what opens them; and the real menu, with files.sh on
// a home made here, searched from the root, a file opened with Return and its
// folder with Ctrl+Return, through uwsm-app (a stub that notes what it is
// asked).
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  Menu { id: menu }

  FileView { id: callsFile; path: test.home + "/stub-calls"; blockLoading: true; printErrors: false }

  function calls() {
    callsFile.reload()
    return callsFile.text().trim().split("\n").filter(Boolean)
  }

  // <next> once <ready> holds, looked at every 50 ms for up to 5 s.
  function when(ready, next, what) {
    waiter.ready = ready
    waiter.next = next
    waiter.what = what
    waiter.tries = 0
    waiter.restart()
  }

  Timer {
    id: waiter
    property var ready: null
    property var next: null
    property string what: ""
    property int tries: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (ready()) {
        stop()
        next()
      } else if (++tries > 100) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(rows)

  function rows() {
    const home = "/home/me"
    const printed = "d\t/home/me/Documents\nf\t/home/me/Documents/Tax 2025.pdf\nf\t/home/me/it's here.png\nf\t/srv/notes\n"
    const found = MenuModel.fileRows(printed, "", home, true)
    check(found.map(row => row.glyph).join(" ") === "\u{F024B} \u{F0226} \u{F021F} \u{F0214}",
      "a folder, a PDF, a picture and a file with no extension each have their glyph")
    check(found.map(row => row.label + "|" + row.line).join(" ") === "Documents|~ Tax 2025.pdf|~/Documents it's here.png|~ notes|/srv",
      "each by its name, with its folder under it, the home as ~")
    check(found[2].command === "uwsm-app -- xdg-open '/home/me/it'\\''s here.png'",
      "a file opens with its app, its path one word whatever it holds")
    check(MenuModel.folderCommand(found[1]) === "uwsm-app -- xdg-open '/home/me/Documents'"
      && MenuModel.folderCommand(found[3]) === "uwsm-app -- xdg-open '/srv'"
      && MenuModel.folderCommand({ kind: "app", key: "apps.x" }) === "", "its folder opens the same way; an app has none")
    check(found.every(row => row.section === "files") && MenuModel.fileRows(printed, "", home, false).every(row => row.section === ""),
      "under a divider after other rows, and none when they are all there is")
    check(MenuModel.fileRows(printed, "TAX 20", home, false).map(row => row.label).join() === "Tax 2025.pdf",
      "an earlier search's files show while the next is asked, those that still hold every word")
    check(MenuModel.findsFiles("root", " tax ") && !MenuModel.findsFiles("root", "ta") && !MenuModel.findsFiles("style", "taxes"),
      "files are found from the root alone, from the third letter")
    const size = { row: 10, tall: 20, gap: 1, divider: 5, peek: 3 }
    check(MenuModel.listHeight([{ line: "", section: "" }, { line: "~", section: "files" }, { line: "~", section: "files" }], 1000, size) === 10 + 1 + 5 + 20 + 1 + 20,
      "the files' divider has its room, once")

    files.running = true
  }

  // A home with three files and a hidden one.
  Process {
    id: files
    command: ["bash", "-c", 'mkdir -p "$HOME/Documents" "$HOME/.private" && : >"$HOME/Documents/Tax Return.pdf" && : >"$HOME/taxi.png" && : >"$HOME/.private/tax.txt"']
    onExited: test.search()
  }

  function search() {
    menu.open("{}")
    menu.filter("ta")
    check(!menu.rows.some(row => row.kind === "file"), "two letters find no files")
    menu.filter("tax")
    when(() => menu.rows.filter(row => row.kind === "file").length === 2, found, "a search from the root finds the home's files")
  }

  function found() {
    const labels = menu.rows.map(row => row.label).join(",")
    check(labels === "taxi.png,Tax Return.pdf", "the shallower first, and nothing hidden (" + labels + ")")
    menu.cursor = 1
    menu.press({ key: Qt.Key_Return, modifiers: Qt.ControlModifier, text: "\r" })
    when(() => test.calls().length === 1, folder, "Ctrl+Return opens the file's folder")
  }

  function folder() {
    check(test.calls()[0] === "uwsm-app -- xdg-open " + test.home + "/Documents" && !menu.opened,
      "Ctrl+Return opens the folder the file is in, and the menu closes")
    menu.open("{}")
    menu.filter("tax ret")
    when(() => menu.rows.length === 1 && menu.rows[0].kind === "file", opened, "every word narrows the files")
  }

  function opened() {
    menu.press({ key: Qt.Key_Return, modifiers: Qt.NoModifier, text: "\r" })
    when(() => test.calls().length === 2, () => {
      check(test.calls()[1] === "uwsm-app -- xdg-open " + test.home + "/Documents/Tax Return.pdf", "Return opens the file with its app")
      finish()
    }, "Return opens the file")
  }
}
