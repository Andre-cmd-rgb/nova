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

// What the notifications keep, through their real files (files.sh): a toast
// gone is replayed from the history, and one on screen comes back when the
// shell restarts. And what they do not: a command belongs to the
// notification that brought it, so words put over a Nova toast by another
// sender (replaces_id), in place or as a new notification in the same
// millisecond, run nothing, live, from the history or after a restart, and
// the file is gone. The commands are the installed nova-notification-send's
// (busctl a stub that notes its call); each notification is handed to the
// service as its server would, a stand-in with the same properties; the
// restart is the service made anew over the same folders. No bus.
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

  Component {
    id: noteMaker
    QtObject {
      property int id: 0
      property bool tracked: false
      property string appName: "Mail"
      property string appIcon: ""
      property string summary: "Head"
      property string body: ""
      property string image: ""
      property int urgency: 1
      property real expireTimeout: -1
      property var hints: ({})
      property var actions: []
      signal closed(int reason)
      function expire() { closed(1) }
      function dismiss() { closed(2) }
    }
  }

  property int nextId: 1
  function arrive(summary, more, at) {
    const note = noteMaker.createObject(stage, Object.assign({ id: nextId++, summary: summary }, more || {}))
    service.arrive(note, at)
    return note
  }
  // A Nova toast whose file of commands is `name`'s.
  function own(summary, name, at) {
    return arrive(summary, { appName: "nova-action", hints: { "nova-command": name } }, at)
  }

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  function shown() {
    var all = []
    for (var i = 0; i < service.toasts.count; i++) all.push(service.toasts.get(i).summary)
    return JSON.stringify(all)
  }
  function at(summary) {
    return service.indexWhere(row => row.summary === summary)
  }
  function stemOf(summary) {
    return Notes.stem(service.toasts.get(at(summary)))
  }

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

  // The shell restarted: the service gone, and a new one over its files.
  function restart(next) {
    service.destroy()
    later(200, () => {
      service = maker.createObject(stage, { shell: fakeShell })
      later(600, next)
    })
  }

  // ------------------------------------------------ what is kept

  function first() {
    arrive("Gone")
    arrive("Kept")
    later(300, second)
  }

  function second() {
    check(shown() === JSON.stringify(["Kept", "Gone"]), "two toasts with no bar show")
    // "Gone" to the history; "Kept" stays on screen.
    service.dismiss(1)
    later(300, () => restart(third))
  }

  function third() {
    check(shown() === JSON.stringify(["Kept"]), "a toast with no bar on screen comes back after a restart")
    service.showHistory()
    later(400, fourth)
  }

  function fourth() {
    check(shown() === JSON.stringify(["Kept", "Gone"]), "and the history replays the toasts gone, and those on screen")
    service.dismissAll()
    senders.running = true
  }

  // ------------------------------------------- what is not: a command's owner

  // Five Nova toasts' files, each with a click's command of its own.
  Process {
    id: senders
    command: ["sh", "-c", "for which in a b c d e; do nova-notification-send Saved --exec nova-x opened-$which || exit 1; done"]
    onExited: code => test.sent(code)
  }

  function sent(code) {
    const said = called().filter(line => line.startsWith("busctl\t")).map(line => {
      const w = line.split("\t")
      return w[w.indexOf("nova-command") + 2]
    })
    check(code === 0 && said.length === 5 && said.every(name => /^[0-9a-f]{32}$/.test(name)), "the senders' calls each name a file")
    names = { a: said[0], b: said[1], c: said[2], d: said[3], e: said[4] }
    fifth()
  }

  property var noteA: null
  property var noteD: null
  property string stemA: ""
  property string stemB: ""
  property string stemD: ""
  property real sameTime: 0
  property var noteB: null

  function fifth() {
    noteA = own("Saved A", names.a)
    noteD = own("Saved D", names.d)
    sameTime = Date.now()
    noteB = own("Saved B", names.b, sameTime)
    later(300, sixth)
  }

  function sixth() {
    stemA = stemOf("Saved A")
    stemD = stemOf("Saved D")
    check(service.toasts.get(at("Saved A")).execArgv !== "" && exists(folder + stemA + ".json"), "a Nova toast has its command, in its own file")
    // Another sender's words over it, in place, with no command of theirs.
    noteA.summary = "Lure A"
    noteA.hints = ({})
    // Nova's own sender, updating its toast with a new file (-r).
    noteD.summary = "Updated D"
    noteD.hints = ({ "nova-command": names.e })
    later(300, seventh)
  }

  function seventh() {
    const lure = service.toasts.get(at("Lure A"))
    check(lure.execArgv === "" && lure.buttons === "", "replaced in place with no command: the live toast has none")
    check(!exists(folder + stemA + ".json"), "and its file is gone")
    check(service.toasts.get(at("Updated D")).execArgv.indexOf("opened-e") >= 0 && exists(folder + stemD + ".json"),
      "a Nova toast updated with a file of its own takes that one")
    service.invoke(at("Lure A"))
    service.invoke(at("Updated D"))
    later(300, eighth)
  }

  function eighth() {
    check(ran("opened-a") === 0, "a click on the words put over it runs nothing of Nova's")
    check(ran("opened-e") === 1 && ran("opened-d") === 0, "a click on the updated one runs its new command, once")
    // A notification under B's id in the same millisecond: a new one, under
    // the same file name, with no command.
    stemB = stemOf("Saved B")
    const replacement = noteMaker.createObject(stage, { id: noteB.id, summary: "Lure B" })
    service.arrive(replacement, sameTime)
    later(300, ninth)
  }

  function ninth() {
    check(at("Lure B") >= 0 && at("Saved B") < 0 && service.toasts.get(at("Lure B")).execArgv === ""
      && Notes.stem(service.toasts.get(at("Lure B"))) === stemB, "a replacement in the same millisecond takes the toast's place and file name, with no command")
    check(!exists(folder + stemB + ".json"), "and the file of the one it replaced is gone")
    service.invoke(at("Lure B"))
    later(300, tenth)
  }

  function tenth() {
    check(ran("opened-b") === 0, "a click on it runs nothing of Nova's")
    service.showHistory()
    later(400, eleventh)
  }

  function eleventh() {
    check(at("Lure A") >= 0 && at("Lure B") >= 0, "the history replays the words put over them")
    service.invoke(at("Lure A"))
    service.invoke(at("Lure B"))
    later(300, twelfth)
  }

  property var noteC: null
  property string stemC: ""
  function twelfth() {
    check(ran("opened-a") === 0 && ran("opened-b") === 0, "a click on them from the history runs nothing of Nova's")
    service.dismissAll()
    noteC = own("Saved C", names.c)
    later(300, () => {
      stemC = stemOf("Saved C")
      noteC.summary = "Lure C"
      noteC.hints = ({})
      later(300, () => restart(thirteenth))
    })
  }

  function thirteenth() {
    check(at("Lure C") >= 0 && !exists(folder + stemC + ".json"), "after a restart the words put over a toast come back, its file does not")
    service.invoke(at("Lure C"))
    later(300, last)
  }

  function last() {
    check(ran("opened-c") === 0, "and a click on them runs nothing of Nova's")
    service.dismissAll()
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    service = maker.createObject(stage, { shell: fakeShell })
    later(300, first)
  })
}
