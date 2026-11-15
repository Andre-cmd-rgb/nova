import QtQuick
import Quickshell.Io
import Quickshell.Wayland
import "Counting.js" as Counting

// The part that does the counting. It watches which window has focus and
// whether anyone is still at the keyboard, adds up seconds per application,
// and hands them to `screentime record` once a minute.
//
// Deliberately thin: nothing is aggregated here and nothing is kept in memory
// beyond the current minute, so a shell restart costs at most one flush and
// every question about the data is answered by the CLI instead.
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/screentime")).replace(/^file:\/\//, ""))

  // Settings live in the CLI's config file — one place to change them, and no
  // second copy in shell.json that could disagree with it.
  property int idleTimeout: 180
  property int flushInterval: 60

  readonly property var toplevel: ToplevelManager.activeToplevel
  readonly property string focusedApp: toplevel ? String(toplevel.appId || "") : ""

  // Seconds counted but not yet written, keyed by app id.
  property var pending: ({})
  // The writes of the last idle timeout, newest first: when each was made,
  // the hour it went to, and its seconds per app. Going idle takes the
  // timeout back from the hours it was written to.
  property var written: []
  // Negative pairs for hours already written, sent with the next write.
  property var takenBack: []
  property string currentApp: ""
  property real since: 0
  property bool counting: true

  readonly property bool idle: idleMonitor.isIdle

  signal flushed()

  function now() { return Date.now() / 1000 }

  function add(app, seconds) {
    if (!app) return
    var next = pending
    next[app] = (next[app] || 0) + seconds
    pending = next
  }

  // Close off the stretch that just ended and start a new one. A suspended
  // laptop wakes with a wall clock that has moved hours; the cap keeps that
  // from landing on whichever window happened to have focus at the time.
  function accumulate() {
    var elapsed = now() - since
    since = now()
    if (!counting || currentApp === "" || elapsed <= 0) return
    add(currentApp, Math.min(elapsed, flushInterval + 5))
  }

  function flush() {
    // A flush still in flight keeps its seconds: they are added to the next
    // one rather than dropped or double-counted.
    if (recordProc.running) return

    var time = now()
    var hour = Counting.hourOf(new Date())
    var args = takenBack.slice()
    var seconds = ({})
    for (var app in pending) {
      var counted = Math.round(pending[app])
      if (counted <= 0) continue
      args.push(app + "=" + counted + "@" + hour)
      seconds[app] = counted
    }
    pending = ({})
    takenBack = []
    written = [{ time: time, hour: hour, seconds: seconds }].concat(written.filter(function (write) {
      return write.time > time - root.idleTimeout
    }))
    if (args.length === 0) {
      flushed()
      return
    }
    recordProc.command = [root.helper, "record"].concat(args)
    recordProc.running = true
  }

  // The idle timeout has been counted by the time the monitor fires: part of
  // it is still pending, and the rest went to the hours of the last writes.
  function takeBackIdle(app) {
    var back = Counting.takeBack(pending, written, app, idleTimeout, now() - idleTimeout)
    pending = back.pending
    written = back.written
    takenBack = takenBack.concat(back.pairs)
  }

  function flushNow() {
    accumulate()
    flush()
  }

  onFocusedAppChanged: {
    accumulate()
    currentApp = focusedApp
  }

  Component.onCompleted: {
    since = now()
    currentApp = focusedApp
    loadSettings()
  }

  function loadSettings() {
    if (!idleProc.running) idleProc.running = true
    if (!flushProc.running) flushProc.running = true
  }

  Process {
    id: recordProc
    onExited: root.flushed()
  }

  Process {
    id: idleProc
    command: [root.helper, "config", "IDLE_TIMEOUT"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = parseInt(String(text).trim(), 10)
        if (isFinite(value) && value > 0) root.idleTimeout = value
      }
    }
  }

  Process {
    id: flushProc
    command: [root.helper, "config", "FLUSH_INTERVAL"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = parseInt(String(text).trim(), 10)
        if (isFinite(value) && value >= 10) root.flushInterval = value
      }
    }
  }

  // Idle is what separates "at this machine" from "left it running". The
  // timeout has already been counted by the time it fires, so it is taken
  // back off whatever had focus, in the hours it was counted in.
  IdleMonitor {
    id: idleMonitor
    enabled: true
    timeout: root.idleTimeout
    // An inhibitor means something is deliberately keeping the screen awake —
    // a full-screen video is time spent at the machine, not time away.
    respectInhibitors: true
    onIsIdleChanged: {
      if (isIdle) {
        accumulate()
        if (root.currentApp !== "") root.takeBackIdle(root.currentApp)
        root.counting = false
        root.flush()
      } else {
        root.since = root.now()
        root.counting = true
      }
    }
  }

  Timer {
    interval: root.flushInterval * 1000
    running: true
    repeat: true
    onTriggered: root.flushNow()
  }

  // Settings are read from disk rather than watched; a ten-minute refresh is
  // soon enough for a value someone changes by hand every few months.
  Timer {
    interval: 600000
    running: true
    repeat: true
    onTriggered: root.loadSettings()
  }
}
