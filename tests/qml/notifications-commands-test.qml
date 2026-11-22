// platform: wayland
// stub: bin/nova-x record
// stub: bin/nova-hyprland-focus-app record
// stub: bin/busctl busctl
// stub: bin/nova-notification-send installed
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/notifications" as Notifications
import "plugins/notifications/NotificationLogic.js" as Notes

// What a toast runs comes only from the file its sender left in Nova's
// runtime folder, which the nova-command hint names; an argv in a hint, any
// sender's, runs nothing and shows no button, and a name can reach nothing
// outside the folder. The files are the installed nova-notification-send's
// (busctl a stub that notes its call), and each notification is handed to
// the service as its server would, a stand-in with the same properties. No
// bus.
ShellRoot {
  id: test

  property QtObject fakeShell: QtObject {
    property var shellConfig: ({})
    function serviceFor(id) { return null }
  }
  property var service: null
  property Item stage: Item {}
  readonly property string folder: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/notifications/"
  property var names: ({})

  Component {
    id: maker
    Notifications.Service {}
  }

  // A notification as Quickshell's server hands it over.
  Component {
    id: noteMaker
    QtObject {
      property int id: 0
      property bool tracked: false
      property string appName: "nova-action"
      property string appIcon: ""
      property string summary: "Head"
      property string body: ""
      property string image: ""
      property int urgency: 1
      property real expireTimeout: -1
      property var hints: ({})
      property var actions: []
      property int gone: 0
      signal closed(int reason)
      function expire() { gone++ }
      function dismiss() { gone++ }
    }
  }

  property int nextId: 1
  function arrive(hints, more) {
    const note = noteMaker.createObject(stage, Object.assign({ id: nextId++, hints: hints }, more || {}))
    service.arrive(note)
    return note
  }

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  FileView { id: calls; path: Quickshell.env("HOME") + "/stub-calls"; blockAllReads: true; printErrors: false }
  function called() {
    calls.reload()
    return String(calls.text() || "").split("\n").filter(line => line !== "")
  }
  function ran(words) {
    return called().filter(line => line === "nova-x " + words).length
  }

  // Whether a file of commands is there: each says something.
  FileView { id: probe; blockAllReads: true; printErrors: false }
  function exists(path) {
    probe.path = path
    probe.reload()
    return String(probe.text() || "") !== ""
  }

  Timer {
    id: wait
    property var next: null
    onTriggered: next()
  }
  function later(ms, next) {
    wait.interval = ms
    wait.next = next
    wait.restart()
  }

  // The senders: an offer with a button and a click's command, a toast with
  // a click's command, one more for do-not-disturb, a second offer with a
  // button, and a file of commands beside the folder, which no name may reach.
  Process {
    id: senders
    command: ["sh", "-c", 'nova-notification-send -u critical --buttons \'[{"says":"Open","argv":["nova-x","pressed"],"main":true}]\' -- Offer b --exec nova-x offer-clicked'
      + ' && nova-notification-send Saved --exec nova-x opened && nova-notification-send Quiet'
      + ' && nova-notification-send -u critical --buttons \'[{"says":"Pair","argv":["nova-x","paired"],"main":true}]\' -- Pair b'
      + ' && umask 077 && printf %s \'{"argv":["nova-x","outside"]}\' >"$XDG_RUNTIME_DIR/nova/secret"']
    onExited: code => test.sent(code)
  }

  // The names in busctl's calls, in order.
  function sent(code) {
    const said = called().filter(line => line.startsWith("busctl\t")).map(line => {
      const w = line.split("\t")
      return w[w.indexOf("nova-command") + 2]
    })
    check(code === 0 && said.length === 4 && said.every(name => /^[0-9a-f]{32}$/.test(name)), "the senders' calls each name a file")
    names = { offer: said[0], saved: said[1], quiet: said[2], pair: said[3] }
    first()
  }

  function first() {
    // Inline commands, in the old hints and in the new one, from anyone.
    arrive({ "nova-exec-argv": "[\"nova-x\",\"inline\"]", "nova-buttons": "[{\"says\":\"Run\",\"argv\":[\"nova-x\",\"inline-button\"],\"main\":true}]" })
    arrive({ "nova-command": "[\"nova-x\",\"inline\"]" })
    arrive({ "nova-command": "../secret" })
    arrive({ "nova-command": "../../" + Quickshell.env("XDG_RUNTIME_DIR").replace(/^\//, "") + "/nova/secret" })
    later(200, second)
  }

  function second() {
    var shown = []
    for (var i = 0; i < service.toasts.count; i++) shown.push(service.toasts.get(i))
    check(shown.length === 4 && shown.every(row => row.buttons === "" && row.execArgv === ""), "an argv in a hint, or a name that is none, shows no button and has no command")
    service.press(0, 0)
    while (service.toasts.count > 0) service.invoke(0)
    later(300, third)
  }

  property var offer: null
  property string offerStem: ""
  function third() {
    check(ran("inline") === 0 && ran("inline-button") === 0 && ran("outside") === 0, "and runs nothing, pressed or clicked")
    offer = arrive({ "nova-command": names.offer }, { urgency: 2 })
    later(300, fourth)
  }

  function fourth() {
    const row = service.toasts.get(0)
    offerStem = Notes.stem(row)
    check(Notes.buttonsOf(row.buttons).length === 1 && Notes.buttonsOf(row.buttons)[0].says === "Open", "a command placed the right way: its button shows")
    check(!exists(folder + names.offer) && exists(folder + offerStem + ".json"), "its file is the toast's now, claimed")
    // The same name again, from another notification: claimed already. And
    // a name of no file, read right after the offer's.
    arrive({ "nova-command": names.offer })
    arrive({ "nova-command": "f".repeat(32) })
    later(200, fifth)
  }

  function fifth() {
    check(service.toasts.count === 3 && service.toasts.get(1).buttons === "", "a name claimed once gives another notification nothing")
    check(service.toasts.get(0).buttons === "" && service.toasts.get(0).execArgv === "", "nor does a name of no file, read after one that had")
    service.dismiss(0)
    service.dismiss(0)
    service.press(0, 0)
    later(300, sixth)
  }

  function sixth() {
    check(ran("pressed") === 1 && ran("offer-clicked") === 0, "its button runs its command, once")
    check(offer.gone === 1 && !exists(folder + offerStem + ".json"), "and the offer is gone, and its file with it")
    arrive({ "nova-command": names.saved })
    later(300, seventh)
  }

  property string savedStem: ""
  function seventh() {
    savedStem = Notes.stem(service.toasts.get(0))
    service.invoke(0)
    later(300, eighth)
  }

  function eighth() {
    check(ran("opened") === 1, "a click runs its command, once")
    check(exists(folder + savedStem + ".json"), "a toast gone to the history keeps its file, for a replay")
    const parts = savedStem.split("-")
    service.replay([
      Notes.historyRow({ id: Number(parts[1]), timestamp: Number(parts[0]), app: "Saved", summary: "Saved" }),
      Notes.historyRow({ id: 99, timestamp: 1, app: "nova-action", summary: "Old", execArgv: "[\"nova-x\",\"from-file\"]" })
    ])
    service.invoke(0)
    service.invoke(0)
    later(300, ninth)
  }

  function ninth() {
    check(ran("opened") === 2 && ran("from-file") === 0, "a toast from before runs what its kept file says, and a command written in a toast's file runs nothing")
    service.setDoNotDisturb(true)
    arrive({}, { summary: "Forged" })
    arrive({ "nova-command": names.quiet }, { summary: "Own" })
    later(300, tenth)
  }

  function tenth() {
    var shown = []
    for (var i = 0; i < service.toasts.count; i++) shown.push(service.toasts.get(i).summary)
    check(JSON.stringify(shown) === JSON.stringify(["Own"]), "do-not-disturb lets Nova's own through, not one that only calls itself nova-action")
    service.dismissAll()
    service.setDoNotDisturb(false)
    pair = arrive({ "nova-command": names.pair }, { urgency: 2, summary: "Pair" })
    later(300, eleventh)
  }

  // A Nova offer up, and then more notifications than ever show at once,
  // each naming a file that is not there, as any program may send them.
  property var pair: null
  function eleventh() {
    check(Notes.buttonsOf(service.toasts.get(0).buttons).length === 1, "an offer of Nova's shows its button")
    for (var i = 0; i < 70; i++) arrive({ "nova-command": (i + 1).toString(16).padStart(32, "0") }, { summary: "Made up " + i })
    later(300, twelfth)
  }

  function twelfth() {
    // Its sender changes it in place: it is drawn anew, its claim asked again.
    pair.summary = "Pair now"
    later(300, thirteenth)
  }

  function thirteenth() {
    const at = service.indexWhere(row => row.summary === "Pair now")
    check(at >= 0 && Notes.buttonsOf(service.toasts.get(at).buttons).length === 1,
      "seventy notifications naming files that are not there do not take a live offer's button away")
    service.press(at, 0)
    later(300, fourteenth)
  }

  function fourteenth() {
    check(ran("paired") === 1, "and the button still runs its command, once")
    service.dismissAll()
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    service = maker.createObject(stage, { shell: fakeShell })
    senders.running = true
  })
}
