import QtQuick
import Quickshell
import "plugins/clipboard/ClipboardHistory.js" as ClipboardHistory

// The clipboard's history: the entries clipboard-history.json may hold, a
// copy going to the top, and the rows the picker shows and searches.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var history = ClipboardHistory.parse(JSON.stringify([
      "bare", { type: "text", text: "  " }, { kind: "text", text: "kind" }, { type: "image", path: "/c/a.png", capturedAt: "Monday 14:05" },
      { type: "image", mime: "image/png" }, null, { type: "text", text: "file:///home/me/photo%20one.png" },
      { type: "text", text: "file:///etc/hostname\r\nfile://localhost/etc/os-release" }
    ]))
    check(JSON.stringify(history) === JSON.stringify([{ type: "text", text: "bare" }, { type: "text", text: "kind" },
      { type: "image", path: "/c/a.png", mime: "image/png", capturedAt: "Monday 14:05" },
      { type: "text", text: "file:///home/me/photo%20one.png" }, { type: "text", text: "file:///etc/hostname\r\nfile://localhost/etc/os-release" }]),
      "entries as the file keeps them: blank text, an image with no path and the rest are left out")
    check(ClipboardHistory.parse("not json").length === 0 && ClipboardHistory.parse("{}").length === 0, "a file that does not parse is no history")
    check(ClipboardHistory.entryKey(history[0]) === "text:bare" && ClipboardHistory.entryKey(history[2]) === "image:/c/a.png",
      "an entry's key, whose md5 the paste helpers check")

    var added = ClipboardHistory.added(history, ClipboardHistory.parseLine('{"type":"text","text":"kind"}\n'), 3)
    check(added.map(ClipboardHistory.entryKey).join(" ") === "text:kind text:bare image:/c/a.png",
      "a copy goes to the top, the same entry further down goes, and the history keeps its limit")
    check(ClipboardHistory.removed(history, 1).length === 4 && ClipboardHistory.removed(history, 9).length === 5, "an entry removed by its place")

    var shown = ClipboardHistory.views(history)
    check(shown[2].previewText === "Screenshot from Monday 14:05" && shown[2].previewImage === "/c/a.png" && shown[2].fullText === ""
      && shown[3].entryType === "file" && shown[3].previewText === "photo one.png" && shown[3].previewImage === "/home/me/photo one.png"
      && shown[4].previewText === "2 files" && shown[4].fullText === "/etc/hostname\n/etc/os-release",
      "rows: an image by when it was copied, files by name, each with what the pane shows")
    check(ClipboardHistory.rows(shown, " SCREENSHOT ", 50).length === 1 && ClipboardHistory.rows(shown, "photo one", 50)[0].index === 3
      && ClipboardHistory.rows(shown, "", 2).length === 2, "a search finds words in the text, a file's name and an image's kind, up to the limit")

    var long = ""
    for (var i = 0; i < 2000; i++) long += "line " + i + "\n"
    var big = ClipboardHistory.views([{ type: "text", text: long }])[0]
    check(big.fullText.length <= 8192 && big.fullText.charAt(big.fullText.length - 1) !== "\n" && /line 99\d$/.test(big.fullText) === false
      && big.fullText.split("\n").pop().indexOf("line ") === 0, "a huge paste is shown and searched up to 8 KiB, cut at a line's end")
    console.log("DONE")
    Qt.quit()
  }
}
