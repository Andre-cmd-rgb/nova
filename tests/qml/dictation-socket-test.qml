// platform: wayland
// stub: bin/dictation-helper dictation-helper
// warns: PeerClosedError
// warns: ServerNotFoundError
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/dictation" as DictationPlugin

// The shell's side of the dictation protocol (Dictation.qml) against a
// stand-in Unix socket: start, listening, finish and words pasted; finish
// queued before the connection opens; cancel flushed before closing; the
// daemon closing mid-dictation (while listening and while transcribing);
// "busy"; empty words ("Nothing heard"); and an unreachable socket.
ShellRoot {
  id: test

  readonly property string folder: Quickshell.env("XDG_RUNTIME_DIR") + "/nova"
  readonly property string socketPath: folder + "/dictation.sock"
  readonly property string insertedPath: Quickshell.env("HOME") + "/inserted"

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // Stand-in nova-dictationd on the exact path Dictation.qml connects to.
  property var currentClient: null
  property var received: []
  property int closes: 0
  property var onLine: null

  Process {
    id: mkdir
    command: ["mkdir", "-p", "-m", "700", test.folder]
    running: true
    onExited: {
      server.active = true
      next.start()
    }
  }

  Process {
    id: unlinkSock
    property bool done: false
    command: ["rm", "-f", test.socketPath]
    onExited: done = true
  }

  SocketServer {
    id: server
    active: false
    path: test.socketPath

    handler: Socket {
      id: client
      parser: SplitParser {
        onRead: function (line) {
          test.received = test.received.concat([line])
          if (test.onLine) test.onLine(client, line)
        }
      }
      onConnectedChanged: {
        if (connected) test.currentClient = client
        else {
          if (test.currentClient === client) test.currentClient = null
          test.closes++
        }
      }
    }
  }

  function reply(client, obj) {
    client.write(JSON.stringify(obj) + "\n")
    client.flush()
  }

  function closeClient(client) {
    client.flush()
    client.connected = false
  }

  DictationPlugin.Dictation {
    id: dictation
    helper: "dictation-helper"
    source: ({ audio: { muted: false } })
  }

  FileView {
    id: insertedFile
    path: test.insertedPath
    blockAllReads: true
    printErrors: false
  }

  function inserted() {
    insertedFile.reload()
    return String(insertedFile.text() || "")
  }

  property int step: 0
  property int tries: 0
  property int closesBefore: 0

  readonly property var steps: [
    // Wait for initial readiness check ("ready").
    () => dictation.readiness === "ready",

    // 1. Start -> listening -> finish -> words pasted.
    () => {
      received = []
      onLine = (c, line) => {
        if (line === "start") reply(c, { type: "listening" })
        else if (line === "finish") {
          reply(c, { type: "text", text: "Hello world. " })
          closeClient(c)
        }
      }
      dictation.press()
      return true
    },
    () => received.length === 1 && received[0] === "start" && dictation.phase === "listening",
    () => {
      check(dictation.reached && dictation.phase === "listening", "start opens the socket and stays listening")
      dictation.finish()
      return true
    },
    () => dictation.phase === "done" && currentClient === null && inserted() === "Hello world. \n",
    () => {
      check(received.join(",") === "start,finish", "finish sends finish after start (" + received.join(",") + ")")
      check(dictation.phase === "done" && inserted() === "Hello world. \n", "words answer delivers text to helper and marks done")
      return true
    },

    // 2. Finish right after press: start and finish arrive in order, words paste.
    () => {
      received = []
      onLine = (c, line) => {
        if (line === "start") reply(c, { type: "listening" })
        else if (line === "finish") {
          reply(c, { type: "text", text: "Quick. " })
          closeClient(c)
        }
      }
      dictation.press()
      dictation.finish()
      return true
    },
    () => dictation.phase === "done" && currentClient === null && inserted() === "Hello world. \nQuick. \n",
    () => {
      check(received.join(",") === "start,finish", "immediate finish after press arrives after start (" + received.join(",") + ")")
      return true
    },

    // 3. Cancel while listening flushes "cancel" and closes the connection.
    () => {
      received = []
      closesBefore = closes
      onLine = (c, line) => {
        if (line === "start") reply(c, { type: "listening" })
      }
      dictation.press()
      return true
    },
    () => received.length === 1 && received[0] === "start" && dictation.reached,
    () => {
      dictation.cancel()
      return true
    },
    () => closes > closesBefore && currentClient === null,
    () => {
      check(dictation.phase === "idle", "cancel returns the pill to idle")
      check(received.join(",") === "start,cancel", "cancel is flushed to the daemon before closing (" + received.join(",") + ")")
      return true
    },

    // 4. Daemon closes mid-dictation while listening -> "Dictation stopped".
    () => {
      received = []
      onLine = (c, line) => {
        if (line === "start") {
          reply(c, { type: "listening" })
          closeClient(c)
        }
      }
      dictation.press()
      return true
    },
    () => dictation.phase === "message" && currentClient === null,
    () => {
      check(dictation.message === "Dictation stopped", "daemon gone while listening says Dictation stopped (" + dictation.message + ")")
      return true
    },

    // 5. Daemon closes mid-dictation while transcribing -> "Could not transcribe".
    () => {
      received = []
      onLine = (c, line) => {
        if (line === "start") reply(c, { type: "listening" })
        else if (line === "finish") closeClient(c)
      }
      dictation.press()
      return true
    },
    () => received.length === 1 && received[0] === "start" && dictation.reached,
    () => {
      dictation.finish()
      return true
    },
    () => dictation.phase === "message" && currentClient === null,
    () => {
      check(dictation.message === "Could not transcribe", "daemon gone while transcribing says Could not transcribe (" + dictation.message + ")")
      return true
    },

    // 6. "busy" error -> "Dictation is busy".
    () => {
      received = []
      onLine = (c, line) => {
        if (line === "start") {
          reply(c, { type: "error", error: "busy" })
          closeClient(c)
        }
      }
      dictation.press()
      return true
    },
    () => dictation.phase === "message" && currentClient === null,
    () => {
      check(dictation.message === "Dictation is busy", "busy error says Dictation is busy (" + dictation.message + ")")
      return true
    },

    // 7. Empty text -> "Nothing heard", nothing pasted.
    () => {
      received = []
      onLine = (c, line) => {
        if (line === "start") reply(c, { type: "listening" })
        else if (line === "finish") {
          reply(c, { type: "text", text: "" })
          closeClient(c)
        }
      }
      dictation.press()
      return true
    },
    () => received.length === 1 && received[0] === "start" && dictation.reached,
    () => {
      dictation.finish()
      return true
    },
    () => dictation.phase === "message" && currentClient === null,
    () => {
      check(dictation.message === "Nothing heard", "empty words say Nothing heard (" + dictation.message + ")")
      check(inserted() === "Hello world. \nQuick. \n", "cancel, errors and empty words paste nothing (" + JSON.stringify(inserted()) + ")")
      return true
    },

    // 8. Unreachable socket -> "Dictation could not start".
    () => {
      server.active = false
      unlinkSock.done = false
      unlinkSock.running = true
      return true
    },
    () => unlinkSock.done,
    () => {
      dictation.press()
      return true
    },
    () => dictation.phase === "message",
    () => {
      check(dictation.message === "Dictation could not start", "unreachable socket says Dictation could not start (" + dictation.message + ")")
      return true
    }
  ]

  Timer {
    id: next
    interval: 50
    onTriggered: {
      if (test.step >= test.steps.length) {
        console.log("DONE")
        Qt.quit()
        return
      }
      if (test.steps[test.step]()) {
        test.step++
        test.tries = 0
      } else if (++test.tries >= 80) {
        test.check(false, "step " + test.step + " timed out (phase=" + dictation.phase + " msg=" + dictation.message + " received=" + test.received.join(",") + ")")
        console.log("DONE")
        Qt.quit()
        return
      }
      next.restart()
    }
  }
}
