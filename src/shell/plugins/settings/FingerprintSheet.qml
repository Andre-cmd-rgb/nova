import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Fingerprints.js" as Fingerprints

SettingsSheet {
  id: root

  property var enrolled: []
  property int stages: 0
  property string finger: ""
  property int acceptedTouches: 0
  property bool enrolling: false
  property bool completed: false
  property bool reported: false
  property string hint: ""
  property string error: ""
  readonly property var available: Fingerprints.fingers.filter(function (finger) { return root.enrolled.indexOf(finger) < 0 })
  readonly property real progress: stages > 0 ? Math.min(1, acceptedTouches / stages) : 0
  signal saved()

  function open() {
    if (enrollProc.running) return
    finger = available.length ? available[0] : ""
    acceptedTouches = 0
    enrolling = false
    completed = false
    reported = false
    hint = ""
    error = ""
    opened = true
  }

  function commandForFinger() {
    // fprintd writes to a pipe here; line buffering makes each touch visible
    // immediately instead of holding all the progress until the process exits.
    return ["stdbuf", "-oL", "-eL", "fprintd-enroll", "-f", finger]
  }

  function start() {
    if (!opened || enrolling || enrollProc.running || stages <= 0 || available.indexOf(finger) < 0) return
    acceptedTouches = 0
    completed = false
    reported = false
    hint = "Touch the sensor"
    error = ""
    enrolling = true
    enrollProc.command = commandForFinger()
    enrollProc.running = true
  }

  function cancel() {
    opened = false
    enrolling = false
    enrollProc.running = false
  }

  function acceptLine(line) {
    if (!enrolling || !opened) return
    var match = /Enroll result: (enroll-[a-z-]+)/.exec(line)
    if (!match) {
      if (/alreadyinuse|already in use/i.test(line)) error = "The sensor is busy."
      else if (/permissiondenied|not authorized|not permitted/i.test(line)) error = "Not permitted."
      return
    }
    var result = match[1]
    if (result === "enroll-stage-passed") {
      acceptedTouches = Math.min(stages, acceptedTouches + 1)
      hint = "Lift your finger and touch again"
    } else if (result === "enroll-completed") {
      acceptedTouches = stages
      completed = true
      enrolling = false
      hint = ""
      error = ""
    } else {
      var retries = {
        "enroll-retry-scan": "Lift your finger and touch again",
        "enroll-swipe-too-short": "Too short",
        "enroll-too-fast": "Touch more slowly",
        "enroll-finger-not-centered": "Centre your finger",
        "enroll-remove-and-retry": "Lift your finger and touch again"
      }
      if (retries[result]) hint = retries[result]
      else {
        var failures = {
          "enroll-data-full": "The sensor is full.",
          "enroll-duplicate": "This finger is already added.",
          "enroll-disconnected": "The sensor disconnected."
        }
        error = failures[result] || "Could not add this finger."
        enrolling = false
        hint = ""
      }
    }
  }

  function finish(exitCode) {
    if (completed) {
      if (!reported) { reported = true; saved() }
    } else if (opened) {
      enrolling = false
      hint = ""
      if (!error) error = exitCode === 0 ? "The fingerprint was not saved." : "Could not add this finger."
    }
  }

  onCanceled: cancel()
  Component.onDestruction: cancel()

  Process {
    id: enrollProc
    environment: ({ LC_ALL: "C" })
    stdout: SplitParser { onRead: function (line) { root.acceptLine(line) } }
    stderr: SplitParser { onRead: function (line) { root.acceptLine(line) } }
    onExited: function (exitCode) { root.finish(exitCode) }
  }

  Text {
    width: parent.width
    text: root.completed ? "Fingerprint added." : (root.enrolling ? "Touch the sensor" : "Add a Finger")
    textFormat: Text.PlainText
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.title
  }
  Dropdown {
    width: parent.width
    showLabel: false
    visible: !root.enrolling && !root.completed
    options: root.available.map(function (finger) { return { value: finger, label: Fingerprints.label(finger) } })
    value: root.finger
    onChanged: function (value) { root.finger = value }
  }
  Rectangle {
    width: parent.width
    height: Style.space(6)
    visible: root.enrolling || root.completed
    radius: height / 2
    color: Util.alpha(Commons.Color.foreground, 0.12)
    Rectangle {
      width: parent.width * root.progress
      height: parent.height
      radius: height / 2
      color: Commons.Color.accent
      Behavior on width { NumberAnimation { duration: 150 } }
    }
  }
  Text {
    width: parent.width
    visible: root.hint.length > 0 || root.error.length > 0
    text: root.error || root.hint
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.error ? Commons.Color.urgent : Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
  Row {
    anchors.right: parent.right
    spacing: Style.space(10)
    Button {
      text: root.completed ? "Done" : "Cancel"
      bordered: true
      focusable: true
      onClicked: root.cancel()
    }
    Button {
      text: root.error ? "Try Again" : "Start"
      visible: !root.enrolling && !root.completed
      enabled: !enrollProc.running && root.stages > 0 && root.available.length > 0
      opacity: enabled ? 1 : 0.5
      bordered: true
      focusable: true
      onClicked: root.start()
    }
  }
}
