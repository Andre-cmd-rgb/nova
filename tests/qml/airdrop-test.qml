// platform: wayland
// stub: bin/nova-airdrop nova-airdrop
// stub: bin/nova-notification-send record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/airdrop"
import "plugins/airdrop/AirDropModel.js" as Model

// AirDrop's card: what it makes of each line of `nova airdrop watch`, and
// what it asks of the command in return. nova-airdrop is a stub: its watch
// says what the test wrote for it, and its other calls are noted, as are
// nova-notification-send's. No radio, no daemon.
ShellRoot {
  id: test

  property var card: null
  property Item stage: Item {}

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

  FileView {
    id: says
    path: Quickshell.env("HOME") + "/airdrop-says"
    printErrors: false
    onSaved: test.second()
  }

  FileView {
    id: refuses
    path: Quickshell.env("HOME") + "/airdrop-refuses"
    printErrors: false
    onSaved: test.sixth()
  }

  FileView {
    id: calls
    path: Quickshell.env("HOME") + "/stub-calls"
    blockLoading: true
    printErrors: false
  }

  function called() {
    calls.reload()
    calls.waitForJob()
    return calls.text().trim().split("\n")
  }

  Component {
    id: made
    AirDrop {}
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

  // The model, with no card.
  function first() {
    check("a line that is no state is nothing", [Model.parse("not json"), Model.parse("[1]"), Model.parse('{"state":7}'), Model.parse("null")],
      [null, null, null, null])
    check("sizes as people say them", [Model.size(512), Model.size(20480), Model.size(1044468), Model.size(3200000000), Model.size("x")],
      ["512 bytes", "20 kB", "1.0 MB", "3.20 GB", "0 bytes"])
    check("one file by its name, more by their number, a link as a link",
      [Model.offered(JSON.parse(asked)), Model.offered({ files: [{ name: "a" }, { name: "b" }], bytes: 2500000 }), Model.offered({ links: ["x"] }), Model.offered({})],
      ["IMG_0001.HEIC (1.0 MB)", "2 files (2.5 MB)", "a link", "0 links"])
    check("the countdown", [Model.clock(119.2), Model.clock(60), Model.clock(0.4), Model.clock(-3)], ["2:00", "1:00", "0:01", "0:00"])

    check("nothing is shown for no state, off, or one the card does not know",
      [Model.face(null, 0), Model.face({ state: "off" }, 0), Model.face({ state: "dancing" }, 0)], [null, null, null])
    const waiting = Model.face({ state: "waiting", name: "Nova", seen: false, ends: 1120 }, 1000)
    check("waiting says where to send, that the Wi-Fi is off and for how long at most, and offers to stop",
      [waiting.title, waiting.words, waiting.note, waiting.answers.map(a => a.does), waiting.stays],
      ["AirDrop", "Send from an iPhone to Nova", "Wi-Fi is off meanwhile. Ends in 2:00.", ["stop"], 0])
    check("once an iPhone has listed the computer, it says so",
      Model.face({ state: "waiting", name: "Nova", seen: true, ends: 0 }, 1000).words, "An iPhone has Nova in its AirDrop list")
    check("with no time to give up at, none is named",
      Model.face({ state: "waiting", name: "Nova", seen: true, ends: 0 }, 1000).note, "Wi-Fi is off meanwhile.")
    const question = Model.face(JSON.parse(asked), 0)
    check("an offer is a question with two answers, yes the main one",
      [question.title, question.words, question.answers], ["Zoë's iPhone wants to send", "IMG_0001.HEIC (1.0 MB)",
        [{ does: "decline", says: "Decline", main: false }, { does: "accept", says: "Accept", main: true }]])
    check("a sender with no name is somebody", Model.face({ state: "asked", files: [], links: ["x"] }, 0).title, "Somebody wants to send")
    const coming = Model.face({ state: "receiving", sender: "Zoë's iPhone", files: [{ name: "IMG_0001.HEIC", bytes: 1044468 }], received: 522234, bytes: 1044468 }, 0)
    check("a transfer shows how much is in", [coming.title, coming.note, coming.share], ["Receiving from Zoë's iPhone", "522 kB of 1.0 MB", 0.5])
    check("more in than was said is all of it, and a size never said is no bar's worth",
      [Model.face({ state: "receiving", received: 9, bytes: 4 }, 0).share, Model.face({ state: "receiving", received: 9 }, 0).share], [1, 0])
    check("the ends stay a moment: a no, a failure, a start that failed, a giving up",
      ["declined", "failed", "error", "ended"].map(state => Model.face({ state: state, why: "x" }, 0).stays > 0), [true, true, true, true])
    check("a failure says why, a start that failed too", [Model.face({ state: "failed", why: "The transfer stopped." }, 0).words,
      Model.face({ state: "error", why: "The Wi-Fi is switched off." }, 0).words], ["The transfer stopped.", "The Wi-Fi is switched off."])

    check("a daemon that was waiting gave up when its time had run out, not before",
      [Model.gaveUp({ state: "waiting", ends: 1000 }, 999), Model.gaveUp({ state: "waiting", ends: 1000 }, 900),
        Model.gaveUp({ state: "waiting", ends: 0 }, 999), Model.gaveUp({ state: "asked" }, 999)], [true, false, false, false])

    const photo = Model.arrival({ state: "received", sender: "Zoë's iPhone", paths: ["/home/zoe/Downloads/IMG_0001.HEIC"] })
    check("one file in: its name, its folder, itself as the picture, and it opens at a click", photo,
      { headline: "AirDrop from Zoë's iPhone", words: "Saved IMG_0001.HEIC in Downloads. Click to open.",
        picture: "/home/zoe/Downloads/IMG_0001.HEIC", opens: "/home/zoe/Downloads/IMG_0001.HEIC", browser: false })
    const several = Model.arrival({ state: "received", sender: "", paths: ["/home/zoe/Downloads/a.pdf", "/home/zoe/Downloads/notes"] })
    check("several in: their number, and the folder opens", [several.headline, several.words, several.picture, several.opens],
      ["AirDrop from Somebody", "Saved 2 things in Downloads. Click to see them.", "", "/home/zoe/Downloads"])
    check("a file that is no picture has none", Model.arrival({ state: "received", paths: ["/d/a.pdf"] }).picture, "")
    // A name is never the first thing in a word of the notification's, where an option could be read from it.
    const sly = Model.arrival({ state: "received", sender: "--exec", paths: ["/home/zoe/Downloads/--image=x.png"] })
    check("names made to look like options stay inside the card's own words", [sly.headline, sly.words.slice(0, 6)], ["AirDrop from --exec", "Saved "])
    check("a path that is not one, or none at all, is no arrival",
      [Model.arrival({ state: "received", paths: ["relative.png"] }), Model.arrival({ state: "received" })], [null, null])
    const link = Model.arrival({ state: "links", sender: "Zoë's iPhone", links: ["https://example.org/a?b=c"] })
    check("a web address opens in the browser", [link.words, link.opens, link.browser], ["Link: https://example.org/a?b=c", "https://example.org/a?b=c", true])
    check("anything else sent as a link is shown and opens nothing",
      [Model.arrival({ state: "links", links: ["file:///etc/passwd"] }).opens, Model.arrival({ state: "links", links: ["https://a b"] }).opens,
        Model.arrival({ state: "links", links: [] })], ["", "", null])

    says.setText(JSON.stringify({ state: "waiting", name: "Nova", seen: false, ends: 0 }) + "\n")
  }

  // The card: the watch is already saying AirDrop is on when the shell starts.
  function second() {
    card = made.createObject(stage)
    check("before the watch has said anything, there is no card", [card.shown, card.face, card.opened], [null, null, false])
    later(1000, third)
  }

  function third() {
    check("the watch's line puts the card up", [card.shown && card.shown.state, card.face && card.face.words, card.opened],
      ["waiting", "Send from an iPhone to Nova", true])
    card.told("not json")
    card.told('{"state":7}')
    check("a line that is no state changes nothing", card.shown.state, "waiting")
    card.told(asked)
    check("an offer is on the card", [card.look.title, card.look.answers.length], ["Zoë's iPhone wants to send", 2])
    card.answer("accept")
    card.told(JSON.stringify({ state: "receiving", sender: "Zoë's iPhone", files: [{ name: "IMG_0001.HEIC", bytes: 1044468 }], received: 261117, bytes: 1044468 }))
    check("then the transfer", [card.look.title, card.look.share], ["Receiving from Zoë's iPhone", 0.25])
    // An answer when nothing is asked goes nowhere.
    card.answer("decline")
    card.told(JSON.stringify({ state: "received", sender: "Zoë's iPhone", paths: ["/home/zoe/Downloads/IMG_0001.HEIC"], bytes: 1044468, seconds: 2.2 }))
    check("what came in takes the card away, AirDrop still on for its last moment", [card.shown, card.face, card.opened], [null, null, true])
    card.told('{"state":"off"}')
    check("and off is off", [card.shown, card.opened], [null, false])
    later(600, fourth)
  }

  function fourth() {
    check("yes went to the command with the question's id, and the arrival to the notifications with a click that opens it", called(), [
      "nova-airdrop accept 7-1",
      "nova-notification-send -u normal -g 󰀃 --image /home/zoe/Downloads/IMG_0001.HEIC AirDrop from Zoë's iPhone Saved IMG_0001.HEIC in Downloads. Click to open. --exec xdg-open /home/zoe/Downloads/IMG_0001.HEIC"
    ])
    check("a link's click is the browser's", card.announcement({ state: "links", sender: "Zoë's iPhone", links: ["https://example.org/"] }).slice(-3),
      ["--exec", "nova-launch-browser", "https://example.org/"])
    check("and one that is no web address has no click", card.announcement({ state: "links", links: ["javascript:alert(1)"] }).indexOf("--exec"), -1)

    // Stopped from the card: the off that follows is no giving up, whatever the clock says.
    const soon = Math.floor(Date.now() / 1000) + 1
    card.told(JSON.stringify({ state: "waiting", name: "Nova", seen: true, ends: soon }))
    card.answer("stop")
    card.told('{"state":"off"}')
    check("stopped: the card goes at once", [card.shown, card.stopping], [null, false])
    // Left alone until its time is up, it says so for a moment.
    card.told(JSON.stringify({ state: "waiting", name: "Nova", seen: false, ends: soon }))
    card.told('{"state":"off"}')
    check("given up: the card says nobody sent anything", [card.shown.state, card.look.words, card.opened], ["ended", "Off again: nobody sent anything", false])
    // A no, and a failure: each stays a moment with AirDrop already off.
    card.told(asked)
    card.told('{"state":"declined","sender":"Zoë\'s iPhone"}')
    card.told('{"state":"off"}')
    check("a no stays on the card over the off", card.shown.state, "declined")
    card.told(asked)
    card.told('{"state":"failed","why":"The transfer from Zoë\'s iPhone stopped before it was complete. Nothing was kept."}')
    card.told('{"state":"off"}')
    check("a failure too, with its reason", [card.shown.state, card.look.title, card.look.words],
      ["failed", "AirDrop did not finish", "The transfer from Zoë's iPhone stopped before it was complete. Nothing was kept."])
    card.close()
    check("closing an AirDrop that is off takes the card away", card.shown, null)
    later(400, fifth)
  }

  function fifth() {
    check("stop asked the command for off", called().slice(2), ["nova-airdrop off"])
    refuses.setText("The Wi-Fi is switched off. Switch it on and try again.\n")
  }

  // Switched on from the shell, and refused.
  function sixth() {
    card.open("")
    check("on from the shell: the card is up at once", [card.shown.state, card.look.words, card.opened], ["starting", "Getting the Wi-Fi card ready", true])
    later(800, seventh)
  }

  function seventh() {
    check("a start that fails says why, in the command's own words", [card.shown && card.shown.state, card.look.title, card.look.words, card.opened],
      ["error", "AirDrop could not start", "The Wi-Fi is switched off. Switch it on and try again.", false])
    check("and it was the command that was asked", called().slice(3), ["nova-airdrop on"])
    finish()
  }
}
