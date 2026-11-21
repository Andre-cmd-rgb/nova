// stub: bin/wl-paste clipboard-watch
// stub: bin/nova-session-pgrep nova-session-pgrep
// warns: null/shell/plugins/clipboard/capture.sh
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/clipboard" as Clipboard
import "plugins/clipboard/ClipboardHistory.js" as Model

// The clipboard history's rules: what an entry is, the history read from
// its file and capture.sh's lines, entries added and dropped, a copy of files,
// and what the picker shows and finds. The answers are those of the rules as
// they were before their rewrite. Then the history and its file
// (History.qml): a copy is written out once and not read back, and a write
// from elsewhere is read.
ShellRoot {
  id: test
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // JSON leaves out what is undefined, and so does the test's answer.
  function same(one, other) {
    return JSON.stringify(one === undefined ? null : one) === JSON.stringify(other)
  }

  function history() {
    return [
      { type: "image", path: "/s/a.png", mime: "image/png", capturedAt: "Monday 14:05" },
      { type: "image", path: "/s/b.jpg", mime: "image/jpeg" },
      { type: "text", text: "file:///home/me/Pictures/cat%20one.JPG" },
      { type: "text", text: "file:///home/me/a.txt\r\nfile://localhost/home/me/b%zz.txt\nnot a file\nfile://relative/x\n" },
      { type: "text", text: "  Hello\n\tWorld  " },
      { type: "text", text: "file:///home/me/doc.pdf" },
      { type: "image", path: "/s/c.webp", mime: "image/webp", capturedAt: "Tuesday 09:00" }
    ]
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(same(["text", "  ", "", { type: "text", text: " a " }, { kind: "text", text: "b" }, { type: "text", text: "  " }, { type: "text" }, { type: "text", text: 5 }, { type: "image", path: "/p.png" }, { type: "image", path: "/p.png", mime: "image/jpeg", capturedAt: "Mon" }, { type: "image", path: "/p.png", capturedAt: null }, { type: "image", path: "/p.png", capturedAt: 0 }, { type: "image" }, { kind: "image", path: 7 }, { type: "video", path: "/v" }, null, undefined, 5, [], ["text"], { type: "text", kind: "image", text: "x" }, { type: "", kind: "text", text: "y" }].map(v => Model.entry(v)), [{"type":"text","text":"text"},null,null,{"type":"text","text":" a "},{"type":"text","text":"b"},null,null,{"type":"text","text":"5"},{"type":"image","path":"/p.png","mime":"image/png"},{"type":"image","path":"/p.png","mime":"image/jpeg","capturedAt":"Mon"},{"type":"image","path":"/p.png","mime":"image/png"},{"type":"image","path":"/p.png","mime":"image/png","capturedAt":"0"},null,{"type":"image","path":"7","mime":"image/png"},null,null,null,null,null,null,{"type":"text","text":"x"},{"type":"text","text":"y"}]), "entries")
    check(same([Model.entryKey({ type: "text", text: "a" }), Model.entryKey({ type: "image", path: "/p" }), Model.entryKey({ type: "image" }), Model.entryKey({}), Model.entryKey(null), Model.entryKey({ type: "other", text: "t", path: "/p" })], ["text:a","image:/p","image:","text:","","text:t"]), "what makes two the same")
    check(same([Model.parse(JSON.stringify(["a", { type: "text", text: "b" }, null, { type: "image", path: "/x.png" }, "  ", { kind: "image", path: "/y.gif", mime: "image/gif" }])), Model.parse(""), Model.parse(null), Model.parse("garbage"), Model.parse("{}"), Model.parse("[]"), Model.parse("5"), Model.parse(" [\"x\"] ")], [[{"type":"text","text":"a"},{"type":"text","text":"b"},{"type":"image","path":"/x.png","mime":"image/png"},{"type":"image","path":"/y.gif","mime":"image/gif"}],[],[],[],[],[],[],[{"type":"text","text":"x"}]]), "the history read")
    check(same([Model.parseLine(JSON.stringify({ type: "text", text: "hi" })), Model.parseLine("  " + JSON.stringify({ type: "image", path: "/z.png" }) + "\n"), Model.parseLine(""), Model.parseLine(null), Model.parseLine("{bad"), Model.parseLine("\"just text\""), Model.parseLine("42"), Model.parseLine("   ")], [{"type":"text","text":"hi"},{"type":"image","path":"/z.png","mime":"image/png"},null,null,null,{"type":"text","text":"just text"},null,null]), "capture.sh's lines")
    check(same([Model.added([{ type: "text", text: "a" }, { type: "text", text: "b" }, { type: "text", text: "c" }], { type: "text", text: "b" }, 10), Model.added([{ type: "text", text: "a" }, { type: "text", text: "b" }, { type: "text", text: "c" }], { type: "text", text: "d" }, 2), Model.added([], { type: "image", path: "/p" }, 5), Model.added([{ type: "image", path: "/p" }], { type: "image", path: "/p" }, 1)], [[{"type":"text","text":"b"},{"type":"text","text":"a"},{"type":"text","text":"c"}],[{"type":"text","text":"d"},{"type":"text","text":"a"}],[{"type":"image","path":"/p"}],[{"type":"image","path":"/p"}]]), "an entry added")
    check(same([Model.removed(["a", "b", "c"], 1), Model.removed(["a", "b", "c"], 3), Model.removed(["a", "b", "c"], -1), Model.removed(["a", "b", "c"], "0"), Model.removed([], 0), Model.removed(["a"], undefined)], [["a","c"],["a","b","c"],["a","b","c"],["b","c"],[],["a"]]), "an entry dropped")
    check(same(["file:///a/b.txt", "file:///a/b.txt\r\nfile:///c%20d/e.png\n", "  file:///spaced  ", "file://localhost/x/y", "file://localhostx/y", "file://host/z", "file:///bad%zzpath", "file:///", "plain text", "", "FILE:///upper", "file:///a\n\nfile:///b", "file://localhost/%41%42"].map(t => Model.filePaths(t)), [["/a/b.txt"],["/a/b.txt","/c d/e.png"],["/spaced"],["/x/y"],[],[],["/bad%zzpath"],["/"],[],[],[],["/a","/b"],["/AB"]]), "a copy of files")
    check(same([Model.shownText("short"), Model.shownText("a".repeat(8192)).length, Model.shownText("a".repeat(9000)).length, Model.shownText("a".repeat(5000) + "\n" + "b".repeat(5000)).length, Model.shownText("\n" + "c".repeat(9000)).length, Model.shownText("d".repeat(8192) + "\n" + "e").length, Model.shownText("f".repeat(100) + "\n" + "g".repeat(8092) + "\n").length, Model.shownLength], ["short",8192,8192,5000,8192,8192,100,8192]), "what the picker reads of an entry")
    check(same(Model.views(history()), [{"kind":"image","whole":"","label":"Screenshot from Monday 14:05","picture":"/s/a.png","path":"/s/a.png","mime":"image/png","place":0,"search":"image screenshot image/png monday 14:05"},{"kind":"image","whole":"","label":"Image","picture":"/s/b.jpg","path":"/s/b.jpg","mime":"image/jpeg","place":1,"search":"image screenshot image/jpeg "},{"kind":"file","whole":"/home/me/Pictures/cat one.JPG","label":"cat one.JPG","picture":"/home/me/Pictures/cat one.JPG","path":"/home/me/Pictures/cat one.JPG","mime":"text/plain","place":2,"search":"file:///home/me/pictures/cat%20one.jpg cat one.jpg"},{"kind":"file","whole":"/home/me/a.txt\n/home/me/b%zz.txt","label":"2 files","picture":"","path":"","mime":"text/plain","place":3,"search":"file:///home/me/a.txt\r\nfile://localhost/home/me/b%zz.txt\nnot a file\nfile://relative/x\n 2 files"},{"kind":"text","whole":"  Hello\n\tWorld  ","label":" Hello World ","picture":"","path":"","mime":"text/plain","place":4,"search":"  hello\n\tworld   "},{"kind":"file","whole":"/home/me/doc.pdf","label":"doc.pdf","picture":"","path":"/home/me/doc.pdf","mime":"text/plain","place":5,"search":"file:///home/me/doc.pdf doc.pdf"},{"kind":"image","whole":"","label":"Image from Tuesday 09:00","picture":"/s/c.webp","path":"/s/c.webp","mime":"image/webp","place":6,"search":"image screenshot image/webp tuesday 09:00"}]), "what the picker shows")
    check(same([Model.rows(Model.views(history()), "", 50).map(r => r.place), Model.rows(Model.views(history()), "  HELLO ", 50).map(r => r.place), Model.rows(Model.views(history()), "screenshot", 50).map(r => r.place), Model.rows(Model.views(history()), "image", 2).map(r => r.place), Model.rows(Model.views(history()), "2 files", 50).map(r => r.place), Model.rows(Model.views(history()), "jpeg", 50).map(r => r.place), Model.rows(Model.views(history()), null, 3).map(r => r.place), Model.rows(Model.views(history()), "nothing like it", 50).map(r => r.place), Model.rows(Model.views(history()), "", 0).map(r => r.place)], [[0,1,2,3,4,5,6],[4],[0,1,6],[0,1],[3],[1],[0,1,2],[],[]]), "and finds")

    seed.running = true
  }

  // ------------------------------------------------------------ the file

  readonly property string file: Quickshell.env("HOME") + "/.local/state/nova/clipboard-history.json"
  property int updates: 0
  property var steps: []

  // Runs the steps in turn, each once the one before has said it is done
  // (returned true), polling; a step that never is ends the test.
  function then(list) {
    steps = list
    waited = 0
    poll.start()
  }
  property int waited: 0
  Timer {
    id: poll
    interval: 50
    repeat: true
    onTriggered: {
      if (test.steps.length === 0) return stop()
      if (test.steps[0]()) {
        test.steps = test.steps.slice(1)
        test.waited = 0
      } else if (++test.waited > 100) {
        stop()
        check(false, "the history's file: a step that never came to pass")
        finish()
      }
    }
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // A history on disk before the shell starts.
  Process {
    id: seed
    command: ["sh", "-c", 'mkdir -p "${0%/*}" && printf \'[{"type":"text","text":"before"}]\\n\' >"$0"', test.file]
    onExited: {
      holder.active = true
      test.then([
        () => holder.item && holder.item.entries.length === 1 && holder.item.entries[0].text === "before",
        function () {
          check(test.updates === 1, "the history is read from its file as the shell starts")
          for (const word of ["one", "two", "three"]) holder.item.add(JSON.stringify({ type: "text", text: word }))
          check(test.updates === 4 && holder.item.entries.map(e => e.text).join(" ") === "three two one before", "each copy goes on top, at once")
          kept = holder.item.entries
          settled.start()
          return true
        },
        () => !settled.running,
        function () {
          check(test.updates === 4 && holder.item.entries === kept, "the history's own writes are not read back: once a copy, not twice")
          disk.running = true
          return true
        },
        () => !disk.running && disk.done,
        function () {
          check(disk.text === JSON.stringify(holder.item.entries) + "\n", "the file holds the history as compact JSON, ending in a newline")
          elsewhere.running = true
          return true
        },
        () => holder.item.entries.length === 1 && holder.item.entries[0].text === "elsewhere",
        function () {
          check(test.updates === 5, "a write from elsewhere is read, once")
          finish()
          return true
        }
      ])
    }
  }
  property var kept: null

  // Long enough for the file's change to come back to its FileView.
  Timer { id: settled; interval: 1500 }

  Process {
    id: disk
    property bool done: false
    property string text: ""
    command: ["cat", test.file]
    stdout: StdioCollector {
      onStreamFinished: { disk.text = text; disk.done = true }
    }
  }

  Process {
    id: elsewhere
    command: ["sh", "-c", 'printf \'[{"type":"text","text":"elsewhere"}]\\n\' >"$0.part" && mv "$0.part" "$0"', test.file]
  }

  Loader {
    id: holder
    active: false
    sourceComponent: Component {
      Clipboard.History { onUpdated: test.updates++ }
    }
  }
}
