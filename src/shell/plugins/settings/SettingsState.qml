import QtQuick
import Quickshell.Io
import "Asked.js" as Asked

// What Settings' window and the welcome show, and how they change it.
// `nova-settings state` fills <info>; a change is the same command the CLI
// offers (nova-theme set, nova battery limit, ...), run one at a time and in
// order, and the state is read again once the last is done, so what the
// window shows is what is set. A command that fails leaves its last line in
// <failure>.
//
// A change shows at once: what it sets (run's <changes>, by path in the
// state, "bar.transparent": true) is laid over what was read, so that a
// switch moves as it is clicked, not a command and a read later. It stays
// laid over until a read begun after its command was done comes back, which
// has it as it is; a read that fails keeps what is on screen. A change
// whose command failed, or could not start, goes at once, with its failure
// said, and the read after has it as it is.
QtObject {
  id: settings

  // `info`, not `data`: `data` is QQuickItem's default property.
  readonly property var info: Asked.over(read, asked)
  property bool loaded: false
  property string failure: ""
  property bool reloadWanted: false
  property var queue: []

  // What the last read gave.
  property var read: ({})
  // The changes not read back yet: {number, path, value}, in the order asked.
  property var asked: []
  // The number of the last change asked, and of the last whose command is
  // done; and that, as the read under way began.
  property int numbered: 0
  property int done: 0
  property int readFrom: 0

  function load() {
    if (stateProc.running) reloadWanted = true
    else startRead()
  }

  function startRead() {
    readFrom = done
    stateProc.running = true
  }

  // Runs <argv>; <changes>, if given, are what it sets, shown at once.
  function run(argv, changes) {
    failure = ""
    numbered += 1
    if (changes) {
      var more = asked.slice()
      for (var path in changes) more.push({ number: numbered, path: path, value: changes[path] })
      asked = more
    }
    var next = queue.slice()
    next.push({ argv: argv, number: numbered })
    queue = next
    pump()
  }

  function pump() {
    if (actionProc.running || queue.length === 0) return
    var next = queue.slice()
    var change = next.shift()
    actionProc.command = change.argv
    actionProc.number = change.number
    actionProc.over = false
    queue = next
    actionProc.running = true
  }

  // The change running is done: exited with <code>, or never started, with
  // <message> then.
  function finished(code, message) {
    var number = actionProc.number
    actionProc.over = true
    done = number
    if (code !== 0) {
      failure = message
      asked = asked.filter(function (change) { return change.number !== number })
    }
    if (queue.length > 0) pump()
    else load()
  }

  property Process stateProc: Process {
    command: ["nova-settings", "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text))
          if (parsed && typeof parsed === "object") {
            settings.asked = settings.asked.filter(function (change) { return change.number > settings.readFrom })
            settings.read = parsed
            settings.loaded = true
          }
        } catch (e) {
          // A truncated read keeps what is on screen.
        }
      }
    }
    onExited: {
      if (settings.reloadWanted) {
        settings.reloadWanted = false
        settings.startRead()
      }
    }
  }

  property Process actionProc: Process {
    property int number: 0
    // Whether the change running is done with: a command that cannot start
    // is never heard to exit, only to stop running.
    property bool over: true
    stderr: StdioCollector {
      id: actionErrors
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var message = String(actionErrors.text || "").trim().split("\n").pop()
      settings.finished(exitCode, message.length > 0 ? message : "That did not work (exit " + exitCode + ").")
    }
    onRunningChanged: {
      if (!running && !over) settings.finished(-1, "Could not run " + command[0] + ".")
    }
  }
}
