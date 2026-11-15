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
    var buttons = JSON.stringify([{ says: " Decline ", argv: ["nova-airdrop", "decline", "7-1"] }, { says: "Accept", argv: ["nova-airdrop", "accept", "7-1"], main: true },
      { says: "", argv: ["x"] }, { says: "Bad", argv: ["-rf"] }, { says: "Fourth", argv: ["a"] }, { says: "Fifth", argv: ["b"] }, { says: "Sixth", argv: ["c"] }])
    check(JSON.stringify(Notes.buttonsOf(buttons)) === JSON.stringify([{ says: "Decline", argv: ["nova-airdrop", "decline", "7-1"], main: false },
        { says: "Accept", argv: ["nova-airdrop", "accept", "7-1"], main: true }, { says: "Fourth", argv: ["a"], main: false }])
      && Notes.buttonsOf("").length === 0 && Notes.buttonsOf("{\"says\":\"x\"}").length === 0 && Notes.buttonsOf("[null,7]").length === 0,
      "buttons: what each says and the command it runs, three at most, those without words or a sound command left out")
    check([Notes.progressOf("40"), Notes.progressOf(140), Notes.progressOf(-3), Notes.progressOf(""), Notes.progressOf(undefined), Notes.progressOf("x"), Notes.progressOf(0)].join() === "40,100,0,-1,-1,-1,0",
      "a bar from 0 to 100, or none")
    check(Notes.moot({ buttons: buttons, progress: -1 }) && Notes.moot({ buttons: "", progress: 0 }) && !Notes.moot({ buttons: "", progress: -1 }) && !Notes.moot({}),
      "an offer or a transfer under way is moot once gone, anything else is not")
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
      === "{\"id\":3,\"originalId\":3,\"app\":\"a\",\"appIcon\":\"\",\"summary\":\"\",\"body\":\"\",\"image\":\"\",\"glyph\":\"\",\"execArgv\":\"\",\"buttons\":\"\",\"urgency\":1,\"expireTimeout\":0,\"progress\":-1,\"timestamp\":5,\"deadline\":9}",
      "a toast's file: one line, its keys in order")

    var raw = "{\"id\":1,\"timestamp\":10}\n{\"id\":2,\"summary\":\"Torn\n{\"id\":3,\"timestamp\":30,\"expireTimeout\":-4}\n"
    var rows = Notes.parseFiles(raw)
    check(rows.length === 2 && rows[0].id === 3 && rows[0].expireTimeout === 0 && rows[1].originalId === 1,
      "the files read back newest first, a torn one skipped")
    var replayed = Notes.replayRows(raw, [{ id: 3, originalId: 3, timestamp: 30, expireTimeout: 9000 }, { id: 4, originalId: 4, timestamp: 40 }], 2)
    check(replayed.length === 2 && replayed[0].id === 4 && replayed[1].id === 3 && replayed[1].expireTimeout === 0,
      "the history: the toasts on screen and the files, each once, newest first, up to the limit")
    var withOffer = Notes.replayRows("", [{ id: 5, originalId: 5, timestamp: 50, buttons: buttons }, { id: 6, originalId: 6, timestamp: 60, progress: 40 }, { id: 4, originalId: 4, timestamp: 40 }], 5)
    check(withOffer.length === 1 && withOffer[0].id === 4 && withOffer[0].progress === -1, "the history leaves out an offer and a transfer under way")
    check(Notes.parseFiles("{\"id\":1,\"timestamp\":10,\"progress\":45}\n{\"id\":2,\"timestamp\":20}")[1].progress === 45
      && Notes.parseFiles("{\"id\":2,\"timestamp\":20}")[0].progress === -1, "a toast's file keeps its bar, and an older file has none")
    check(Notes.expired({ timestamp: 0, deadline: 100 }, 8000, 99) === false
      && Notes.expired({ timestamp: 0, deadline: 100 }, 8000, 100) && Notes.expired({ timestamp: 0 }, 8000, 8000)
      && !Notes.expired({ timestamp: 0 }, 0, 1e15), "a restored toast's deadline counts, and a critical one never runs out")
    check(Notes.readSettings("{\"dnd\":false,\"pending\":[]}").legacy && Notes.readSettings("{\"version\":3,\"dnd\":true}").dnd === true
      && Notes.readSettings("").dnd === null && Notes.readSettings("").problem === "" && Notes.readSettings("{").problem !== ""
      && Notes.readSettings("null").dnd === null, "notifications.json, and the old one with the history in it")

    var sent = { id: 7, appName: "Mail", appIcon: "", summary: 5, body: "b", image: "", urgency: 0, expireTimeout: -3,
      hints: { "nova-glyph": "g", "nova-exec-argv": "[\"x\"]" } }
    var row = Notes.rowOf(sent, 50)
    check(JSON.stringify(row) === "{\"id\":7,\"originalId\":7,\"app\":\"Mail\",\"appIcon\":\"\",\"summary\":\"5\",\"body\":\"b\",\"image\":\"\",\"glyph\":\"g\",\"execArgv\":\"[\\\"x\\\"]\",\"buttons\":\"\",\"urgency\":0,\"expireTimeout\":0,\"progress\":-1,\"timestamp\":50}"
      && Notes.rowOf(sent, 50, 3).id === 3 && Notes.rowOf(sent, 50, 3).originalId === 3,
      "a notification's row: its roles in the file's order, low urgency kept, under the toast's own id when given")
    var transfer = Notes.rowOf({ id: 8, appName: "nova-action", summary: "s", urgency: 2, hints: { "nova-buttons": buttons, "value": 35 } }, 60)
    check(transfer.buttons === buttons && transfer.progress === 35 && Notes.differs(transfer, Notes.rowOf({ id: 8, appName: "nova-action", summary: "s", urgency: 2, hints: { "nova-buttons": buttons, "value": 40 } }, 60)),
      "a notification's buttons and bar are in its row, and a bar that moves is drawn anew")
    sent.body = "changed"
    check(Notes.differs(row, Notes.rowOf(sent, 50)) && !Notes.differs(row, Notes.rowOf(Object.assign({}, sent, { body: "b", id: 9 }), 60)),
      "an update counts when it changes what is drawn")
    check(JSON.stringify(Notes.plain({ timestamp: 1, id: 2, extra: 3 })) === JSON.stringify({ id: 2, originalId: undefined, app: undefined,
      appIcon: undefined, summary: undefined, body: undefined, image: undefined, glyph: undefined, execArgv: undefined, buttons: undefined, urgency: undefined,
      expireTimeout: undefined, progress: undefined, timestamp: 1 }), "a model's row as a plain one: its roles only")
    console.log("DONE")
    Qt.quit()
  }
}
