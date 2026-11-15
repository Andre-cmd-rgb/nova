import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "UpdatesModel.js" as Model

// Updates' place in Settings: Nova's version, whether a newer one is out, and
// the update itself with no terminal (nova-update-run): a bar for how far it
// is, its output under Details, and one authentication for the release and the
// apps together. An app whose AUR recipe changed beyond a new version waits
// here, to be read before it is built.
//
// nova update --status writes how far it is to status.json, which this only
// reads: closed and opened again, the page finds the run where it is.
Column {
  id: root

  property string version: ""
  // Opened to install Chrome and VS Code (by nova-launch-browser, with no
  // browser at all).
  property bool offerApps: false
  // A run ended: Settings reads its state again.
  signal finished()
  // Check was pressed: Settings looks for firmware too.
  signal checking()

  readonly property string dir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/update"
  readonly property string releases: "https://github.com/Andre-cmd-rgb/nova/releases/tag/v"
  property var status: ({})
  property bool alive: true
  property bool aliveAsked: false
  property string check: ""
  property bool details: false
  property string logText: ""
  property string reviewing: ""
  property string reviewText: ""
  property string lastState: ""
  // Watched once it exists: Quickshell sees a file appear in a folder that
  // is there, not in one made after it started looking.
  property bool watching: false

  readonly property string state: Model.state(status, alive)
  readonly property bool running: state === "running"
  readonly property bool ended: state === "failed" || state === "stopped"
  readonly property var summary: Model.summary(status, check, alive)
  readonly property real fraction: Model.fraction(status)
  readonly property string available: running ? "" : Model.availableVersion(check)

  spacing: Style.space(8)

  Component.onCompleted: checkProc.running = true

  onStateChanged: {
    if (lastState === "running" && (state === "done" || state === "failed")) {
      if (!checkProc.running) checkProc.running = true
      root.finished()
    }
    lastState = state
  }

  function start(args) {
    alive = true
    details = false
    reviewing = ""
    Util.execArgv(["nova-update-run"].concat(args))
  }

  function act(action) {
    if (action === "update" || action === "retry") start([])
    else if (action === "restart") Util.execArgv(["nova-system-reboot"])
    else if (action === "check") {
      if (!checkProc.running) checkProc.running = true
      root.checking()
    }
  }

  function review(pkg) {
    reviewing = pkg
    reviewText = ""
    if (pkg === "") return
    reviewProc.pkg = pkg
    reviewProc.running = true
  }

  Process {
    command: ["mkdir", "-p", root.dir]
    running: true
    onExited: root.watching = true
  }

  FileView {
    path: root.watching ? root.dir + "/status.json" : ""
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && typeof parsed === "object") root.status = parsed
      } catch (e) {
        // Written whole, then moved into place: a bad read is someone else's.
      }
      // One stopped from outside left "running" behind it.
      if (root.status.state === "running" && !root.aliveAsked) {
        root.aliveAsked = true
        aliveProc.running = true
      }
    }
    onLoadFailed: root.status = ({})
    onFileChanged: reload()
  }

  FileView {
    id: logFile
    path: root.details ? root.dir + "/status.log" : ""
    watchChanges: true
    printErrors: false
    onLoaded: root.logText = Model.tail(text(), 200)
    // pacman writes a line at a time: twice a second is enough to read.
    onFileChanged: if (!logTimer.running) logTimer.start()
  }

  Timer {
    id: logTimer
    interval: 500
    onTriggered: logFile.reload()
  }

  Process {
    id: aliveProc
    command: ["systemctl", "--user", "--quiet", "is-active", "nova-update.service"]
    onExited: function (exitCode) { root.alive = exitCode === 0 }
  }

  Process {
    id: checkProc
    command: ["nova-update-check"]
    onStarted: root.check = ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.check = String(text || "").trim() || "error"
    }
  }

  Process {
    id: reviewProc
    property string pkg: ""
    command: ["nova-apps-install", "--review", pkg]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.reviewText = String(text || "")
    }
  }

  Line {
    label: root.version ? "Nova " + root.version : "Nova"
    detail: root.summary.detail
    Row {
      spacing: Style.space(8)
      Button {
        visible: root.available !== ""
        text: "Release Notes"
        bordered: true
        onClicked: Util.execArgv(["nova-launch-browser", root.releases + root.available])
      }
      Button {
        visible: root.running || root.ended
        text: root.details ? "Hide Details" : "Details"
        bordered: true
        onClicked: root.details = !root.details
      }
      Button {
        visible: root.summary.action !== ""
        text: ({ update: "Update Now", check: "Check", restart: "Restart", retry: "Try Again" })[root.summary.action] || ""
        bordered: true
        onClicked: root.act(root.summary.action)
      }
    }
  }

  // How far it is; while that is not known (an app building, the password
  // asked for), the track alone.
  Item {
    visible: root.running
    width: parent.width
    height: Style.space(6)
    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius > 0 ? height / 2 : 0
      color: Commons.Color.foreground
      opacity: 0.12
    }
    Rectangle {
      visible: root.fraction > 0
      width: parent.width * root.fraction
      height: parent.height
      radius: Style.cornerRadius > 0 ? height / 2 : 0
      color: Commons.Color.accent
    }
  }

  Caption {
    width: parent.width
    text: Model.leftOver(root.status, root.alive)
    visible: text.length > 0
  }

  Output {
    visible: root.details && (root.running || root.ended)
    text: root.logText
    follow: true
  }

  Line {
    visible: root.offerApps && !root.running
    label: "Chrome and VS Code"
    detail: "Not installed."
    Button {
      text: "Install"
      bordered: true
      onClicked: root.start(["--apps-only", "--apps-install"])
    }
  }

  // Apps whose recipe changed more than its version: read, then built at
  // the commit that was read, or left for later.
  Repeater {
    model: root.running ? [] : (root.status.held || [])
    delegate: Column {
      id: held
      required property var modelData
      readonly property bool open: root.reviewing === modelData
      readonly property string commit: open ? Model.reviewCommit(root.reviewText) : ""
      width: root.width
      spacing: Style.space(8)
      Line {
        label: Model.appName(held.modelData)
        detail: "Its recipe changed since it was last built."
        Row {
          spacing: Style.space(8)
          Button {
            visible: held.commit !== ""
            text: "Build"
            bordered: true
            onClicked: root.start(Model.approveCommand(held.modelData, held.commit))
          }
          Button {
            text: held.open ? "Not Now" : "Review…"
            bordered: true
            onClicked: root.review(held.open ? "" : held.modelData)
          }
        }
      }
      Caption {
        visible: held.open && held.commit === ""
        width: parent.width
        text: reviewProc.running ? "Reading the recipe…" : "Could not read the recipe."
      }
      Output {
        visible: held.commit !== ""
        text: Model.reviewBody(root.reviewText)
        follow: false
      }
    }
  }

  // A box of command output, scrolled to its end when it follows.
  component Output: Item {
    id: output
    property alias text: outputText.text
    property bool follow: false
    width: parent ? parent.width : 0
    height: Style.space(200)
    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius > 0 ? Style.space(6) : 0
      color: Commons.Color.foreground
      opacity: 0.05
    }
    Flickable {
      id: flick
      anchors.fill: parent
      anchors.margins: Style.space(10)
      clip: true
      contentWidth: width
      contentHeight: outputText.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      onContentHeightChanged: if (output.follow) contentY = Math.max(0, contentHeight - height)
      Caption {
        id: outputText
        width: flick.width
        wrapMode: Text.WrapAnywhere
      }
    }
  }
}
