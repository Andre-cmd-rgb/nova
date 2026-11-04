import QtQuick
import Quickshell
import "plugins/notifications/NotificationLogic.js" as Notes

// The notifications' rules: what a toast's body may show, how long it stays,
// what a click runs, and the files toasts and the history are kept in.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var spliced = "<im<img src=\"http://a/d.png\">g src=\"http://a/b.png\">"
    check(Notes.withoutImages("<b>Hi</b><img src=\"http://x/y.png\">there<IMG/>") === "<b>Hi</b>there"
      && Notes.withoutImages("<\u0085img src=\"http://x/y.png\">") === ""
      && Notes.withoutImages(spliced) === spliced
      && Notes.withoutImages("a <img src=x") === "a ",
      "image tags go whole, never joining what is left into a new one")
    check(Notes.bodyMarkup("<x\n<img src=\"http://a/b.png\">", "", "") === "<x<br/>"
      && Notes.bodyMarkup("one\r\ntwo\rthree", "", "") === "one<br/>two<br/>three",
      "lines broken by <br/>, and an image tag the break uncovers dropped")
    check(Notes.shownBody("example.com Hello", "Chromium", "") === "Hello"
      && Notes.shownBody("<a href=\"https://x.org\">x.org</a> Hi", "", "brave-browser") === "Hi"
      && Notes.shownBody("example.com Hello", "firefox", "") === "example.com Hello",
      "a browser's notification without the site's address first")
    check(Notes.startsWithGlyph("\u{F009A}  Silenced") && !Notes.startsWithGlyph("\u{F009A} One")
      && !Notes.startsWithGlyph("Hi  there") && Notes.startsWithGlyph(" \u{F009A}  Indented") && !Notes.startsWithGlyph("\uD83D  x")
      && !Notes.startsWithGlyph("   "), "a summary that starts with a glyph of its own, a surrogate pair one character")

    check(JSON.stringify(Notes.runnable("[\"nova-x\",\"a b\"]")) === "[\"nova-x\",\"a b\"]"
      && Notes.runnable("[\"-rf\"]") === null && Notes.runnable("[\"a\",2]") === null
      && Notes.runnable("not json") === null && Notes.runnable("") === null,
      "a click runs an array of strings, a program first, or nothing")
    check(Notes.breaksThroughDnd({ appName: "nova-action", urgency: 0 })
      && Notes.breaksThroughDnd({ appName: "notify-send", urgency: 2 })
      && !Notes.breaksThroughDnd({ appName: "Slack", urgency: 2 })
      && Notes.passing({ appName: "Slack", hints: { transient: true } }) && !Notes.passing({ appName: "Slack", hints: {} }),
      "what do-not-disturb lets through, and what it does not keep")
    check(Notes.lifetime(2, 99999) === 0 && Notes.lifetime(0, 0) === 5000 && Notes.lifetime(1, -1) === 8000
      && Notes.lifetime(1, 12000.4) === 12000 && Notes.lifetime(1, 60000) === 30000,
      "a toast stays 5 s low, 8 s normal, longer if asked up to 30 s, and a critical one until closed")

    var disk = Notes.forDisk({ timestamp: 5, originalId: 3, appIcon: "/tmp/a b.png", image: "image://qsimage/1/2" }, "/s/")
    var again = Notes.forDisk(disk.entry, "/s/")
    check(disk.entry.appIcon === "file:///s/5-3-appIcon" && disk.entry.image === ""
      && JSON.stringify(disk.copies) === JSON.stringify([{ from: "/tmp/a b.png", to: "/s/5-3-appIcon" }])
      && again.copies.length === 0 && again.entry.appIcon === disk.entry.appIcon,
      "a file is written naming copies of its pictures, and a picture held in memory is dropped")
    // The image-path hint as Quickshell hands it over.
    var byPath = Notes.forDisk({ timestamp: 5, originalId: 3, image: "image://icon//tmp/chrome/p.png", appIcon: "image://icon/dialog-information" }, "/s/")
    check(byPath.entry.image === "file:///s/5-3-image" && byPath.entry.appIcon === ""
      && JSON.stringify(byPath.copies) === JSON.stringify([{ from: "/tmp/chrome/p.png", to: "/s/5-3-image" }]),
      "a picture sent by its path is copied too, an icon's name is not")
    check(Notes.line({ id: 3, originalId: 3, app: "a", timestamp: 5, deadline: 9, extra: 1 })
      === "{\"id\":3,\"originalId\":3,\"app\":\"a\",\"appIcon\":\"\",\"summary\":\"\",\"body\":\"\",\"image\":\"\",\"glyph\":\"\",\"execArgv\":\"\",\"urgency\":1,\"expireTimeout\":0,\"timestamp\":5,\"deadline\":9}",
      "a toast's file: one line, its keys in order")

    var raw = "{\"id\":1,\"timestamp\":10}\n{\"id\":2,\"summary\":\"Torn\n{\"id\":3,\"timestamp\":30,\"expireTimeout\":-4}\n"
    var rows = Notes.parseFiles(raw)
    check(rows.length === 2 && rows[0].id === 3 && rows[0].expireTimeout === 0 && rows[1].originalId === 1,
      "the files read back newest first, a torn one skipped")
    var replayed = Notes.replayRows(raw, [{ id: 3, originalId: 3, timestamp: 30, expireTimeout: 9000 }, { id: 4, originalId: 4, timestamp: 40 }], 2)
    check(replayed.length === 2 && replayed[0].id === 4 && replayed[1].id === 3 && replayed[1].expireTimeout === 0,
      "the history: the toasts on screen and the files, each once, newest first, up to the limit")
    check(Notes.expired({ timestamp: 0, deadline: 100 }, 8000, 99) === false
      && Notes.expired({ timestamp: 0, deadline: 100 }, 8000, 100) && Notes.expired({ timestamp: 0 }, 8000, 8000)
      && !Notes.expired({ timestamp: 0 }, 0, 1e15), "a restored toast's deadline counts, and a critical one never runs out")
    check(Notes.parseSettings("{\"dnd\":false,\"pending\":[]}").legacy && Notes.parseSettings("{\"version\":3,\"dnd\":true}").dnd === true
      && Notes.parseSettings("").dnd === null && Notes.parseSettings("").problem === "" && Notes.parseSettings("{").problem !== ""
      && Notes.parseSettings("null").dnd === null, "notifications.json, and the old one with the history in it")

    var sent = { id: 7, appName: "Mail", appIcon: "", summary: 5, body: "b", image: "", urgency: 0, expireTimeout: -3,
      hints: { "nova-glyph": "g", "nova-exec-argv": "[\"x\"]" } }
    var row = Notes.rowOf(sent, 50)
    check(JSON.stringify(row) === "{\"id\":7,\"originalId\":7,\"app\":\"Mail\",\"appIcon\":\"\",\"summary\":\"5\",\"body\":\"b\",\"image\":\"\",\"glyph\":\"g\",\"execArgv\":\"[\\\"x\\\"]\",\"urgency\":0,\"expireTimeout\":0,\"timestamp\":50}"
      && Notes.rowOf(sent, 50, 3).id === 3 && Notes.rowOf(sent, 50, 3).originalId === 3,
      "a notification's row: its roles in the file's order, low urgency kept, under the toast's own id when given")
    sent.body = "changed"
    check(Notes.differs(row, Notes.rowOf(sent, 50)) && !Notes.differs(row, Notes.rowOf(Object.assign({}, sent, { body: "b", id: 9 }), 60)),
      "an update counts when it changes what is drawn")
    check(JSON.stringify(Notes.plain({ timestamp: 1, id: 2, extra: 3 })) === JSON.stringify({ id: 2, originalId: undefined, app: undefined,
      appIcon: undefined, summary: undefined, body: undefined, image: undefined, glyph: undefined, execArgv: undefined, urgency: undefined,
      expireTimeout: undefined, timestamp: 1 }), "a model's row as a plain one: its roles only")
    console.log("DONE")
    Qt.quit()
  }
}
