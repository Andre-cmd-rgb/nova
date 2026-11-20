// stub: bin/gdbus record
// stub: bin/gio record
// platform: wayland
// warns: Trying to disable
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/preview" as Preview

// Quick Look's window: a text read as its first part, a folder with its
// count, another file shown in place with a size of its own, a large
// picture decoded at the room's size and a small one at its own, the calls
// it makes to nova-previewer for a selection and for being closed, and
// Return, which opens the file and closes the window. gdbus and gio are
// recorded, not run.
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  Preview.Preview { id: preview }

  function window() {
    for (var i = 0; i < preview.data.length; i++)
      if (preview.data[i] && preview.data[i].contentItem !== undefined) return preview.data[i]
    return null
  }

  function all(ok) {
    var found = []
    function walk(item) {
      if (!item) return
      if (ok(item)) found.push(item)
      for (var i = 0; i < item.children.length; i++) walk(item.children[i])
    }
    walk(window().contentItem)
    return found
  }

  function shown(item) {
    for (var i = item; i; i = i.parent)
      if (!i.visible) return false
    return true
  }

  function note(text) {
    return all(function (i) { return i.text === text && shown(i) }).length > 0
  }

  FileView {
    id: calls
    path: Quickshell.env("HOME") + "/stub-calls"
    printErrors: false
    blockLoading: true
  }

  function called(line) {
    calls.reload()
    return String(calls.text()).split("\n").indexOf(line) >= 0
  }

  function request(fields) {
    return JSON.stringify(Object.assign({ uri: "file:///x", path: "", name: "x", mime: "", kind: "other", type: "", size: -1, sizeText: "", items: -1, icon: [], seq: 1 }, fields))
  }

  Process {
    id: make
    // Two bitmaps Qt reads (PBM): 4000 by 3000 and 300 by 200, all white.
    command: ["sh", "-c", "printf 'first\\tline\\nsecond\\n' >\"$HOME/notes.txt\" && "
      + "{ printf 'P4\\n4000 3000\\n'; head -c 1500000 /dev/zero; } >\"$HOME/large.pbm\" && "
      + "{ printf 'P4\\n300 200\\n'; head -c 7600 /dev/zero; } >\"$HOME/small.pbm\""]
  }

  property var steps: []
  property int tries: 0

  Timer {
    id: next
    interval: 50
    onTriggered: {
      if (test.steps.length === 0) {
        console.log("DONE")
        Qt.quit()
        return
      }
      if (test.steps[0]() === false && test.tries < 100) {
        test.tries++
      } else {
        if (test.tries >= 100) check(false, "a step that never came true (" + test.steps.length + " left)")
        test.tries = 0
        test.steps.shift()
      }
      next.restart()
    }
  }

  Component.onCompleted: {
    make.running = true
    var textSize
    steps = [
      function () { return !make.running },
      function () {
        var home = Quickshell.env("HOME")
        preview.open(request({ uri: "file://" + home + "/notes.txt", path: home + "/notes.txt", name: "notes.txt", kind: "text", type: "Plain text", size: 17, sizeText: "17 bytes", seq: 1 }))
      },
      function () { return preview.head !== "" },
      function () {
        check(window().visible && window().title === "Quick Look", "the window opens, titled Quick Look")
        check(preview.head === "first    line\nsecond\n", "a text's first part is read")
        check(note("notes.txt"), "its name is on the window")
        check(note("first    line\nsecond\n"), "and its text")
        textSize = Qt.size(window().implicitWidth, window().implicitHeight)
        check(window().minimumSize.width === textSize.width && window().maximumSize.height === textSize.height, "the window's size is fixed to the file's")
        preview.open(request({ uri: "file:///stuff", path: "/stuff", name: "stuff", kind: "folder", type: "Folder", items: 4, seq: 2 }))
      },
      function () {
        check(window().visible, "another file is shown in the same window")
        check(note("stuff") && note("4 items"), "a folder: its name, and how many items")
        check(preview.head === "", "the text of the file before is gone")
        check(window().implicitWidth < textSize.width, "and the window is the size of the folder's page, not the text's")
        var home = Quickshell.env("HOME")
        preview.open(request({ uri: "file://" + home + "/large.pbm", path: home + "/large.pbm", name: "large.pbm", mime: "image/x-portable-bitmap", kind: "image", seq: 3 }))
      },
      function () { return preview.pictured },
      function () {
        var cap = preview.picture.sourceSize
        var w = preview.picture.implicitWidth
        var h = preview.picture.implicitHeight
        check(w <= cap.width && h <= cap.height && (w === cap.width || h === cap.height),
          "a large picture is decoded as large as the room in the screen's pixels, no larger (" + w + "x" + h + ")")
        check(Math.abs(w / h - 4 / 3) < 0.01, "and keeps its proportions")
        check(Math.abs(preview.picture.width / preview.picture.height - 4 / 3) < 0.01, "and is drawn at them")
        var home = Quickshell.env("HOME")
        preview.open(request({ uri: "file://" + home + "/small.pbm", path: home + "/small.pbm", name: "small.pbm", mime: "image/x-portable-bitmap", kind: "image", seq: 4 }))
      },
      function () { return preview.pictured && preview.info.name === "small.pbm" },
      function () {
        check(preview.picture.implicitWidth === 300 && preview.picture.implicitHeight === 200, "a small picture is decoded at its own size, never more")
        preview.open(request({ uri: "file:///stuff", path: "/stuff", name: "stuff", kind: "folder", type: "Folder", items: 4, seq: 2 }))
      },
      function () { return !preview.pictured },
      function () {
        preview.select(5)
      },
      function () { return called("gdbus call --session --dest org.gnome.NautilusPreviewer --object-path /org/gnome/NautilusPreviewer --method org.nova.Previewer.Select 5") },
      function () {
        check(true, "an arrow is sent to nova-previewer as the direction GTK numbers it")
        preview.openInApp()
      },
      function () { return called("gio open file:///stuff") },
      function () {
        check(!window().visible, "Return opens the file in its app, and closes the window")
      },
      function () { return called("gdbus call --session --dest org.gnome.NautilusPreviewer --object-path /org/gnome/NautilusPreviewer --method org.nova.Previewer.Closed 2") },
      function () {
        check(true, "nova-previewer is told which file's window closed")
        preview.open("not json")
        check(!window().visible, "a request that is not one opens nothing")
      }
    ]
    next.start()
  }
}
