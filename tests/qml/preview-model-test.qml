import QtQuick
import Quickshell
import "plugins/preview/PreviewModel.js" as Model

// Quick Look's rules: the request read, the line under a name, the size of
// the window for each kind and the first part of a text.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(got, want, what) {
    const ok = JSON.stringify(got) === JSON.stringify(want)
    check(ok, what + (ok ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    var info = Model.parse('{"uri":"file:///a/b.png","path":"/a/b.png","name":"b.png","mime":"image/png","kind":"image","type":"PNG image","size":2048,"sizeText":"2.0 kB","items":-1,"icon":["image-x-generic"],"seq":3}')
    same(info, { uri: "file:///a/b.png", path: "/a/b.png", name: "b.png", mime: "image/png", kind: "image", type: "PNG image", size: 2048, sizeText: "2.0 kB", items: -1, icon: ["image-x-generic"], seq: 3 }, "a request is read as it was sent")
    same(Model.parse('{"uri":"file:///x"}'), { uri: "file:///x", path: "", name: "file:///x", mime: "", kind: "other", type: "", size: -1, sizeText: "", items: -1, icon: [], seq: -1 }, "what is missing has its plain value")
    same(Model.parse('{"uri":"file:///x","kind":"hologram","size":"big","icon":[1,"a"]}'), { uri: "file:///x", path: "", name: "file:///x", mime: "", kind: "other", type: "", size: -1, sizeText: "", items: -1, icon: ["a"], seq: -1 }, "an unknown kind is other, a wrong type is not taken")
    same(["", null, "nonsense", "[]", "{}", '{"uri":""}', '{"uri":3}'].map(Model.parse), [null, null, null, null, null, null, null], "anything that is not a file's request is nothing")

    same([
      Model.facts({ kind: "folder", items: 12, type: "Folder" }),
      Model.facts({ kind: "folder", items: 1, type: "Folder" }),
      Model.facts({ kind: "folder", items: -1, type: "Folder" }),
      Model.facts({ kind: "text", items: -1, type: "Plain text", sizeText: "10.4 kB" }),
      Model.facts({ kind: "other", items: -1, type: "", sizeText: "5.0 kB" }),
      Model.facts({ kind: "other", items: -1, type: "Unknown", sizeText: "" })
    ], ["12 items", "1 item", "Folder", "Plain text · 10.4 kB", "5.0 kB", "Unknown"], "the line under a name")

    var room = Qt.size(1000, 700)
    same(Model.stage("image", Qt.size(500, 400), room, 1), { width: 500, height: 400 }, "an image the room holds is its own size")
    same(Model.stage("image", Qt.size(4000, 2000), room, 1), { width: 1000, height: 500 }, "a wide image is made to fit the width, its proportions kept")
    same(Model.stage("image", Qt.size(2000, 4000), room, 1), { width: 350, height: 700 }, "a tall one the height")
    same(Model.stage("image", Qt.size(32, 32), room, 1), { width: 280, height: 280 }, "an icon is made large enough to see")
    same(Model.stage("image", Qt.size(32, 32), Qt.size(200, 200), 1), { width: 200, height: 200 }, "and still no larger than the room")
    same(Model.stage("pdf", Qt.size(0, 0), room, 1), { width: 544, height: 700 }, "a page not there yet is the size of its kind, as far as the room goes")
    same(Model.stage("text", Qt.size(900, 900), room, 1), { width: 720, height: 520 }, "a text has a size of its own, whatever picture")
    same(Model.stage("folder", Qt.size(0, 0), room, 2), { width: 840, height: 600 }, "the sizes follow the interface's scale")
    same(Model.stage("nonsense", Qt.size(0, 0), room, 0), { width: 420, height: 300 }, "an unknown kind and no scale are the plainest")

    same(Model.head("a\tb\r\nc\n", 10, 80), "a    b\nc\n", "a text's tabs are spaces and its line ends one kind")
    same(Model.head("1\n2\n3\n4", 2, 80), "1\n2", "only as many lines as asked")
    same(Model.head("abcdefghij", 5, 4), "abc…", "a long line ends in an ellipsis")
    same(Model.head("ab\u0000cd", 5, 80), null, "a NUL is not text")
    same([Model.head("", 5, 5), Model.head(null, 5, 5)], ["", ""], "and nothing is nothing")

    var known = { "b": "/icons/b.svg", "text-x-generic": "/icons/t.svg" }
    var find = function (name) { return known[name] || "" }
    same([Model.iconFor(["a", "b"], find), Model.iconFor(["a"], find), Model.iconFor([], function () { return "" })], ["/icons/b.svg", "/icons/t.svg", ""], "the first icon the theme has, else the plain page")

    console.log("DONE")
    Qt.quit()
  }
}
