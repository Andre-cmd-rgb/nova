import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DictationModel.js" as Model

// Dictation. SUPER + D (default/hypr/bindings/dictation.lua) calls press and
// release here: a hold records until the release, a tap until the next press.
// `nova dictation` (bin/dictation) turns the recording into text on this
// computer and pastes it where the cursor is. The pill at the bottom of the
// screen shows each step: the microphone's level while it listens, a wave
// while the words are worked out, and a check once they are in.
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/dictation")).replace(/^file:\/\//, ""))
  // Memory, and private to this user: a recording never touches the disk.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/dictation"
  readonly property string modelSize: "669 MB"

  property string phase: "idle"
  // The phase the pill draws: the last one that was not idle, so the pill
  // fades out showing what it showed.
  property string look: "idle"
  property bool handsFree: false
  property real pressedAt: 0
  property int elapsed: 0
  property string recording: ""
  // What `dictation check` last answered: ready, no-engine, no-model, or
  // "no-model metered".
  property string readiness: ""
  property bool startWhenChecked: false
  property bool startHandsFree: false
  property string messageIcon: ""
  property string message: ""
  property string hint: ""
  property int progress: 0
  property bool verifying: false
  // The transcriber's text and its exit code, which arrive in either order.
  property var transcript: null
  property var transcribeCode: null
  property var levels: []
  property real wave: 0

  readonly property int barCount: 18
  readonly property int barWidth: Math.max(2, Style.space(3))
  readonly property int barGap: Math.max(2, Style.space(3))
  readonly property int rowHeight: Style.space(22)
  readonly property bool shown: phase !== "idle"
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var lockService: shell ? shell.serviceFor("nova.lock") : null

  onPhaseChanged: if (phase !== "idle") look = phase

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
    // A cancelled recording or transcription is still winding down; it is
    // gone in a moment.
    if (recordProc.running || transcribeProc.running) return
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
    recording = runtimeDir + "/" + Date.now() + ".wav"
    // pdeathsig: should the shell die mid-dictation, the microphone closes.
    recordProc.command = ["setpriv", "--pdeathsig", "TERM", helper, "record", recording]
    recordProc.running = true
    handsFree = hands
    pressedAt = Date.now()
    elapsed = 0
    levels = []
    phase = "listening"
  }

  function finish() {
    if (phase !== "listening") return
    transcript = null
    transcribeCode = null
    phase = "transcribing"
    // pw-record finishes the file's header on SIGTERM; the transcription
    // starts once it has exited.
    if (recordProc.running) recordProc.signal(15)
  }

  function transcribed() {
    if (transcript === null || transcribeCode === null || phase !== "transcribing") return
    if (transcribeCode !== 0) {
      say("󰀦", "Could not transcribe", "")
      check()
      return
    }
    var text = Model.clean(transcript)
    if (text === "") {
      say("󰍬", "Nothing heard", "")
      return
    }
    Quickshell.execDetached([helper, "insert", text])
    phase = "done"
    doneTimer.restart()
  }

  function cancel() {
    startWhenChecked = false
    messageTimer.stop()
    doneTimer.stop()
    phase = "idle"
    handsFree = false
    if (recordProc.running) recordProc.signal(15)
    if (transcribeProc.running) transcribeProc.running = false
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
    else if (answer === "no-engine") say("󰀦", "Dictation is not available on this computer yet", "")
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

  PwObjectTracker { objects: root.source ? [root.source] : [] }

  PwNodePeakMonitor {
    id: peakMonitor
    node: root.source
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
    id: recordProc
    // An exit status of 1 is how pw-record ends on SIGTERM, file and all.
    onExited: {
      var file = root.recording
      if (root.phase === "transcribing") {
        transcribeProc.command = [root.helper, "transcribe", file]
        transcribeProc.running = true
        return
      }
      Quickshell.execDetached(["rm", "-f", "--", file])
      if (root.phase === "listening") root.say("󰀦", "The microphone stopped", "")
    }
  }

  // The helper deletes the recording, read or not.
  Process {
    id: transcribeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.transcript = text
        root.transcribed()
      }
    }
    onExited: function (exitCode) {
      root.transcribeCode = exitCode
      root.transcribed()
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
    onTriggered: root.levels = Model.pushLevel(root.levels, Model.level(peakMonitor.peak), root.barCount)
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
    running: root.phase === "transcribing"
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

  TextMetrics {
    id: clockMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    text: "0:00"
  }

  PanelWindow {
    id: panel
    visible: root.shown || card.opacity > 0
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
      readonly property int pad: Style.space(10)
      width: card.borderLeft + card.pad * 2 + row.implicitWidth + card.borderRight
      height: card.borderTop + card.pad * 2 + root.rowHeight + card.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(28)
      color: Util.alpha(Commons.Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.shown ? 1 : 0
      scale: root.shown ? 1 : 0.88
      transform: Translate {
        y: root.shown ? 0 : Style.space(10)
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

          // Recording: a dot that breathes.
          Rectangle {
            visible: root.look === "listening"
            width: Style.space(8)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: Commons.Color.urgent

            SequentialAnimation on opacity {
              running: root.phase === "listening"
              loops: Animation.Infinite
              NumberAnimation { to: 0.35; duration: 650; easing.type: Easing.InOutSine }
              NumberAnimation { to: 1; duration: 650; easing.type: Easing.InOutSine }
            }
          }

          // The microphone's level, newest on the right, while listening; a
          // wave running through the same bars while the words are worked out.
          Item {
            visible: root.look === "listening" || root.look === "transcribing"
            width: root.barCount * root.barWidth + (root.barCount - 1) * root.barGap
            height: root.rowHeight

            Repeater {
              model: root.barCount

              Rectangle {
                id: bar
                required property int index
                readonly property real value: root.look === "transcribing"
                  ? 0.15 + 0.45 * (0.5 + 0.5 * Math.sin(root.wave - bar.index * 0.55))
                  : (root.levels[bar.index] || 0)
                x: bar.index * (root.barWidth + root.barGap)
                anchors.verticalCenter: parent.verticalCenter
                width: root.barWidth
                height: Math.max(root.barWidth, Math.round(bar.value * root.rowHeight))
                radius: root.barWidth / 2
                color: root.look === "transcribing" ? Commons.Color.accent : Commons.Color.popups.text

                Behavior on height { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
                Behavior on color { ColorAnimation { duration: 200 } }
              }
            }
          }

          // Hands-free has no finger on the key, so it shows the time.
          Text {
            visible: root.look === "listening" && root.handsFree
            width: Math.ceil(clockMetrics.advanceWidth)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: Model.clock(root.elapsed)
            font: clockMetrics.font
            color: Util.alpha(Commons.Color.popups.text, 0.6)
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
