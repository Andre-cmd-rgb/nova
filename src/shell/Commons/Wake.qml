pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The moments the wall clock moves in a way a timer cannot see: a Timer runs
// on the monotonic clock, which stands still while the machine sleeps and
// does not follow a clock that is set or a new time zone, so what waits on
// one comes back as it went. nova-sessiond writes $XDG_RUNTIME_DIR/nova/clock
// at each, one line with its reason, "woke", "set" or "zone", the wall
// clock's seconds and a count, so that each is new text
// (src/session/daemon/src/clock.rs); this watches the file, with no clock
// of its own, and says woke() for the whole shell. What waits
// for a time of day aims a Timer at it and aims it again then. The
// JavaScript engine, which keeps the time zone's offset until it is told,
// is told first each time: a new zone is one of them.
QtObject {
  id: wake

  signal woke()

  readonly property string folder: Quickshell.env("XDG_RUNTIME_DIR") + "/nova"
  // The line read last; what the file held before the shell started is not
  // news.
  property string last: ""
  property bool read: false

  function take(text) {
    const line = String(text || "").trim()
    const news = read && line !== "" && line !== last
    read = true
    last = line
    if (!news) return
    Date.timeZoneUpdated()
    woke()
  }

  // Quickshell sees a file appear in a folder that is there, not in one made
  // after it started looking: the folder first, once.
  property bool watching: false

  property Process maker: Process {
    running: true
    command: ["mkdir", "-p", wake.folder]
    onExited: wake.watching = true
  }

  property WatchedFile stamp: WatchedFile {
    path: wake.watching ? wake.folder + "/clock" : ""
    onLoaded: wake.take(text())
    onLoadFailed: wake.take("")
  }
}
