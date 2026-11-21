import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Dictation's page in Settings: the speech model, downloaded or not (Super+D
// offers it too), whether nova-dictationd has it in memory now, the last
// dictation's words, and the user's own spellings (vocab.toml). It asks
// `nova dictation` and systemd, never nova-dictationd's socket: a look at
// this page does not start it.
Column {
  id: root
  spacing: Style.space(22)

  readonly property string modelSize: "669 MB"
  // `nova dictation check`: ready, no-engine, no-model or "no-model metered".
  property string readiness: ""
  property int progress: 0
  property bool verifying: false
  property string failure: ""
  // A second press removes the model: it is a long download back.
  property bool confirmRemove: false
  // nova-dictationd as systemd has it: running, and its memory in bytes.
  property bool running: false
  property real memory: 0
  property string last: ""

  readonly property bool engine: readiness !== "" && readiness !== "no-engine"
  readonly property bool ready: readiness === "ready"
  readonly property bool downloading: setup.running

  function refresh() {
    if (!checkProc.running) checkProc.running = true
    look()
  }

  function look() {
    if (!unitProc.running) unitProc.running = true
    if (!lastProc.running) lastProc.running = true
  }

  // systemctl show's lines: ActiveState=active, MemoryCurrent=<bytes> (or
  // [not set] when it is not running).
  function readUnit(text) {
    var state = String(text || "").match(/^ActiveState=(.*)$/m)
    var bytes = String(text || "").match(/^MemoryCurrent=(\d+)$/m)
    running = !!state && (state[1] === "active" || state[1] === "deactivating")
    memory = running && bytes ? Number(bytes[1]) : 0
  }

  Component.onCompleted: refresh()

  Timer {
    interval: 3000
    repeat: true
    running: root.visible && root.engine
    onTriggered: root.look()
  }

  Timer {
    interval: 4000
    running: root.confirmRemove
    onTriggered: root.confirmRemove = false
  }

  Process {
    id: checkProc
    command: ["nova-dictation", "check"]
    stdout: StdioCollector {
      onStreamFinished: root.readiness = String(text).trim()
    }
  }

  Process {
    id: unitProc
    command: ["systemctl", "--user", "show", "--property=ActiveState,MemoryCurrent", "nova-dictationd.service"]
    stdout: StdioCollector {
      onStreamFinished: root.readUnit(text)
    }
  }

  Process {
    id: lastProc
    command: ["nova-dictation", "last"]
    stdout: StdioCollector {
      onStreamFinished: root.last = String(text).trim()
    }
  }

  // "progress <percent>" lines, then "checking" against the model's SHA-256.
  Process {
    id: setup
    command: ["nova-dictation", "setup", "--progress"]
    stdout: SplitParser {
      onRead: function (line) {
        var m = /^progress (\d{1,3})$/.exec(String(line).trim())
        if (m) root.progress = Math.min(100, parseInt(m[1], 10))
        else if (String(line).trim() === "checking") root.verifying = true
      }
    }
    onExited: function (code) {
      root.failure = code === 0 ? "" : "The download stopped; Download carries on from where it was."
      root.refresh()
    }
  }

  Process {
    id: removal
    command: ["nova-dictation", "remove"]
    onExited: root.refresh()
  }

  Section {
    Line {
      label: "Speech model"
      detail: root.readiness === "" ? ""
        : !root.engine ? "This computer has no speech engine (whisper-cpp)"
        : root.downloading ? (root.verifying ? "Checking the download" : "Downloading, " + root.progress + "%")
        : root.ready ? "Parakeet, " + root.modelSize + ", on this computer"
        : root.failure !== "" ? root.failure
        : root.readiness.indexOf("metered") > 0 ? "Not downloaded (" + root.modelSize + "); this connection is metered"
        : "Not downloaded (" + root.modelSize + ")"

      // In a Row, which lays out only the button shown: the Line's slot is
      // as wide as all it holds, hidden or not.
      Row {
        spacing: Style.space(8)

        Button {
          visible: root.engine && !root.ready
          text: root.downloading ? "Stop" : "Download"
          bordered: true
          onClicked: {
            if (root.downloading) {
              setup.running = false
              return
            }
            root.progress = 0
            root.verifying = false
            root.failure = ""
            setup.running = true
          }
        }

        Button {
          visible: root.ready
          text: root.confirmRemove ? "Remove " + root.modelSize : "Remove"
          bordered: true
          enabled: !removal.running
          onClicked: {
            if (!root.confirmRemove) {
              root.confirmRemove = true
              return
            }
            root.confirmRemove = false
            removal.running = true
          }
        }
      }
    }

    // The bindings are data/hypr/keys/dictation.lua's; the tap's length is
    // DictationModel.js's tapMs.
    Line {
      visible: root.ready
      label: "Hold Super+D and speak"
      detail: "The words are pasted when you let go. A tap listens until the next press; Esc cancels."
    }

    Line {
      visible: root.ready
      label: "In memory"
      detail: root.running
        ? (root.memory > 0 ? Math.round(root.memory / 1e6) + " MB, " : "") + "until two minutes after the last dictation"
        : "No; it loads as the next dictation starts"
    }
  }

  Section {
    title: "LAST DICTATION"
    visible: root.last !== ""

    Text {
      width: parent.width
      text: root.last
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
      maximumLineCount: 4
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }

    Line {
      label: "Kept until you log out"
      detail: "nova dictation last prints it too"

      Button {
        text: "Copy"
        bordered: true
        onClicked: Util.execArgv(["bash", "-c", "nova-dictation last | wl-copy"])
      }
    }
  }

  Section {
    title: "YOUR SPELLINGS"
    visible: root.engine

    Line {
      label: "Words dictation writes another way"
      detail: "~/.config/nova/dictation/vocab.toml"

      Button {
        text: "Edit"
        bordered: true
        onClicked: Util.execArgv(["nova-dictation", "vocab"])
      }
    }
  }
}
