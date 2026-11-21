import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DictationModel.js" as Model

// Dictation. SUPER + D (default/hypr/keys/dictation.lua) calls press and
// release here: a hold listens until the release, a tap until the next press.
// nova-dictationd (src/dictation) does the listening, on a connection of its
// socket for each dictation: it records, hears what is said while it is
// said, and answers with the words when the key is let go, which
// `nova dictation insert` (bin/dictation) pastes where the cursor is. The
// pill at the bottom of the screen is a wave, which rises with the voice
// while it listens and runs on its own while the last words are worked
// out, and a check once they are in.
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null

  // Not read-only, for tests/qml/dictation-socket-test.qml.
  property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/dictation")).replace(/^file:\/\//, ""))
  // nova-dictationd's, which systemd holds (nova-dictationd.socket) and
  // starts it on.
  readonly property string socketPath: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/dictation.sock"
  readonly property string modelSize: "669 MB"

  property string phase: "idle"
  // The phase the pill draws: the last one that was not idle, so the pill
  // fades out showing what it showed.
  property string look: "idle"
  property bool handsFree: false
  property real pressedAt: 0
  property int elapsed: 0
  // What `dictation check` last answered: ready, no-engine, "no-engine
  // other", no-model, or "no-model metered".
  property string readiness: ""
  property bool startWhenChecked: false
  property bool startHandsFree: false
  property string messageIcon: ""
  property string message: ""
  property string hint: ""
  property int progress: 0
  property bool verifying: false
  // This dictation's connection: the lines waiting for it to open, whether
  // it opened, and whether nova-dictationd has answered (words or why not).
  property var queued: []
  property bool reached: false
  property bool answered: false
  // How loud the voice is, 0 to 1, for the wave.
  property real loud: 0
  property real wave: 0
  // How far the wave swings: with the voice while listening, on its own after.
  readonly property real swing: look === "listening" ? 0.18 + 0.62 * loud : 0.45

  readonly property int barCount: 18
  readonly property int barWidth: Math.max(2, Style.space(3))
  readonly property int barGap: Math.max(2, Style.space(3))
  readonly property int rowHeight: Style.spacing.pillRowHeight
  readonly property bool shown: phase !== "idle"
  // Drawn only while it holds the bottom of the screen: a message or the
  // volume's card takes the place for its moment, and the pill is back
  // after it. Listening, working and pasting go on meanwhile.
  readonly property bool seen: shown && Bottom.holder === "dictation"
  readonly property var pipewireSource: Pipewire.defaultAudioSource
  // Not read-only, for tests/qml/dictation-socket-test.qml (no PipeWire).
  property var source: pipewireSource
  readonly property var lockService: shell ? shell.serviceFor("nova.lock") : null

  onPhaseChanged: if (phase !== "idle") look = phase
  onShownChanged: {
    if (shown) Bottom.claim("dictation", 0)
    else Bottom.release("dictation")
  }

  function press() {
    switch (Model.onPress(phase)) {
    case "start": start(false); break
    case "finish": finish(); break
    case "setup": setup(); break
    }
    return phase
  }

  function release() {
    switch (Model.onRelease(phase, handsFree, Date.now() - pressedAt)) {
    case "hands-free": handsFree = true; break
    case "finish": finish(); break
    }
    return phase
  }

  // `nova dictation toggle`, for a key of one's own: hands-free from the start.
  function toggle() {
    if (phase === "listening") finish()
    else if (Model.onPress(phase) === "start") start(true)
    return phase
  }

  function start(hands) {
    if (lockService && lockService.locked) return
    // The last dictation's connection is closing; it is gone in a moment.
    if (daemon.connected) return
    // Anything but ready is asked again: a model put in place since, or one
    // that is gone.
    if (readiness !== "ready") {
      startWhenChecked = true
      startHandsFree = hands
      check()
      return
    }
    if (!source) {
      say("󰍭", "No microphone", "")
      return
    }
    if (source.audio && source.audio.muted) {
      say("󰍭", "The microphone is muted", "")
      return
    }
    messageTimer.stop()
    doneTimer.stop()
    queued = ["start"]
    reached = false
    answered = false
    handsFree = hands
    pressedAt = Date.now()
    elapsed = 0
    loud = 0
    phase = "listening"
    // Last: a socket that cannot be reached may say so at once (closed()),
    // and that is heard only while listening.
    daemon.connected = true
  }

  // A line to nova-dictationd, once the connection is open.
  function send(line) {
    if (daemon.connected) daemon.write(line + "\n")
    else queued = queued.concat([line])
  }

  // Let go: the rest is heard, and the words come back (often at once,
  // when what was said was all heard while it was said).
  function finish() {
    if (phase !== "listening") return
    phase = "transcribing"
    send("finish")
  }

  function opened() {
    reached = true
    // Cancelled before it opened.
    if (phase !== "listening" && phase !== "transcribing") {
      daemon.connected = false
      return
    }
    var lines = queued
    queued = []
    for (var i = 0; i < lines.length; i++) daemon.write(lines[i] + "\n")
  }

  // The connection closed: after the words or a reason, or with neither.
  function closed() {
    if (answered || (phase !== "listening" && phase !== "transcribing")) return
    say("󰀦", reached ? (phase === "listening" ? "Dictation stopped" : "Could not transcribe") : "Dictation could not start", "")
    check()
  }

  function heard(line) {
    var answer = Model.answer(line)
    if (answer.type === "text") {
      answered = true
      if (phase === "listening" || phase === "transcribing") deliver(answer.text)
    } else if (answer.type === "error") {
      answered = true
      if (phase === "listening" || phase === "transcribing") failed(answer.error)
    }
  }

  function failed(error) {
    daemon.connected = false
    if (error === "no-model") {
      readiness = ""
      offer("Dictation needs a " + modelSize + " speech model", "Super+D downloads it")
    } else if (error === "no-engine") {
      readiness = ""
      say("󰀦", "Dictation is not available on this computer yet", "")
    } else if (error === "microphone") {
      say("󰍭", "The microphone stopped", "")
    } else if (error === "busy") {
      say("󰀦", "Dictation is busy", "")
    } else {
      say("󰀦", "Could not transcribe", "")
    }
  }

  // The words, tidied by nova-dictationd, pasted.
  function deliver(text) {
    if (text === "") {
      say("󰍬", "Nothing heard", "")
      return
    }
    Quickshell.execDetached([helper, "insert", text])
    phase = "done"
    doneTimer.restart()
  }

  // Esc, or the lock. While it listens, what was said is forgotten; once
  // let go, nova-dictationd finishes it all the same and keeps the words for
  // `nova dictation last`, but nothing is pasted.
  function cancel() {
    startWhenChecked = false
    messageTimer.stop()
    doneTimer.stop()
    var listening = phase === "listening"
    phase = "idle"
    handsFree = false
    queued = []
    if (listening && daemon.connected) daemon.write("cancel\n")
    daemon.connected = false
    // The part downloaded so far is kept; the next setup carries on from it.
    if (setupProc.running) setupProc.running = false
  }

  function check() {
    if (!checkProc.running) checkProc.running = true
  }

  function checked(answer) {
    readiness = answer
    if (!startWhenChecked) return
    startWhenChecked = false
    if (answer === "ready") start(startHandsFree)
    else if (answer.indexOf("no-engine") === 0) say("󰀦", "Dictation is not available on this computer yet", "")
    else if (answer.indexOf("no-model") === 0)
      offer(answer.indexOf("metered") > 0
        ? "Dictation needs a " + modelSize + " speech model, and this connection is metered"
        : "Dictation needs a " + modelSize + " speech model", "Super+D downloads it")
    else say("󰀦", "Dictation could not start", "")
  }

  // The model is downloaded only when asked, with a second press: it is big,
  // and a press by mistake should not spend a mobile data plan.
  function offer(text, hintText) {
    messageIcon = "󰇚"
    message = text
    hint = hintText
    phase = "offer"
    messageTimer.interval = 9000
    messageTimer.restart()
  }

  function setup() {
    if (setupProc.running) return
    messageTimer.stop()
    progress = 0
    verifying = false
    phase = "downloading"
    setupProc.running = true
  }

  function say(icon, text, hintText) {
    messageIcon = icon
    message = text
    hint = hintText
    phase = "message"
    messageTimer.interval = hintText === "" ? 2600 : 4000
    messageTimer.restart()
  }

  Component.onCompleted: check()

  Connections {
    target: root.lockService
    ignoreUnknownSignals: true
    // Words spoken before the lock are not pasted into it, and the
    // microphone does not listen to a locked computer.
    function onLockedChanged() {
      if (root.lockService.locked) root.cancel()
    }
  }

  Socket {
    id: daemon
    path: root.socketPath
    parser: SplitParser {
      onRead: line => root.heard(line)
    }
    onConnectedChanged: {
      if (connected) root.opened()
      else root.closed()
    }
    // It could not be reached: closed() says so, as no answer came.
    onError: if (!connected) root.closed()
  }

  PwObjectTracker { objects: root.pipewireSource ? [root.pipewireSource] : [] }

  PwNodePeakMonitor {
    id: peakMonitor
    node: root.pipewireSource
    enabled: root.phase === "listening"
  }

  Process {
    id: checkProc
    command: [root.helper, "check"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.checked(String(text).trim())
    }
  }

  Process {
    id: setupProc
    command: [root.helper, "setup", "--progress"]
    stdout: SplitParser {
      onRead: function (line) {
        var percent = Model.progress(line)
        if (percent >= 0) root.progress = percent
        else if (String(line).trim() === "checking") root.verifying = true
      }
    }
    onExited: function (exitCode) {
      if (root.phase !== "downloading") return
      root.check()
      if (exitCode === 0) root.say("󰄬", "Dictation is ready", "hold Super+D and speak")
      else root.offer("The download stopped", "Super+D tries again")
    }
  }

  Timer {
    id: messageTimer
    onTriggered: if (root.phase === "message" || root.phase === "offer") root.phase = "idle"
  }

  Timer {
    id: doneTimer
    interval: 650
    onTriggered: if (root.phase === "done") root.phase = "idle"
  }

  Timer {
    interval: 45
    repeat: true
    running: root.phase === "listening"
    onTriggered: root.loud = Model.voice(root.loud, Model.level(peakMonitor.peak))
  }

  // nova-dictationd answers a let-go in a second or two at most; one that
  // never does (stopped, say) is not waited on for ever.
  Timer {
    interval: 120000
    running: root.phase === "transcribing"
    onTriggered: {
      root.cancel()
      root.say("󰀦", "Could not transcribe", "")
    }
  }

  Timer {
    interval: 250
    repeat: true
    running: root.phase === "listening"
    onTriggered: {
      root.elapsed = Math.floor((Date.now() - root.pressedAt) / 1000)
      if (root.elapsed >= Model.maxSeconds) root.finish()
    }
  }

  NumberAnimation on wave {
    from: 0
    to: 2 * Math.PI
    duration: 1100
    loops: Animation.Infinite
    running: root.phase === "listening" || root.phase === "transcribing"
  }

  IpcHandler {
    target: "dictation"
    function press(): string { return root.press() }
    function release(): string { return root.release() }
    function toggle(): string { return root.toggle() }
    function cancel(): string { root.cancel(); return "ok" }
    function refresh(): string { root.check(); return "ok" }
    function state(): string { return root.phase }
  }

  PanelWindow {
    id: panel
    visible: root.seen || card.opacity > 0
    anchors.bottom: true
    // Room for the widest pill and its pop; the pill sizes itself inside.
    implicitWidth: Style.space(640)
    implicitHeight: card.height + card.anchors.bottomMargin + Style.space(12)
    color: "transparent"
    WlrLayershell.namespace: "nova-dictation"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Visual only: clicks go through to what is under it, and the keyboard
    // stays with the window the words are for.
    mask: Region {}

    BorderSurface {
      id: card
      readonly property int pad: Style.spacing.pillPadding
      width: card.edge.left + card.pad * 2 + row.implicitWidth + card.edge.right
      height: card.edge.top + card.pad * 2 + root.rowHeight + card.edge.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Bottom.foot
      color: Util.alpha(Commons.Color.popups.background, 0.97)
      frame: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.seen ? 1 : 0
      scale: root.seen ? 1 : 0.88
      transform: Translate {
        y: root.seen ? 0 : Style.space(10)
        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }

      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
      Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

      // The content keeps its own width while the pill grows or shrinks to
      // it, so it is clipped rather than spilled during the change.
      Item {
        anchors.fill: parent
        anchors.margins: card.pad
        clip: true

        Row {
          id: row
          anchors.centerIn: parent
          height: root.rowHeight
          spacing: Style.space(9)

          // A wave running through the bars: as tall as the voice while it
          // listens, and on its own while the last words are worked out.
          Item {
            visible: root.look === "listening" || root.look === "transcribing"
            width: root.barCount * root.barWidth + (root.barCount - 1) * root.barGap
            height: root.rowHeight

            Repeater {
              model: root.barCount

              Rectangle {
                id: bar
                required property int index
                readonly property real value: 0.15 + root.swing * (0.5 + 0.5 * Math.sin(root.wave - bar.index * 0.55))
                x: bar.index * (root.barWidth + root.barGap)
                anchors.verticalCenter: parent.verticalCenter
                width: root.barWidth
                height: Math.max(root.barWidth, Math.round(bar.value * root.rowHeight))
                radius: root.barWidth / 2
                color: Commons.Color.accent

                Behavior on height { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
              }
            }
          }

          // Square, the pill at its smallest.
          Text {
            visible: root.look === "done"
            width: root.rowHeight
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "󰄬"
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            color: Commons.Color.accent
          }

          Text {
            visible: root.look === "message" || root.look === "offer" || root.look === "downloading"
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.look === "downloading" ? "󰇚" : root.messageIcon
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            color: Commons.Color.accent
          }

          Text {
            visible: root.look === "message" || root.look === "offer" || root.look === "downloading"
            width: Math.min(implicitWidth, Style.space(420))
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.look !== "downloading" ? root.message
              : (root.verifying ? "Checking the speech model" : "Downloading the speech model")
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            color: Commons.Color.popups.text
            elide: Text.ElideRight
            maximumLineCount: 1
          }

          Rectangle {
            visible: root.look === "downloading" && !root.verifying
            width: Style.space(110)
            height: Math.max(Style.space(4), 2)
            anchors.verticalCenter: parent.verticalCenter
            color: Util.alpha(Commons.Color.popups.text, 0.25)

            Rectangle {
              width: parent.width * root.progress / 100
              height: parent.height
              color: Commons.Color.accent
              Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
            }
          }

          Text {
            visible: (root.look === "message" || root.look === "offer") && root.hint !== ""
              || root.look === "downloading" && !root.verifying
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.look === "downloading" ? root.progress + "%" : root.hint
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            color: Util.alpha(Commons.Color.popups.text, 0.6)
          }
        }
      }
    }
  }
}
