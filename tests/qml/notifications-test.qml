import QtQuick
import Quickshell
import "plugins/notifications/NotificationLogic.js" as NotificationLogic

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
    check(NotificationLogic.withoutImages("<b>Hi</b><img src=\"http://x/y.png\">there<IMG/>") === "<b>Hi</b>there"
      && NotificationLogic.withoutImages("<\u0085img src=\"http://x/y.png\">") === ""
      && NotificationLogic.withoutImages(spliced) === spliced
      && NotificationLogic.withoutImages("a <img src=x") === "a ",
      "image tags go whole, never joining what is left into a new one")
    check(NotificationLogic.bodyMarkup("<x\n<img src=\"http://a/b.png\">", "", "") === "<x<br/>"
      && NotificationLogic.bodyMarkup("one\r\ntwo\rthree", "", "") === "one<br/>two<br/>three",
      "lines broken by <br/>, and an image tag the break uncovers dropped")
    check(NotificationLogic.shownBody("example.com Hello", "Chromium", "") === "Hello"
      && NotificationLogic.shownBody("<a href=\"https://x.org\">x.org</a> Hi", "", "brave-browser") === "Hi"
      && NotificationLogic.shownBody("example.com Hello", "firefox", "") === "example.com Hello",
      "a browser's notification without the site's address first")
    check(NotificationLogic.startsWithGlyph("\u{F009A}  Silenced") && !NotificationLogic.startsWithGlyph("\u{F009A} One")
      && !NotificationLogic.startsWithGlyph("Hi  there"), "a summary that starts with a glyph of its own")

    check(JSON.stringify(NotificationLogic.runnable("[\"nova-x\",\"a b\"]")) === "[\"nova-x\",\"a b\"]"
      && NotificationLogic.runnable("[\"-rf\"]") === null && NotificationLogic.runnable("[\"a\",2]") === null
      && NotificationLogic.runnable("not json") === null && NotificationLogic.runnable("") === null,
      "a click runs an array of strings, a program first, or nothing")
    check(NotificationLogic.breaksThroughDnd({ appName: "nova-action", urgency: 0 })
      && NotificationLogic.breaksThroughDnd({ appName: "notify-send", urgency: 2 })
      && !NotificationLogic.breaksThroughDnd({ appName: "Slack", urgency: 2 })
      && NotificationLogic.passing({ appName: "Slack", hints: { transient: true } }) && !NotificationLogic.passing({ appName: "Slack", hints: {} }),
      "what do-not-disturb lets through, and what it does not keep")
    check(NotificationLogic.lifetime(2, 99999) === 0 && NotificationLogic.lifetime(0, 0) === 5000 && NotificationLogic.lifetime(1, -1) === 8000
      && NotificationLogic.lifetime(1, 12000.4) === 12000 && NotificationLogic.lifetime(1, 60000) === 30000,
      "a toast stays 5 s low, 8 s normal, longer if asked up to 30 s, and a critical one until closed")

    var disk = NotificationLogic.forDisk({ timestamp: 5, originalId: 3, appIcon: "/tmp/a b.png", image: "image://qsimage/1/2" }, "/s/")
    var again = NotificationLogic.forDisk(disk.entry, "/s/")
    check(disk.entry.appIcon === "file:///s/5-3-appIcon" && disk.entry.image === ""
      && JSON.stringify(disk.copies) === JSON.stringify([{ from: "/tmp/a b.png", to: "/s/5-3-appIcon" }])
      && again.copies.length === 0 && again.entry.appIcon === disk.entry.appIcon,
      "a file is written naming copies of its pictures, and a picture held in memory is dropped")
    check(NotificationLogic.line({ id: 3, originalId: 3, app: "a", timestamp: 5, deadline: 9, extra: 1 })
      === "{\"id\":3,\"originalId\":3,\"app\":\"a\",\"appIcon\":\"\",\"summary\":\"\",\"body\":\"\",\"image\":\"\",\"glyph\":\"\",\"execArgv\":\"\",\"urgency\":1,\"expireTimeout\":0,\"timestamp\":5,\"deadline\":9}",
      "a toast's file: one line, its keys in order")

    var raw = "{\"id\":1,\"timestamp\":10}\n{\"id\":2,\"summary\":\"Torn\n{\"id\":3,\"timestamp\":30,\"expireTimeout\":-4}\n"
    var rows = NotificationLogic.parseFiles(raw)
    check(rows.length === 2 && rows[0].id === 3 && rows[0].expireTimeout === 0 && rows[1].originalId === 1,
      "the files read back newest first, a torn one skipped")
    var replayed = NotificationLogic.replayRows(raw, [{ id: 3, originalId: 3, timestamp: 30, expireTimeout: 9000 }, { id: 4, originalId: 4, timestamp: 40 }], 2)
    check(replayed.length === 2 && replayed[0].id === 4 && replayed[1].id === 3 && replayed[1].expireTimeout === 0,
      "the history: the toasts on screen and the files, each once, newest first, up to the limit")
    check(NotificationLogic.expired({ timestamp: 0, deadline: 100 }, 8000, 99) === false
      && NotificationLogic.expired({ timestamp: 0, deadline: 100 }, 8000, 100) && NotificationLogic.expired({ timestamp: 0 }, 8000, 8000)
      && !NotificationLogic.expired({ timestamp: 0 }, 0, 1e15), "a restored toast's deadline counts, and a critical one never runs out")
    check(NotificationLogic.parseSettings("{\"dnd\":false,\"pending\":[]}").legacy && NotificationLogic.parseSettings("{\"version\":3,\"dnd\":true}").dnd === true
      && NotificationLogic.parseSettings("").dnd === null && NotificationLogic.parseSettings("{").error, "notifications.json, and the old one with the history in it")
    console.log("DONE")
    Qt.quit()
  }
}
