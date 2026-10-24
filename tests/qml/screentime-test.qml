import QtQuick
import Quickshell
import "plugins/screentime/Counting.js" as Counting

// Screen Time's counting: going idle takes the timeout back from what is still
// pending first, then from the hours the last writes went to, newest first,
// and never from a write older than the timeout.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(Counting.hourOf(new Date(2026, 9, 24, 9, 59, 30)) === "2026-10-24T09", "an hour in local time")

    var written = [
      { time: 1000, hour: "2026-10-24T00", seconds: { foot: 40, code: 20 } },
      { time: 940, hour: "2026-10-23T23", seconds: { foot: 60 } },
      { time: 880, hour: "2026-10-23T23", seconds: { foot: 60 } },
      { time: 820, hour: "2026-10-23T23", seconds: { foot: 60 } }
    ]
    var back = Counting.takeBack({ foot: 30, code: 5 }, written, "foot", 180, 1030 - 180)
    check(back.pending.foot === 0 && back.pending.code === 5, "the pending seconds go first")
    check(back.pairs.join(" ") === "foot=-40@2026-10-24T00 foot=-60@2026-10-23T23 foot=-50@2026-10-23T23",
      "the rest from the hours written to, newest first (" + back.pairs.join(" ") + ")")
    check(back.written[0].seconds.foot === 0 && back.written[0].seconds.code === 20 && back.written[2].seconds.foot === 10,
      "what was taken back is gone from the writes, the other apps' stays")

    var old = Counting.takeBack({}, written, "foot", 180, 950)
    check(old.pairs.join(" ") === "foot=-40@2026-10-24T00", "a write older than the timeout is left alone")
    check(written[0].seconds.foot === 40, "nothing is changed in place")
    console.log("DONE")
    Qt.quit()
  }
}
