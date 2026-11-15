// platform: wayland
// stub: bin/nova-airdrop nova-airdrop
// stub: bin/busctl busctl
// stub: bin/vipsthumbnail vipsthumbnail
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/airdrop"
import "plugins/airdrop/AirDropModel.js" as Model

// AirDrop in the shell: what it makes of each line of `nova airdrop watch`,
// the notifications it sends for it, and what it asks of the command in
// return. nova-airdrop is a stub: its watch says what the test wrote for it,
// and its other calls are noted, as are busctl's (the notifications) and
// vipsthumbnail's (a photo's smaller copy). No radio, no daemon, no bus.
ShellRoot {
  id: test

  property var airdrop: null
  property var toggle: null
  property Item stage: Item {}

  // The shell as far as AirDrop asks it: the lock screen's service.
  property QtObject lock: QtObject { property bool locked: false }
  property QtObject fakeShell: QtObject {
    function serviceFor(id) { return id === "nova.lock" ? test.lock : null }
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property string pictures: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/airdrop-pictures"

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  readonly property string asked: JSON.stringify({ state: "asked", id: "7-1", sender: "Zoë's iPhone",
    files: [{ name: "IMG_0001.HEIC", bytes: 1044468 }], bytes: 1044468, links: [] })
  readonly property string offerSummary: "“Zoë's iPhone” wants to send you a photo"
  readonly property string buttons: JSON.stringify([{ says: "Decline", argv: ["nova-airdrop", "decline", "7-1"] },
    { says: "Accept", argv: ["nova-airdrop", "accept", "7-1"], main: true }])

  function receiving(received) {
    return JSON.stringify({ state: "receiving", sender: "Zoë's iPhone", files: [{ name: "IMG_0001.HEIC", bytes: 1044468 }], received: received, bytes: 1044468 })
  }

  function received(path) {
    return JSON.stringify({ state: "received", sender: "Zoë's iPhone", paths: [path], bytes: 1044468, seconds: 2.2 })
  }

  FileView {
    id: says
    path: test.home + "/airdrop-says"
    printErrors: false
    onSaved: test.second()
  }

  FileView {
    id: failing
    path: test.home + "/thumbnails-fail"
    printErrors: false
    onSaved: test.eighth()
  }

  FileView {
    id: refuses
    path: test.home + "/airdrop-refuses"
    printErrors: false
    onSaved: test.tenth()
  }

  FileView {
    id: calls
    path: test.home + "/stub-calls"
    blockLoading: true
    printErrors: false
  }

  function called() {
    calls.reload()
    calls.waitForJob()
    return calls.text().split("\n").filter(line => line !== "")
  }

  // What was asked of nova-airdrop.
  function asks() {
    return called().filter(line => line.startsWith("nova-airdrop "))
  }

  // The notifications, from busctl's calls: each Notify as the id it
  // replaces, its summary, its body and its hints; each close as its id.
  function notes() {
    return called().filter(line => line.startsWith("busctl\t")).map(line => {
      const w = line.split("\t")
      const at = w.indexOf("Notify")
      if (at < 0) return { close: Number(w[w.length - 1]) }
      const hints = {}
      for (let i = 0; i < Number(w[at + 8]); i++) hints[w[at + 9 + 3 * i]] = w[at + 11 + 3 * i]
      return { replaces: Number(w[at + 3]), summary: w[at + 5], body: w[at + 6], hints: hints }
    })
  }

  function lastNote() {
    const all = notes()
    return all[all.length - 1]
  }

  Component {
    id: made
    AirDrop {}
  }

  Component {
    id: madeToggle
    AirDropToggle {}
  }

  Timer {
    id: wait
    property var next: null
    onTriggered: next()
  }

  function later(ms, next) {
    wait.next = next
    wait.interval = ms
    wait.restart()
  }

  Component.onCompleted: Qt.callLater(first)

  // The rules, with no AirDrop running.
  function first() {
    check("a line that is no state is nothing", [Model.parse("not json"), Model.parse("[1]"), Model.parse('{"state":7}'), Model.parse("null")],
      [null, null, null, null])
    check("sizes as people say them", [Model.size(512), Model.size(20480), Model.size(1044468), Model.size(3200000000), Model.size("x")],
      ["512 bytes", "20 kB", "1.0 MB", "3.20 GB", "0 bytes"])
    check("what is offered, in a few words",
      [Model.what(JSON.parse(asked)), Model.what({ files: [{ name: "a.jpg" }, { name: "b.PNG" }] }), Model.what({ files: [{ name: "a.mov" }, { name: "b.mp4" }] }),
        Model.what({ files: [{ name: "a.jpg" }, { name: "b.pdf" }] }), Model.what({ files: [{ name: "notes" }] }), Model.what({ links: ["x"] }), Model.what({ links: ["x", "y"] })],
      ["a photo", "2 photos", "2 videos", "2 files", "a file", "a link", "2 links"])

    const offer = Model.offer(JSON.parse(asked), "nova-airdrop")
    check("an offer: who wants to send what, its name and size, and the two answers, until answered",
      [offer.summary, offer.body, offer.urgency, JSON.stringify(offer.buttons)], [offerSummary, "IMG_0001.HEIC, 1.0 MB", 2, buttons])
    check("several files are their size, a link itself, a sender with no name someone",
      [Model.offer({ state: "asked", files: [{ name: "a" }, { name: "b" }], bytes: 2500000 }, "x").body, Model.offer({ state: "asked", links: ["https://example.org/"] }, "x").body,
        Model.offer({ state: "asked", links: ["x"] }, "x").summary], ["2.5 MB", "https://example.org/", "Someone wants to send you a link"])
    check("a name is words, never markup", Model.offer({ state: "asked", files: [{ name: "<b>x</b>&.png" }], bytes: 5 }, "x").body, "&lt;b&gt;x&lt;/b&gt;&amp;.png, 5 bytes")

    const coming = Model.receiving(JSON.parse(receiving(522234)))
    check("a transfer: from whom, what, and how far along, until it is over",
      [coming.summary, coming.body, coming.progress, coming.urgency], ["Receiving from “Zoë's iPhone”", "IMG_0001.HEIC", 50, 2])
    check("its bar in steps of 5, all of it at most, nothing for a size never said",
      [Model.receiving({ received: 261117, bytes: 1044468 }).progress, Model.receiving({ received: 9, bytes: 4 }).progress, Model.receiving({ received: 9 }).progress,
        Model.receiving({ received: 3, bytes: 10, files: [{ name: "a.jpg" }, { name: "b.jpg" }] }).body], [25, 100, 0, "2 photos"])

    const photo = Model.arrival(JSON.parse(received("/home/zoe/Downloads/IMG_0001.HEIC")))
    check("one photo in: from whom, where it is, itself for its picture, and it opens at a click", photo,
      { summary: "AirDrop from “Zoë's iPhone”", body: "Saved IMG_0001.HEIC in Downloads", urgency: 1,
        picture: "/home/zoe/Downloads/IMG_0001.HEIC", opens: ["xdg-open", "/home/zoe/Downloads/IMG_0001.HEIC"] })
    const several = Model.arrival({ state: "received", sender: "", paths: ["/home/zoe/Downloads/a.pdf", "/home/zoe/Downloads/notes"] })
    check("several in: their number, and the folder opens", [several.summary, several.body, several.picture, several.opens],
      ["AirDrop from Someone", "Saved 2 things in Downloads", "", ["xdg-open", "/home/zoe/Downloads"]])
    check("a file that is no photo has no picture", Model.arrival({ state: "received", paths: ["/d/a.pdf"] }).picture, "")
    check("a path that is not one, or none at all, is no arrival",
      [Model.arrival({ state: "received", paths: ["relative.png"] }), Model.arrival({ state: "received" })], [null, null])
    const link = Model.arrival({ state: "links", sender: "Zoë's iPhone", links: ["https://example.org/a?b=c&d"] })
    check("a web address opens in the browser", [link.body, link.opens], ["https://example.org/a?b=c&amp;d", ["nova-launch-browser", "https://example.org/a?b=c&d"]])
    check("anything else sent as a link is shown and opens nothing",
      [Model.arrival({ state: "links", links: ["file:///etc/passwd"] }).opens, Model.arrival({ state: "links", links: ["https://a b"] }).opens,
        Model.arrival({ state: "links", links: [] })], [null, null, null])
    check("a failure in the daemon's sentence, a start refused in the command's words",
      [Model.failure({ why: "The transfer stopped." }).summary, Model.failure({ why: "The transfer stopped." }).body, Model.failure({}).body,
        Model.refusal("The Wi-Fi is switched off.").summary, Model.refusal("The Wi-Fi is switched off.").body],
      ["AirDrop didn’t finish", "The transfer stopped.", "Nothing was saved.", "AirDrop couldn’t start", "The Wi-Fi is switched off."])
    check("Qt reads a JPEG, a PNG or a GIF as it is, not a HEIC",
      [Model.readable("/a/b.JPG"), Model.readable("/a/b.png"), Model.readable("/a/b.heic"), Model.readable("")], [true, true, false, false])

    // The calls: busctl takes each word as one value, after its "--".
    const sly = Model.notify({ summary: "--exec rm", body: "-u critical", urgency: 2, buttons: [{ says: "A", argv: ["x"] }], progress: 5 }, 4, "G")
    check("a notification is one busctl call, Nova's own, the text each one word wherever it starts, its hints typed", sly,
      ["busctl", "--user", "--", "call", "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
        "Notify", "susssasa{sv}i", "nova-action", "4", "", "--exec rm", "-u critical", "0", "4",
        "urgency", "y", "2", "nova-glyph", "s", "G", "nova-buttons", "s", '[{"says":"A","argv":["x"]}]', "value", "i", "5", "-1"])
    const opening = Model.notify({ summary: "s", body: "b", urgency: 1, picture: "/p.jpg", opens: ["xdg-open", "/p.jpg"] }, 0, "G")
    check("what came in: its picture and what a click runs", opening.slice(15),
      ["4", "urgency", "y", "1", "nova-glyph", "s", "G", "image-path", "s", "/p.jpg", "nova-exec-argv", "s", '["xdg-open","/p.jpg"]', "-1"])
    check("a close, and the id an answer names", [Model.closing(3).slice(7), Model.answered("u 42\n"), Model.answered(""), Model.answered("x 4")],
      [["CloseNotification", "u", "3"], 42, 0, 0])

    // The doorbell: on for the iPhone's open share sheet while unlocked, once a sheet; off when it closes.
    const bell = (more) => Model.doorbell(Object.assign({ near: false, locked: false, on: false, rung: false, spent: false, state: "off" }, more))
    check("the iPhone shows AirDrop: on, but not while locked, and not again for a sheet that has had it",
      [bell({ near: true }), bell({ near: true, locked: true }), bell({ near: true, spent: true }), bell({})], ["on", "", "", ""])
    check("an AirDrop switched on by hand is not the doorbell's to end",
      [bell({ on: true, state: "waiting" }), bell({ on: true, state: "waiting", locked: true })], ["", ""])
    check("the sheet closed: off, but not from under an offer or a transfer",
      [bell({ on: true, rung: true, state: "waiting" }), bell({ on: true, rung: true, state: "off" }), bell({ on: true, rung: true, state: "asked" }),
        bell({ on: true, rung: true, state: "receiving" }), bell({ on: true, rung: true, state: "received" }), bell({ on: true, rung: true, near: true, state: "waiting" })],
      ["off", "off", "", "", "off", ""])
    check("locked, an AirDrop the doorbell switched on goes off", bell({ on: true, rung: true, near: true, locked: true, state: "asked" }), "off")

    says.setText(JSON.stringify({ state: "waiting", name: "Nova", seen: false, ends: 0 }) + "\n")
  }

  // AirDrop running: the watch is already saying it is on when the shell starts.
  function second() {
    airdrop = made.createObject(stage)
    toggle = madeToggle.createObject(stage, { service: airdrop })
    check("before the watch has said anything, it is off", [airdrop.opened, toggle.opened], [false, false])
    later(1000, third)
  }

  function third() {
    check("the watch's line: AirDrop is on, and the menu's toggle says so", [airdrop.said.state, airdrop.opened, toggle.opened], ["waiting", true, true])
    check("and nothing is said of it: the bar's icon does", notes(), [])
    airdrop.told("not json")
    airdrop.told('{"state":7}')
    check("a line that is no state changes nothing", airdrop.said.state, "waiting")
    airdrop.told(asked)
    later(400, fourth)
  }

  function fourth() {
    check("an offer is a notification of its own, with Decline and Accept, that stays", notes(), [{ replaces: 0, summary: offerSummary,
      body: "IMG_0001.HEIC, 1.0 MB", hints: { urgency: "2", "nova-glyph": "\u{F0003}", "nova-buttons": buttons } }])
    check("its id is kept, to replace it", airdrop.liveId, 1)
    // Accepted from the notification, which goes: the transfer starts.
    airdrop.told(receiving(261117))
    later(300, fifth)
  }

  function fifth() {
    check("for its first moment a transfer has no bar, and the offer is taken away", notes().slice(1), [{ close: 1 }])
    later(800, sixth)
  }

  function sixth() {
    check("one that takes longer gets its bar", notes().slice(2), [{ replaces: 0, summary: "Receiving from “Zoë's iPhone”",
      body: "IMG_0001.HEIC", hints: { urgency: "2", "nova-glyph": "\u{F0003}", value: "25" } }])
    airdrop.told(receiving(522234))
    airdrop.told(receiving(540000))
    later(400, function () {
      check("which moves, in its place, and only as often as it changes", notes().slice(3).map(note => [note.replaces, note.hints.value]), [[2, "50"]])
      airdrop.told(received("/home/zoe/Downloads/IMG_0001.HEIC"))
      later(600, seventh)
    })
  }

  function seventh() {
    const made = called().filter(line => line.startsWith("vipsthumbnail"))
    const copy = made.length === 1 ? made[0].replace(/^.* -o (.*)\[Q=85\]$/, "$1") : ""
    check("a smaller copy of the photo is made, with untrusted loaders blocked, under a name of its own in the runtime folder",
      [made.length, made.length === 1 && made[0].startsWith("vipsthumbnail VIPS_BLOCK_UNTRUSTED=1 /home/zoe/Downloads/IMG_0001.HEIC --size 256x256 -o "),
        copy.startsWith(pictures + "/") && /^\d+\.jpg$/.test(copy.slice(pictures.length + 1))], [1, true, true])
    check("and what came in takes the transfer's place, with that copy for its picture, opening the photo at a click", notes().slice(4), [{ replaces: 2,
      summary: "AirDrop from “Zoë's iPhone”", body: "Saved IMG_0001.HEIC in Downloads",
      hints: { urgency: "1", "nova-glyph": "\u{F0003}", "image-path": copy, "nova-exec-argv": '["xdg-open","/home/zoe/Downloads/IMG_0001.HEIC"]' } }])
    check("it is on its own now: nothing more replaces it", airdrop.liveId, 0)
    airdrop.told('{"state":"off"}')
    check("off is off", [airdrop.opened, toggle.opened], [false, false])
    failing.setText("yes\n")
  }

  // No smaller copy can be made.
  function eighth() {
    const before = notes().length
    airdrop.told(JSON.stringify({ state: "waiting", name: "Nova", seen: true, ends: 0 }))
    airdrop.told(received("/home/zoe/Downloads/a.jpg"))
    later(500, function () {
      check("a JPEG is its own picture then", lastNote().hints["image-path"], "/home/zoe/Downloads/a.jpg")
      airdrop.told(received("/home/zoe/Downloads/b.heic"))
      later(500, function () {
        check("a HEIC has none: the AirDrop glyph rather than a broken picture", [lastNote().hints["image-path"], lastNote().hints["nova-glyph"]], [undefined, "\u{F0003}"])
        airdrop.told('{"state":"failed","why":"The transfer from Zoë\'s iPhone stopped before it was complete. Nothing was kept."}')
        airdrop.told(JSON.stringify({ state: "links", sender: "Zoë's iPhone", links: ["https://example.org/"] }))
        later(600, function () {
          check("a failure, and a link, each a notification of its own, in order", notes().slice(before + 2).map(note => [note.replaces, note.summary, note.body, note.hints["nova-exec-argv"]]), [
            [0, "AirDrop didn’t finish", "The transfer from Zoë's iPhone stopped before it was complete. Nothing was kept.", undefined],
            [0, "AirDrop from “Zoë's iPhone”", "https://example.org/", '["nova-launch-browser","https://example.org/"]']])
          // A failure while a photo's copy is still being made comes after it.
          airdrop.told(received("/home/zoe/Downloads/slow.jpg"))
          airdrop.told('{"state":"failed","why":"Later."}')
          later(1600, function () {
            check("what came in and what failed after it, in the order they happened", notes().slice(-2).map(note => note.body), ["Saved slow.jpg in Downloads", "Later."])
            airdrop.told(asked)
            later(400, ninth)
          })
        })
      })
    })
  }

  function ninth() {
    const offered = lastNote()
    // Its id: the stub's server counts every new one.
    const id = notes().filter(note => note.replaces === 0).length
    airdrop.told('{"state":"declined","sender":"Zoë\'s iPhone"}')
    later(400, function () {
      check("an offer declined, or left unanswered until the daemon said no, is taken away", [offered.summary, lastNote()], [offerSummary, { close: id }])
      airdrop.told('{"state":"off"}')
      refuses.setText("The Wi-Fi is switched off. Switch it on and try again.\n")
    })
  }

  // Switched on from the menu, and refused.
  function tenth() {
    const before = asks().length
    toggle.open("")
    check("on from the menu: on its way at once", [airdrop.starting, toggle.opened], [true, true])
    later(800, function () {
      check("it was the command that was asked", asks().slice(before), ["nova-airdrop on"])
      check("a start that fails says why, in the command's own words", [lastNote().summary, lastNote().body, airdrop.opened],
        ["AirDrop couldn’t start", "The Wi-Fi is switched off. Switch it on and try again.", false])
      eleventh()
    })
  }

  function eleventh() {
    const before = asks().length
    airdrop.shell = fakeShell
    // The iPhone's sheet shows AirDrop: on, to stay on after a transfer. This start is refused too.
    airdrop.bell = { state: "listening", phones: 1, near: true, learning: 0 }
    check("the doorbell rings for the sheet", airdrop.doorbell, "on")
    later(800, function () {
      check("asked for with --stay", asks().slice(before), ["nova-airdrop on --stay"])
      check("a start that failed leaves that sheet spent: no second try while it is open", [airdrop.opened, airdrop.rung, airdrop.spent, airdrop.doorbell], [false, false, true, ""])
      airdrop.bell = { state: "listening", phones: 1, near: false, learning: 0 }
      check("the sheet closed, the next one may ring again", airdrop.spent, false)
      twelfth()
    })
  }

  function twelfth() {
    const before = asks().length
    // Up for the sheet (as the watch would say), an offer; the sheet closes meanwhile.
    airdrop.rung = true
    airdrop.told(JSON.stringify({ state: "waiting", name: "Nova", seen: true, ends: 0 }))
    airdrop.bell = { state: "listening", phones: 1, near: true, learning: 0 }
    airdrop.told(asked)
    airdrop.bell = { state: "listening", phones: 1, near: false, learning: 0 }
    check("the sheet closing does not end an offer", airdrop.doorbell, "")
    airdrop.told('{"state":"declined","sender":"Zoë\'s iPhone"}')
    check("once it is over, it does", airdrop.doorbell, "off")
    later(50, function () {
      airdrop.told('{"state":"off"}')
      check("and then it is off, nobody's", [airdrop.opened, airdrop.rung, airdrop.spent], [false, false, false])
      // Locked while on for the sheet: off; unlocked with the sheet still open: not again.
      airdrop.rung = true
      airdrop.told(JSON.stringify({ state: "waiting", name: "Nova", seen: false, ends: 0 }))
      airdrop.bell = { state: "listening", phones: 1, near: true, learning: 0 }
      test.lock.locked = true
      check("locked: off", airdrop.doorbell, "off")
      later(50, function () {
        airdrop.told('{"state":"off"}')
        test.lock.locked = false
        later(50, function () {
          check("unlocked with the same sheet open: it has had its AirDrop", [airdrop.spent, airdrop.doorbell, airdrop.starting], [true, "", false])
          later(400, function () {
            check("off was asked for twice, for the closed sheet and the lock, and nothing else", asks().slice(before), ["nova-airdrop off", "nova-airdrop off"])
            thirteenth()
          })
        })
      })
    })
  }

  function thirteenth() {
    const before = asks().length
    // The sheet closes while AirDrop is still starting for it: no off until the start is over.
    airdrop.bell = { state: "listening", phones: 1, near: false, learning: 0 }
    airdrop.rung = true
    airdrop.starting = true
    check("starting for a sheet that has closed: the doorbell says off", airdrop.doorbell, "off")
    later(100, function () {
      check("but nothing is asked while the start is on its way", asks().length, before)
      airdrop.told(JSON.stringify({ state: "waiting", name: "Nova", seen: false, ends: 0 }))
      later(100, function () {
        check("once it is up, it is switched off", asks().slice(before), ["nova-airdrop off"])
        toggle.close()
        later(100, function () {
          check("and the menu's toggle switches it off as well", asks().slice(before + 1), ["nova-airdrop off"])
          finish()
        })
      })
    })
  }
}
