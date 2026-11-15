import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "AirDropModel.js" as Model

// AirDrop's card, under the middle of the bar: up from the moment AirDrop is
// switched on until it is off again, since the Wi-Fi is off the network
// meanwhile and that should not go unseen. It says what is going on in a
// line or two, asks yes or no when an iPhone offers something, and shows the
// transfer coming in. What has come in is announced as any notification is,
// with a click to open it, and the card goes.
//
// The work is nova-airdropd's (src/airdrop). `nova airdrop watch` tells this
// each change as a line of JSON, for as long as the shell runs; on, off,
// accept and decline are that command's too. The menu's AirDrop row toggles
// this plugin, and the airdrop IPC target does the same from a key.
Item {
  id: airdrop

  // Set by the shell.
  property var shell: null

  // What the daemon last said, and what the card shows: the same while it
  // waits, asks or receives; an end stays on the card for a moment after
  // the daemon is off.
  property var said: ({ state: "off" })
  property var shown: null
  // In Unix seconds, kept going while there is a countdown to show.
  property real now: Date.now() / 1000
  // Stop was asked for: the off that follows is no giving up.
  property bool stopping: false
  readonly property var face: Model.face(shown, now)
  // The last face, for the card to keep while it goes.
  property var look: ({ title: "", words: "", note: "", share: -1, answers: [], stays: 0 })
  // `nova airdrop on` is at work.
  readonly property bool starting: shown !== null && shown.state === "starting"
  // AirDrop is on, or on its way: what the shell's toggle goes by.
  readonly property bool opened: starting || said.state !== "off"

  readonly property string command: "nova-airdrop"
  readonly property string glyph: "󰀃"
  readonly property string glyphFont: shell && shell.bar ? shell.bar.fontFamily : Style.font.family
  readonly property color ink: Commons.Color.notifications.text

  onFaceChanged: if (face) look = face
  onShownChanged: {
    var next = Model.face(shown, now)
    away.stop()
    if (next && next.stays > 0) {
      away.interval = next.stays
      away.start()
    }
  }

  // The shell's summon and hide: on and off.
  function open(payload) {
    turnOn()
  }

  function close() {
    turnOff()
  }

  function turnOn() {
    if (opened) return
    starter.code = -1
    starter.words = null
    shown = { state: "starting" }
    starter.running = true
  }

  function turnOff() {
    if (!opened) {
      shown = null
      return
    }
    stopping = true
    Quickshell.execDetached([command, "off"])
  }

  // An answer from the card: what one of the face's answers `does`.
  function answer(does) {
    if (does === "stop") turnOff()
    else if ((does === "accept" || does === "decline") && shown && shown.state === "asked")
      Quickshell.execDetached([command, does, Model.text(shown.id)])
  }

  // A line of the watch.
  function told(line) {
    var next = Model.parse(line)
    if (!next) return
    var before = said
    said = next
    now = Date.now() / 1000
    switch (next.state) {
    case "off":
      // An end stays its moment, and a start not yet up is not over.
      if (!Model.over(shown) && !starting)
        shown = !stopping && Model.gaveUp(before, now) ? { state: "ended" } : null
      stopping = false
      break
    case "received":
    case "links":
      announce(next)
      shown = null
      break
    default:
      shown = next
    }
  }

  // What came in, as a notification: a click opens it.
  function announcement(state) {
    var arrival = Model.arrival(state)
    if (!arrival) return []
    var words = ["nova-notification-send", "-u", "normal", "-g", glyph]
    if (arrival.picture !== "") words.push("--image", arrival.picture)
    words.push(arrival.headline, arrival.words)
    if (arrival.opens !== "") words.push("--exec", arrival.browser ? "nova-launch-browser" : "xdg-open", arrival.opens)
    return words
  }

  function announce(state) {
    var words = announcement(state)
    if (words.length > 0) Quickshell.execDetached(words)
  }

  // `nova airdrop on` is done when it has ended and its last words are in.
  function started() {
    if (starter.code < 0 || starter.words === null) return
    var code = starter.code
    var why = String(starter.words).trim().split("\n").slice(0, 2).join(" ").slice(0, 240)
    starter.code = -1
    starter.words = null
    if (!starting) return
    if (code !== 0) shown = { state: "error", why: why }
    // Up, and the watch says so in a moment; a watch that says nothing leaves no card behind.
    else if (said.state === "off") unheard.restart()
  }

  Timer {
    id: away
    onTriggered: airdrop.shown = null
  }

  Timer {
    id: unheard
    interval: 4000
    onTriggered: if (airdrop.starting) airdrop.shown = null
  }

  Timer {
    interval: 1000
    repeat: true
    running: !!airdrop.shown && airdrop.shown.state === "waiting"
    onTriggered: airdrop.now = Date.now() / 1000
  }

  Process {
    id: starter
    property int code: -1
    property var words: null
    command: [airdrop.command, "on"]
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
    onExited: again.start()
  }

  Timer {
    id: again
    interval: 5000
    onTriggered: {
      interval = Math.min(interval * 4, 300000)
      watcher.running = true
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
    function state(): string { return airdrop.shown ? airdrop.shown.state : airdrop.said.state }
  }

  // The window is the card's size, below the bar where the bar is on top.
  PanelWindow {
    id: window

    readonly property string barSide: airdrop.shell && airdrop.shell.barConfig ? String(airdrop.shell.barConfig.position || "top") : "top"
    readonly property int barRoom: (airdrop.shell && airdrop.shell.bar && !airdrop.shell.bar.tucked ? Math.max(0, airdrop.shell.bar.thickness)
      : Style.bar.sizeHorizontal) + Style.gapsOut

    visible: airdrop.face !== null
    anchors.top: true
    margins.top: barSide === "top" ? barRoom : Style.gapsOut
    implicitWidth: card.width
    implicitHeight: card.height
    color: "transparent"
    WlrLayershell.namespace: "nova-airdrop"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    BorderSurface {
      id: card

      readonly property real margin: Style.space(12)

      width: Style.space(380)
      height: edge.top + margin + body.implicitHeight + margin + edge.bottom
      radius: Style.cornerRadius
      color: Commons.Color.notifications.background
      frame: Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(2)))

      RowLayout {
        id: body
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.edge.top + card.margin
        anchors.leftMargin: card.edge.left + card.margin
        anchors.rightMargin: card.edge.right + card.margin
        spacing: Style.space(12)

        Text {
          Layout.alignment: Qt.AlignTop
          textFormat: Text.PlainText
          text: airdrop.glyph
          color: airdrop.ink
          font.family: airdrop.glyphFont
          font.pixelSize: Style.font.displayLarge
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Words {
            text: airdrop.look.title
            font.bold: true
            maximumLineCount: 2
          }

          Words {
            visible: text !== ""
            text: airdrop.look.words
            maximumLineCount: 3
          }

          Words {
            visible: text !== ""
            text: airdrop.look.note
            color: Qt.darker(airdrop.ink, 1.3)
            font.pixelSize: Style.font.body
            maximumLineCount: 2
          }

          // How much is in.
          Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(6)
            visible: airdrop.look.share >= 0
            height: Math.max(Style.space(4), 2)
            color: Util.alpha(airdrop.ink, 0.25)

            Rectangle {
              width: parent.width * Math.max(0, airdrop.look.share)
              height: parent.height
              color: Commons.Color.accent

              Behavior on width {
                NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
              }
            }
          }

          RowLayout {
            Layout.alignment: Qt.AlignRight
            Layout.topMargin: Style.space(8)
            visible: airdrop.look.answers.length > 0
            spacing: Style.space(8)

            Repeater {
              model: airdrop.look.answers

              Button {
                required property var modelData
                text: modelData.says
                bordered: true
                selected: modelData.main
                foreground: airdrop.ink
                onClicked: airdrop.answer(modelData.does)
              }
            }
          }
        }
      }
    }
  }

  // Plain text: every word of these can be a sender's.
  component Words: Text {
    Layout.fillWidth: true
    textFormat: Text.PlainText
    color: airdrop.ink
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    wrapMode: Text.Wrap
    elide: Text.ElideRight
  }
}
