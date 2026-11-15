import QtQuick
import Quickshell
import Quickshell.Io
import "AirDropModel.js" as Model

// AirDrop, in the background, said in notifications as on a Mac: an
// iPhone's offer, with Decline and Accept; a transfer that takes a moment,
// with its bar; what came in, with its picture, which a click opens; and a
// failure, in a sentence. Nothing else: while AirDrop is on, the Wi-Fi is
// off the network, and the bar's Wi-Fi icon is AirDrop's meanwhile (the
// network widget reads `opened`).
//
// The work is nova-airdropd's (src/airdrop). `nova airdrop watch` tells this
// each change as a line of JSON, for as long as the shell runs; on, off,
// accept and decline are that command's too. The menu's AirDrop row toggles
// it (through AirDropToggle.qml), and the airdrop IPC target does the same
// from a key.
//
// AirDrop's doorbell, where it is switched on (Settings → AirDrop), is
// Bluetooth listening for the user's iPhone: `nova airdrop bell watch` says
// when its share sheet shows AirDrop and when it closes, and this switches
// AirDrop on and off by that, while the computer is unlocked
// (Model.doorbell).
Item {
  id: airdrop

  // Set by the shell.
  property var shell: null

  // What the daemon last said.
  property var said: ({ state: "off" })
  // `nova airdrop on` is at work, or done and the watch not yet saying so.
  property bool starting: false
  // Stop was asked for, and the off that ends it has not come yet.
  property bool stopping: false
  // AirDrop is on, or on its way: what the menu's toggle and the bar go by.
  readonly property bool opened: starting || said.state !== "off"

  // What the doorbell last said; `near` while the iPhone it knows shows AirDrop.
  property var bell: ({ state: "off" })
  readonly property bool near: bell.near === true
  // This AirDrop was switched on for the iPhone's share sheet.
  property bool rung: false
  // That sheet has had its AirDrop: none again until it closes.
  property bool spent: false
  readonly property var lockService: shell ? shell.serviceFor("nova.lock") : null
  readonly property bool locked: !!lockService && lockService.locked
  readonly property string doorbell: Model.doorbell({ near: near, locked: locked, on: opened, rung: rung, spent: spent, state: said.state })

  readonly property string command: "nova-airdrop"
  readonly property string glyph: "󰀃"

  // Acted on once what it says has settled: switching changes what it says.
  // Looked at again when a start or a stop is over, which may change what
  // can be done about it.
  onDoorbellChanged: Qt.callLater(ring)
  onStartingChanged: Qt.callLater(ring)
  onStoppingChanged: Qt.callLater(ring)
  function ring() {
    if (doorbell === "on") {
      rung = true
      turnOn()
    }
    // Not while it is starting: an off then can come before the on and be
    // lost, and AirDrop would stay on with the sheet closed. Once the start
    // is over, this is looked at again.
    else if (doorbell === "off" && !stopping && !starting) turnOff()
  }
  onOpenedChanged: if (!opened) {
    if (near) spent = true
    rung = false
  }
  onNearChanged: if (!near) spent = false

  function turnOn() {
    if (opened) return
    starter.code = -1
    starter.words = null
    starting = true
    // For the iPhone's share sheet it stays on after a transfer: it is the sheet's closing that ends it.
    starter.command = rung ? [command, "on", "--stay"] : [command, "on"]
    starter.running = true
  }

  function turnOff() {
    if (!opened) return
    stopping = true
    Quickshell.execDetached([command, "off"])
  }

  // A line of the watch.
  function told(line) {
    var next = Model.parse(line)
    if (!next) return
    said = next
    if (next.state !== "off") starting = false
    if (next.state !== "receiving") {
      slow.stop()
      slow.shown = false
    }
    switch (next.state) {
    case "asked":
      live = Model.offer(next, command)
      break
    case "receiving":
      if (!slow.shown && !slow.running) slow.start()
      // A photo is in before a bar would be any use: none for the first moment.
      live = slow.shown ? Model.receiving(next) : null
      break
    case "received":
      live = null
      arrived(Model.arrival(next))
      break
    case "links":
      live = null
      tell(Model.arrival(next))
      break
    case "failed":
      live = null
      tell(Model.failure(next))
      break
    case "off":
      live = null
      stopping = false
      break
    default:
      // Waiting, or an offer declined (by the user, or by the daemon for
      // want of an answer): nothing to show.
      live = null
    }
  }

  // `nova airdrop on` is done when it has ended and its last words are in.
  function started() {
    if (starter.code < 0 || starter.words === null) return
    var code = starter.code
    var why = String(starter.words).trim().split("\n").slice(0, 2).join(" ").slice(0, 240)
    starter.code = -1
    starter.words = null
    if (!starting) return
    if (stopping) {
      // Stopped on its way: a start that was cut short is no failure to
      // show, and one the stop came too early for is stopped now. No line
      // of the watch may ever say off to end the stopping.
      stopping = false
      if (code !== 0) starting = false
      else {
        turnOff()
        unheard.restart()
      }
      return
    }
    if (code !== 0) {
      starting = false
      tell(Model.refusal(why))
    }
    // Up, and the watch says so in a moment; a watch that says nothing leaves nothing on.
    else if (said.state === "off") unheard.restart()
  }

  Timer {
    id: unheard
    interval: 4000
    onTriggered: if (airdrop.said.state === "off") airdrop.starting = false
  }

  // A transfer gets its bar once it has taken this long.
  Timer {
    id: slow
    property bool shown: false
    interval: 800
    onTriggered: {
      shown = true
      if (airdrop.said.state === "receiving") airdrop.live = Model.receiving(airdrop.said)
    }
  }

  Process {
    id: starter
    property int code: -1
    property var words: null
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        starter.words = text
        airdrop.started()
      }
    }
    onExited: function (exitCode) {
      starter.code = exitCode
      airdrop.started()
    }
  }

  // ---- notifications ------------------------------------------------------

  // The notification of what is under way, an offer or a transfer: `live` is
  // what it should say, null for none. It is sent one call at a time, each
  // in place of the last under its id, and what it says changes only as
  // often as a call can go: the last word wins.
  property var live: null
  property int liveId: 0
  property string liveSent: ""
  // Notifications that stand on their own once sent, in order: what came in,
  // a failure, a start refused. The first takes the live one's place. One
  // whose photo's smaller copy is still being made is `waiting`: it, what
  // comes after it and the live one, which it takes the place of, wait.
  property var finals: []
  // The copies, in the user's runtime folder, each under a name of its own
  // (an image shown is cached by its name); the notifications keep a copy of
  // their own, and those older than ten minutes go as the next is made.
  readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string pictures: runtime + "/nova/airdrop-pictures"

  onLiveChanged: Qt.callLater(post)

  function tell(notice) {
    if (!notice) return
    finals = finals.concat([notice])
    Qt.callLater(post)
  }

  // What came in, once its picture is ready.
  function arrived(notice) {
    if (!notice) return
    if (notice.picture === "" || thumbnailer.running || runtime === "") {
      notice.picture = Model.readable(notice.picture) ? notice.picture : ""
      tell(notice)
      return
    }
    notice.waiting = true
    tell(notice)
    var copy = pictures + "/" + Date.now() + ".jpg"
    thumbnailer.notice = notice
    thumbnailer.copy = copy
    // The photo's own name stays one word: it is the sender's.
    thumbnailer.command = ["sh", "-c",
      'mkdir -p -m 700 -- "$1" && find "$1" -maxdepth 1 -name "*.jpg" -mmin +10 -delete;'
      + ' VIPS_BLOCK_UNTRUSTED=1 exec timeout 10 vipsthumbnail "$2" --size 256x256 -o "$3[Q=85]" 2>/dev/null',
      "sh", pictures, notice.picture, copy]
    thumbnailer.running = true
  }

  // A photo's smaller copy made, or not: what came in is told either way.
  Process {
    id: thumbnailer
    property var notice: null
    property string copy: ""
    onExited: function (exitCode) {
      var notice = thumbnailer.notice
      thumbnailer.notice = null
      if (!notice) return
      notice.picture = exitCode === 0 ? thumbnailer.copy : Model.readable(notice.picture) ? notice.picture : ""
      notice.waiting = false
      Qt.callLater(airdrop.post)
    }
  }

  function post() {
    if (notifier.running) return
    if (finals.length > 0) {
      if (finals[0].waiting) return
      var next = finals[0]
      finals = finals.slice(1)
      notifier.isFinal = true
      notifier.send(Model.notify(next, liveId, glyph))
      return
    }
    var want = live ? JSON.stringify(live) : ""
    if (want === liveSent) return
    liveSent = want
    if (want === "") {
      var id = liveId
      liveId = 0
      if (id > 0) {
        notifier.isFinal = false
        notifier.send(Model.closing(id))
      }
      return
    }
    notifier.isFinal = false
    notifier.send(Model.notify(live, liveId, glyph))
  }

  // One call to the notifications at a time. busctl answers Notify with the
  // id it is under.
  Process {
    id: notifier
    property bool isFinal: false
    property int code: -1
    property var output: null

    function send(argv) {
      code = -1
      output = null
      command = argv
      running = true
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        notifier.output = text
        airdrop.sent()
      }
    }
    onExited: function (exitCode) {
      notifier.code = exitCode
      airdrop.sent()
    }
  }

  function sent() {
    if (notifier.code < 0 || notifier.output === null) return
    var id = Model.answered(notifier.output)
    notifier.code = -1
    notifier.output = null
    // A final notification is on its own now; a live one is replaced next time.
    if (notifier.isFinal) {
      liveId = 0
      liveSent = ""
    } else if (id > 0) liveId = id
    Qt.callLater(post)
  }

  // ---- the watches ----------------------------------------------------------

  // The watch runs for as long as the shell does. Should it end, it is
  // started again, after longer each time: a command that is not there is
  // not asked for every few seconds for good.
  Process {
    id: watcher
    command: [airdrop.command, "watch"]
    running: true
    stdout: SplitParser {
      onRead: function (line) { airdrop.told(line) }
    }
    // What the live notification said can be neither answered nor followed
    // now; the watch says how things are when it is back.
    onExited: {
      airdrop.live = null
      again.start()
    }
  }

  Timer {
    id: again
    interval: 5000
    onTriggered: {
      interval = Math.min(interval * 4, 300000)
      watcher.running = true
    }
  }

  // The doorbell's watch, the same way. While the doorbell is off it says
  // so once and waits.
  Process {
    id: bellWatcher
    command: [airdrop.command, "bell", "watch"]
    running: true
    stdout: SplitParser {
      onRead: function (line) {
        var next = Model.parse(line)
        if (next) airdrop.bell = next
      }
    }
    onExited: {
      airdrop.bell = { state: "off" }
      bellAgain.start()
    }
  }

  Timer {
    id: bellAgain
    interval: 5000
    onTriggered: {
      interval = Math.min(interval * 4, 300000)
      bellWatcher.running = true
    }
  }

  IpcHandler {
    target: "airdrop"
    function on(): string { airdrop.turnOn(); return "ok" }
    function off(): string { airdrop.turnOff(); return "ok" }
    function toggle(): string {
      if (airdrop.opened) airdrop.turnOff()
      else airdrop.turnOn()
      return "ok"
    }
    function state(): string { return airdrop.starting && airdrop.said.state === "off" ? "starting" : airdrop.said.state }
  }
}
