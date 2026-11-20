// platform: wayland
// warns: PeerClosedError
// warns: inotify_add_watch
// warns: QWaylandTextInputv3
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/file-picker/FilePickerModel.js" as Model

// Nova's file picker, as nova-sessiond talks to it on its socket: a pick for
// each mode, answered with the exact line the backend reads, and the window
// driven as a person would, by clicks and keys: choosing, the filter and the
// name's extension, the question on replacing a file, a new folder, hidden
// files, the location field, a pick cancelled and one the backend ends; and
// the rules in FilePickerModel.js, apart.
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // By its address, as the shell makes a service: a folder with a hyphen in
  // its name is no module's, and no import can name it.
  Loader {
    id: loader
    source: "file://" + Quickshell.env("TEST_PLUGINS") + "/file-picker/FilePicker.qml"
  }
  readonly property var picker: loader.item

  readonly property string socket: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/file-picker.sock"
  readonly property string home: Quickshell.env("HOME")
  readonly property string scratch: home + "/scratch"

  property var heardA: []
  property var heardB: []

  Socket {
    id: appA
    path: test.socket
    parser: SplitParser { onRead: data => test.heardA = test.heardA.concat([data]) }
  }

  Socket {
    id: appB
    path: test.socket
    parser: SplitParser { onRead: data => test.heardB = test.heardB.concat([data]) }
  }

  function say(app, object) {
    app.write((typeof object === "string" ? object : JSON.stringify(object)) + "\n")
    app.flush()
  }

  // The scratch folder: what a person's home might hold. A real 1x1 picture
  // is one of its files, for the thumbnail.
  Process {
    id: making
    running: true
    workingDirectory: test.home
    command: ["sh", "-c", [
      "mkdir -p scratch/docs scratch/empty scratch/locked scratch/Pictures",
      "cd scratch",
      "echo a > a.txt; echo bb > b.txt; echo pdf > report.pdf; echo md > notes.md; echo h > .hidden.txt; echo w > 'we#ird?%.txt'",
      "echo i > docs/inner.txt",
      "printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP43+AAAARBAcAM0e2RAAAAAElFTkSuQmCC' | base64 -d > Photo.PNG",
      "chmod 000 locked"
    ].join("; ")]
    onExited: test.made = true
  }
  property bool made: false

  // So that the scratch home can be removed afterwards.
  Process {
    id: unlock
    command: ["chmod", "755", test.scratch + "/locked"]
  }

  function win() { return picker.window }

  function key(code, text, modifiers) {
    var event = { key: code, text: text || "", modifiers: modifiers || Qt.NoModifier, accepted: false }
    var took = win().handleKey(event)
    return took
  }

  function rowOf(name) {
    var w = win()
    for (var i = 0; i < w.count(); i++) if (w.nameAt(i) === name) return i
    return -1
  }

  function names() {
    var w = win()
    var all = []
    for (var i = 0; i < w.count(); i++) all.push(w.nameAt(i))
    return all.join(",")
  }

  function pick(extra) {
    return Object.assign({
      type: "pick", mode: "open", multiple: false, title: "", app: "", accept: "", folder: test.scratch, name: "", select: "",
      files: [], filters: [], filter: 0, choices: [], places: [], hidden: false
    }, extra)
  }

  readonly property var places: [
    { label: "Home", path: test.home, glyph: "home" },
    { label: "Pictures", path: test.home + "/scratch/Pictures", glyph: "pictures" }
  ]
  readonly property var filters: [
    { name: "Images", globs: ["*.png", "*.jpg"] },
    { name: "All files", globs: ["*"] }
  ]

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

  function ready() {
    var w = win()
    return !!w && w.count() > 0 && w.field !== undefined
  }

  Component.onCompleted: {
    // ---- the rules ----------------------------------------------------------
    var m = Model
    check(m.parse("not json") === null && m.parse('{"type":"later"}') === null && m.parse("[1]") === null
      && m.parse('{"type":"pick","mode":"nope","folder":"/x"}') === null && m.parse('{"type":"pick","mode":"open","folder":"x"}') === null,
      "a line that is not a pick is passed over")
    var r = m.parse(JSON.stringify({ type: "pick", mode: "save", folder: "/a/../b/", name: "x.png", filter: 9, hidden: true, multiple: true,
      choices: [{ id: "e", label: "Encoding", options: [{ id: "u", label: "UTF-8" }], value: "zz" }, { id: "b", label: "BOM", options: [], value: "yes" }, { id: 3 }],
      filters: [{ name: "A", globs: ["*.a", 4] }, 7], places: [{ label: "Bad", path: "rel" }, { label: "Root", path: "/" }] }))
    check(r.folder === "/b" && r.filter === 0 && r.hidden && !r.multiple && r.filters.length === 1 && r.filters[0].globs.length === 1,
      "a request is made tidy: its folder, the filter in range, no several in a save, only the globs that are strings")
    check(r.choices.length === 2 && r.choices[0].value === "u" && r.choices[1].value === "false" && r.places.length === 1,
      "a choice's value is one of its options, a switch's is true or false, a place has an absolute path")
    var many = []
    for (var i = 0; i < 100; i++) many.push({ name: "f" + i, globs: ["*"] })
    check(m.parse(JSON.stringify({ type: "pick", mode: "open", folder: "/", filters: many })).filters.length === 64, "at most 64 filters")
    check(m.title({ mode: "open", title: "" }) === "Open" && m.title({ mode: "folder", title: "" }) === "Choose a Folder" && m.title({ mode: "save-files", title: "" }) === "Save Files"
      && m.title({ mode: "save", title: "Export Image" }) === "Export Image", "a title: the app's, else the mode's")
    check(m.acceptWords({ mode: "folder", accept: "" }) === "Choose" && m.acceptWords({ mode: "open", accept: "Import" }) === "Import" && m.acceptWords({ mode: "save", accept: "" }) === "Save",
      "the accept button's words")
    check(m.join("/", "a") === "/a" && m.join("/x", "a b") === "/x/a b" && m.parent("/x/y") === "/x" && m.parent("/x") === "/" && m.parent("/") === "/" && m.baseName("/x/y.z") === "y.z",
      "paths joined and split")
    check(m.breadcrumbs("/a/b", "").map(function (c) { return c.label }).join() === "/,a,b" && m.breadcrumbs("/h/u/Pictures", "/h/u").map(function (c) { return c.label + c.path }).join() === "Home/h/u,Pictures/h/u/Pictures",
      "the trail of a path, from the root or from home")
    var long = m.collapse(m.breadcrumbs("/a/b/c/d/e/f", ""), 5, 3)
    check(long.map(function (c) { return c.label }).join() === "/,…,d,e,f" && long[1].path === "/a/b/c", "a long trail loses its middle, the ellipsis going to the last part it hides")
    check(m.fileUrl("/a/b#c/d?e/50%") === "file:///a/b%23c/d%3Fe/50%25" && m.fileUrl("/") === "file:///" && m.fileUrl("/x y") === "file:///x%20y", "an address, each part percent-encoded")
    check(m.nameProblem("") === "empty" && m.nameProblem("a/b") === "slash" && m.nameProblem(".") === "dots" && m.nameProblem("..") === "dots" && m.nameProblem("a.b") === "",
      "what a name may not be")
    check(m.overwriteQuestion("a.png", "/h/Pictures") === "“a.png” already exists in “Pictures”. Replace it?", "the question on replacing")
    var png = ["*.png"], jpg = ["*.jpg", "*.jpeg"]
    check(m.swapExtension("a.PNG", png, jpg) === "a.jpg" && m.swapExtension("a.txt", png, jpg) === "a.txt" && m.swapExtension("a.png", png, ["*"]) === "a.png"
      && m.swapExtension("a.png", png, ["image*"]) === "a.png" && m.swapExtension("noext", ["*"], jpg) === "noext" && m.swapExtension("a.tar.gz", ["*.gz"], png) === "a.tar.png",
      "the extension follows the filter, only from a matching one to a plain *.ext")
    check(m.stemLength("report.pdf") === 6 && m.stemLength(".bashrc") === 7 && m.stemLength("noext") === 5, "a stem")
    var rows = ["alpha", "Beta", "bravo", "charlie"]
    var at = function (i) { return rows[i] }
    check(m.typeAhead(4, at, "b", 0) === 1 && m.typeAhead(4, at, "b", 2) === 2 && m.typeAhead(4, at, "br", 0) === 2 && m.typeAhead(4, at, "z", 0) === -1 && m.typeAhead(4, at, "", 0) === -1,
      "type-ahead: the first name from where it is, ignoring case")
    var now = new Date(2026, 10, 20, 15, 30).getTime()
    check(m.dateLabel(new Date(2026, 10, 20, 14, 2).getTime(), now) === "Today 14:02" && m.dateLabel(new Date(2026, 10, 19, 9, 10).getTime(), now) === "Yesterday 09:10"
      && m.dateLabel(new Date(2026, 2, 12, 8, 0).getTime(), now) === "12 Mar" && m.dateLabel(new Date(2025, 2, 12, 8, 0).getTime(), now) === "12 Mar 2025",
      "dates: today, yesterday, this year, before")
    check(m.sizeLabel(0) === "0 B" && m.sizeLabel(812) === "812 B" && m.sizeLabel(4000) === "4 KB" && m.sizeLabel(1200000) === "1.2 MB" && m.sizeLabel(15400) === "15 KB" && m.sizeLabel(2500000000) === "2.5 GB",
      "sizes in thousands")
    check(m.isImage("PNG") && m.isImage("avif") && !m.isImage("txt") && !m.isImage(""), "the images that get a picture")
    check(m.kindOf("PDF") === "pdf" && m.kindOf("rs") === "code" && m.kindOf("zip") === "archive" && m.kindOf("xyz") === "file" && m.fileGlyph(true, "") === m.glyph("folder"), "a file's kind and glyph")
    check(m.savesLine(["a.txt", "b.txt"]) === "Saves 2 files: a.txt, b.txt" && m.savesLine(["a"]) === "Saves 1 file: a", "what save-files says")
    check(m.placeFor([{ path: "/h" }, { path: "/h/Docs" }, { path: "/" }], "/h/Docs/x") === 1 && m.placeFor([{ path: "/h" }], "/hh") === -1, "the place holding a folder: the longest")
    check(m.resolveLocation("~", "/h", "/f") === "/h" && m.resolveLocation("~/x", "/h", "/f") === "/h/x" && m.resolveLocation("y", "/h", "/f") === "/f/y" && m.resolveLocation("/a/../b", "/h", "/f") === "/b",
      "a typed location")
    check(m.freeName("New Folder", function (n) { return n === "New Folder" || n === "New Folder 2" }) === "New Folder 3", "a name not taken")
    check(m.answerLine(["/a"], -1, { x: "1" }, false) === '{"type":"answer","paths":["/a"],"filter":-1,"choices":{"x":"1"},"hidden":false}\n' && m.cancelLine() === '{"type":"cancel"}\n', "the lines the window says")

    // ---- the picks ----------------------------------------------------------
    steps = [
      function () { return test.made && picker.window === null },
      function () {
        check(!picker.window, "no window while nobody asks")
        appA.connected = true
      },
      function () { return appA.connected },
      // ---- open, several, with filters ----
      function () {
        say(appA, pick({ multiple: true, app: "Editor", filters: filters, filter: 1, select: test.scratch + "/a.txt", places: places }))
      },
      function () { return ready() },
      function () {
        var w = win()
        check(w.title === "Open" && w.visible, "a window titled for its mode")
        check(names() === "docs,empty,locked,Pictures,a.txt,b.txt,notes.md,Photo.PNG,report.pdf,we#ird?%.txt", "folders first, then files, hidden ones left out: " + names())
        check(w.chosenPaths.join() === test.scratch + "/a.txt", "the file asked to select is selected")
        check(w.placeIndex === 0 && w.field === "", "the place that holds the folder is lit; the keys are in the list")
        key(Qt.Key_Down)
        check(w.chosenPaths.join() === test.scratch + "/b.txt", "Down moves the selection")
        key(Qt.Key_End)
        check(w.chosenPaths.join() === test.scratch + "/we#ird?%.txt", "End goes to the last row")
        key(Qt.Key_Home)
        check(w.chosenPaths.join() === test.scratch + "/docs", "Home to the first")
        w.choose(rowOf("a.txt"), Qt.NoModifier)
        w.choose(rowOf("notes.md"), Qt.ShiftModifier)
        check(w.chosenFiles.length === 3, "Shift extends the selection to a range")
        w.choose(rowOf("b.txt"), Qt.ControlModifier)
        check(w.chosenFiles.length === 2 && w.chosenFiles.indexOf(test.scratch + "/b.txt") < 0, "Control takes one away")
        key(Qt.Key_A, "a", Qt.ControlModifier)
        check(w.chosenFiles.length === 6 && w.chosenDirs.length === 0, "Control+A chooses every file")
        w.chooseFilter(0)
      },
      function () { return names() === "docs,empty,locked,Pictures,Photo.PNG" },
      function () {
        check(true, "a filter keeps the folders and the files that match, whatever their case")
        check(win().chosenPaths.length === 0 && win().filterIndex === 0, "and clears the selection")
        key(Qt.Key_H, "h", Qt.ControlModifier)
        win().chooseFilter(1)
      },
      function () { return rowOf(".hidden.txt") >= 0 },
      function () {
        check(win().hidden, "Control+H shows hidden files")
        win().choose(rowOf("we#ird?%.txt"), Qt.NoModifier)
        win().choose(rowOf("a.txt"), Qt.ControlModifier)
        key(Qt.Key_Return)
      },
      function () { return heardA.length === 1 },
      function () {
        check(heardA[0] === JSON.stringify({ type: "answer", paths: [test.scratch + "/we#ird?%.txt", test.scratch + "/a.txt"], filter: 1, choices: {}, hidden: true }),
          "Return answers with the files chosen, the filter and the hidden state: " + heardA[0])
      },
      function () { return !appA.connected && picker.window === null },
      function () {
        check(true, "then the connection closes, and the window is gone")
        appA.connected = true
      },
      function () { return appA.connected },
      // ---- open: folders, history, keys ----
      function () { say(appA, pick({ places: places, filters: filters, filter: 1 })) },
      function () { return ready() },
      function () {
        var w = win()
        w.choose(rowOf("docs"), Qt.NoModifier)
        check(w.chosenDirs.length === 1 && w.canAccept, "a folder can be chosen in a list of files")
        key(Qt.Key_Return)
      },
      function () { return win().folder === test.scratch + "/docs" && rowOf("inner.txt") >= 0 },
      function () {
        var w = win()
        check(w.chosenPaths.length === 0 && w.canBack && !w.canForward, "Return enters a folder; the selection is cleared")
        key(Qt.Key_Left, "", Qt.AltModifier)
      },
      function () { return win().folder === test.scratch && rowOf("docs") >= 0 },
      function () {
        key(Qt.Key_Right, "", Qt.AltModifier)
      },
      function () { return win().folder === test.scratch + "/docs" },
      function () {
        key(Qt.Key_Backspace)
      },
      function () { return win().folder === test.scratch && rowOf("docs") >= 0 },
      function () {
        check(true, "Alt+Left and Alt+Right go back and forward; Backspace goes to the parent")
        key(Qt.Key_P, "p")
        check(win().chosenPaths.join() === test.scratch + "/Pictures", "typing letters jumps to the first name that begins with them")
        key(Qt.Key_Up, "", Qt.AltModifier)
      },
      function () { return win().folder === test.home },
      function () {
        var w = win()
        check(w.placeIndex === 0, "Alt+Up goes up, and the place that holds the folder is lit")
        w.navigate(test.scratch + "/Pictures")
        check(w.placeIndex === 1, "the longest place wins")
        w.navigate(test.scratch)
        check(key(Qt.Key_Slash, "/") && w.locating && w.locationInput.text === "/" && w.field === "location", "typing / opens the location field")
        check(key(Qt.Key_Escape) && !w.locating && !w.done, "Escape closes it, and does not cancel")
        key(Qt.Key_L, "l", Qt.ControlModifier)
        check(w.locating && w.locationInput.text === test.scratch, "Control+L opens it on the folder")
        w.locationInput.text = "~/scratch/docs"
        w.goToLocation()
      },
      function () { return win().folder === test.scratch + "/docs" },
      function () {
        check(!win().locating, "a folder typed with ~ is entered")
        key(Qt.Key_L, "l", Qt.ControlModifier)
        win().locationInput.text = test.scratch + "/a.txt"
        win().goToLocation()
      },
      function () { return heardA.length === 2 },
      function () {
        check(heardA[1] === JSON.stringify({ type: "answer", paths: [test.scratch + "/a.txt"], filter: 1, choices: {}, hidden: false }), "in open, a file typed in the location field answers: " + heardA[1])
        appA.connected = true
      },
      function () { return appA.connected && !picker.window },
      // ---- save ----
      function () {
        say(appA, pick({ mode: "save", name: "report.pdf", filters: [{ name: "PDF", globs: ["*.pdf"] }, { name: "Text", globs: ["*.txt"] }, { name: "All files", globs: ["*"] }],
          app: "Writer", title: "Export", accept: "Export", filter: 0, hidden: false, places: places,
          choices: [{ id: "encoding", label: "Encoding", options: [{ id: "utf8", label: "UTF-8" }, { id: "latin1", label: "Western" }], value: "utf8" }, { id: "bom", label: "Write a byte order mark", options: [], value: "false" }] }))
      },
      function () { return ready() && win().nameInput.text === "report.pdf" },
      function () {
        var w = win()
        check(w.title === "Export" && w.saves && w.canAccept, "a save window, titled by the app")
        check(w.nameInput.selectionStart === 0 && w.nameInput.selectionEnd === 6 && w.field === "name", "the name has the keys, its stem chosen, not its extension")
        check(names() === "docs,empty,locked,Pictures,report.pdf", "the filter's files: " + names())
        w.chooseFilter(1)
        check(w.nameInput.text === "report.txt", "the name's extension follows the filter")
        w.chooseFilter(2)
        check(w.nameInput.text === "report.txt", "and stays when the filter has no plain extension")
        w.chooseFilter(0)
        check(w.nameInput.text === "report.pdf", "and goes back")
        w.chooseFilter(2)
      },
      function () { return rowOf("a.txt") >= 0 },
      function () {
        var w = win()
        w.nameInput.text = "a/b"
        w.accept()
        check(w.message === "A name can’t contain “/”." && !w.done, "a name with a slash is refused, in words")
        w.nameInput.text = ".."
        w.accept()
        check(w.message.indexOf("..") >= 0 && !w.done, "so is ..")
        w.nameInput.text = ""
        check(!w.canAccept, "an empty name leaves nothing to accept")
        w.choose(rowOf("b.txt"), Qt.NoModifier)
        check(w.nameInput.text === "b.txt", "clicking a file puts its name in the field")
        w.nameInput.text = "docs"
        w.accept()
      },
      function () { return win().folder === test.scratch + "/docs" },
      function () {
        check(win().nameInput.text === "", "a name that is a folder enters it")
        win().goBack()
        win().nameInput.text = "a.txt"
        win().accept()
      },
      function () { return win().confirm.asking },
      function () {
        check(win().confirm.question === "“a.txt” already exists in “scratch”. Replace it?" && win().confirm.yes === "Replace", "a file of that name asks, in the window")
        key(Qt.Key_Escape)
        check(!win().confirm.asking && !win().done, "Escape keeps it")
        win().accept()
      },
      function () { return win().confirm.asking },
      function () {
        win().setChoice("bom", "true")
        win().setChoice("encoding", "latin1")
        key(Qt.Key_Return)
      },
      function () { return heardA.length === 3 },
      function () {
        check(heardA[2] === JSON.stringify({ type: "answer", paths: [test.scratch + "/a.txt"], filter: 2, choices: { encoding: "latin1", bom: "true" }, hidden: false }),
          "Replace answers, with the choices: " + heardA[2])
        appA.connected = true
      },
      function () { return appA.connected && !picker.window },
      // ---- save: a new folder, a name that is free ----
      function () { say(appA, pick({ mode: "save", name: "", places: places })) },
      function () { return ready() },
      function () {
        var w = win()
        check(w.field === "name" && !w.canAccept, "an empty name has the keys, and nothing to accept")
        w.startNaming()
        check(w.naming && w.newInput.text === "New Folder", "New Folder proposes its name")
        w.newInput.text = "a/b"
        w.makeFolder()
        check(w.message.indexOf("/") >= 0, "a folder name with a slash is refused")
        w.newInput.text = "docs"
        w.makeFolder()
      },
      function () { return win().message.indexOf("already exists") >= 0 },
      function () {
        check(win().message === "“docs” already exists.", "a folder that exists is said so in plain words")
        win().newInput.text = "New Folder"
        win().makeFolder()
      },
      function () { return win().folder === test.scratch + "/New Folder" },
      function () {
        check(!win().naming, "a folder made is entered")
        win().goUp()
      },
      function () { return win().folder === test.scratch && rowOf("New Folder") >= 0 },
      function () {
        win().startNaming()
        check(win().newInput.text === "New Folder 2", "and the next is numbered")
        key(Qt.Key_Escape)
        check(!win().naming && !win().done, "Escape leaves the name without cancelling")
        win().nameInput.text = "x.txt"
        win().navigate(test.scratch + "/empty")
      },
      function () { return win().bareKind === "empty" },
      function () {
        check(true, "an empty folder is known to be empty")
        win().navigate(test.scratch + "/locked")
      },
      function () { return win().bareKind === "no" },
      function () {
        check(true, "a folder that can't be read is known so")
        key(Qt.Key_Escape)
      },
      function () { return heardA.length === 4 },
      function () {
        check(heardA[3] === '{"type":"cancel"}', "Escape cancels: the backend is told")
        appA.connected = true
      },
      function () { return appA.connected && !picker.window },
      // ---- folder ----
      function () { say(appA, pick({ mode: "folder", multiple: true, title: "Choose backup folders", places: places })) },
      function () { return ready() },
      function () {
        var w = win()
        check(w.title === "Choose backup folders" && w.picksFolders && w.canAccept, "a folder window with its app's title")
        w.choose(rowOf("a.txt"), Qt.NoModifier)
        check(w.chosenPaths.length === 0, "a file can't be chosen, though it is shown")
        key(Qt.Key_Down)
        check(w.chosenPaths.join() === test.scratch + "/docs", "the arrows pass over files")
        w.choose(rowOf("empty"), Qt.ControlModifier)
        key(Qt.Key_Return)
      },
      function () { return win().folder === test.scratch + "/empty" },
      function () {
        check(true, "Return enters the folder under the keys")
        win().accept()
      },
      function () { return heardA.length === 5 },
      function () {
        check(heardA[4] === JSON.stringify({ type: "answer", paths: [test.scratch + "/empty"], filter: -1, choices: {}, hidden: false }), "with none chosen, the folder shown is the answer: " + heardA[4])
        appA.connected = true
      },
      function () { return appA.connected && !picker.window },
      // ---- save-files ----
      function () { say(appA, pick({ mode: "save-files", files: ["a.txt", "b.txt"], places: places })) },
      function () { return ready() },
      function () {
        var w = win()
        check(w.title === "Save Files" && w.request.files.length === 2, "a save-files window")
        w.choose(rowOf("docs"), Qt.NoModifier)
        w.accept()
      },
      function () { return heardA.length === 6 },
      function () {
        check(heardA[5] === JSON.stringify({ type: "answer", paths: [test.scratch + "/docs"], filter: -1, choices: {}, hidden: false }), "the folder chosen is the answer: " + heardA[5])
        appA.connected = true
      },
      function () { return appA.connected && !picker.window },
      // ---- sorting, and the window closed by the manager ----
      function () { say(appA, pick({ filters: [] })) },
      function () { return ready() },
      function () {
        var w = win()
        w.sortBy(2)
        check(w.sortField === 2 && !w.sortReversed, "a column sorts")
        w.sortBy(0)
        w.sortBy(0)
        check(w.sortReversed && w.isDirAt(0), "the same column again reverses, and folders stay first")
        w.visible = false
      },
      function () { return heardA.length === 7 },
      function () {
        check(heardA[6] === '{"type":"cancel"}', "the window closed by the window manager cancels")
        appA.connected = true
      },
      function () { return appA.connected && !picker.window },
      // ---- the queue ----
      function () {
        appB.connected = true
        say(appA, pick({ title: "First" }))
      },
      function () { return appB.connected && ready() },
      function () {
        say(appB, pick({ title: "Second", mode: "folder" }))
      },
      function () { return picker.picks.length === 2 },
      function () {
        check(win().title === "First", "a second pick waits for the first")
        appB.connected = false
      },
      function () { return picker.picks.length === 1 },
      function () {
        check(win().title === "First", "and is dropped when it closes")
        appB.connected = true
      },
      function () { return appB.connected },
      function () { say(appB, pick({ title: "Third", mode: "save" })) },
      function () { return picker.picks.length === 2 },
      function () {
        win().cancel()
      },
      function () { return heardA.length === 8 && picker.window && picker.window.title === "Third" && picker.window.count() > 0 },
      function () {
        check(heardA[7] === '{"type":"cancel"}' && !appA.connected, "when the first ends, the next is shown, in a window of its own")
        appB.connected = false
      },
      function () { return !picker.window && picker.picks.length === 0 },
      function () {
        check(heardB.length === 0, "a backend that closes ends the window, and nothing is sent")
        appA.connected = true
      },
      // ---- what is not a pick ----
      function () { return appA.connected },
      function () { say(appA, "this is not json") },
      function () { return !appA.connected },
      function () {
        check(!picker.window && picker.picks.length === 0, "a line that is not a pick closes the connection, and shows nothing")
        appA.connected = true
      },
      function () { return appA.connected },
      function () { say(appA, pick({ folder: "relative" })) },
      function () { return !appA.connected },
      function () {
        check(!picker.window, "so does a folder that is not absolute")
        unlock.running = true
      },
      function () { return !unlock.running }
    ]
    next.start()
  }
}
