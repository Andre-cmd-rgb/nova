import QtQuick
import Quickshell.Io

// Which sound outputs have something to play into, for a list of them on
// screen: <plugged> maps a sink's name to false for one with nothing in its
// jack (HDMI with no screen, say) and for speakers that a speaker tuning
// stands in front of; a sink it does not name is fine. <known> once it has
// been told.
//
// nova-audio-sink-availability tells, a line per sink: its name, a tab, and
// 0 or 1. It is asked when <watching> turns on, and after that only when
// `pactl subscribe` reports a card changing or a sink coming or going (a
// cable in a jack, a tuning applied), never on a timer.
Item {
  id: outputs

  property bool watching: false
  property var plugged: ({})
  property bool known: false

  // A change came while the helper ran, which may have read the sinks as
  // they were before it: it runs once more.
  property bool _again: false

  function ask() {
    if (helper.running) _again = true
    else helper.running = true
  }

  function _read(text) {
    const found = {}
    for (const line of String(text || "").split("\n")) {
      const [name, state] = line.trim().split("\t")
      if (state !== undefined) found[name] = state !== "0"
    }
    return found
  }

  function _watch() {
    events.running = watching
    if (watching) ask()
  }

  onWatchingChanged: _watch()
  Component.onCompleted: _watch()

  Process {
    id: helper
    command: ["nova-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        outputs.plugged = outputs._read(text)
        outputs.known = true
      }
    }
    onExited: {
      if (!outputs._again) return
      outputs._again = false
      Qt.callLater(outputs.ask)
    }
  }

  // The events of one change come a few at a time: they are let settle.
  Timer {
    id: settle
    interval: 250
    onTriggered: outputs.ask()
  }

  // A sink's own events are mostly its volume; a port plugged in is an event
  // of its card.
  Process {
    id: events
    command: ["env", "LC_ALL=C.UTF-8", "pactl", "subscribe"]
    stdout: SplitParser {
      onRead: line => {
        if (/ on card #|'(new|remove)' on sink #/.test(line)) settle.restart()
      }
    }
    // It ends when the sound server restarts. It starts again a little
    // later, and asks, as what changed in between went unheard.
    onExited: if (outputs.watching) rewatch.start()
  }

  Timer {
    id: rewatch
    interval: 2000
    onTriggered: {
      if (!outputs.watching) return
      events.running = true
      outputs.ask()
    }
  }
}
