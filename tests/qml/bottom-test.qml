// platform: wayland
import QtQuick
import Quickshell
import qs.Commons
import "plugins/dictation"
import "plugins/osd"

// The bottom of the screen has room for one pop-up at a time
// (Commons/Bottom.qml). The dictation's pill is up, a message of the OSD
// comes: the pill is hidden for the message's time, though dictation goes on
// in its phase, and is drawn again once the message is gone. The newest of
// the same rank holds the place; a message holds it over a pill that comes
// meanwhile, and the pill is back after it.
ShellRoot {
  id: test

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  Osd { id: osd }
  Dictation { id: dictation }

  // A window is no Item: it is among the plugin's data, not its children.
  function windowOf(plugin) {
    for (let i = 0; i < plugin.data.length; i++) {
      const o = plugin.data[i]
      if (o && o.contentItem !== undefined && o.implicitWidth !== undefined) return o
    }
    return null
  }

  function card(plugin) { return windowOf(plugin).contentItem.children[0] }

  property int step: 0

  Timer {
    interval: 400
    repeat: true
    running: true
    onTriggered: test.next()
  }

  function next() {
    switch (step++) {
    case 0:
      check(Bottom.holder === "", "nobody holds the place at first")
      dictation.pressedAt = Date.now()
      dictation.phase = "listening"
      break
    case 1:
      check(Bottom.holder === "dictation" && dictation.seen, "the pill holds the place while it listens")
      check(windowOf(dictation).visible && card(dictation).opacity === 1, "and is drawn")
      osd.open(JSON.stringify({ icon: "system-run", message: "Launching Files…", duration: "1200" }))
      break
    case 2:
      check(Bottom.holder === "osd" && osd.seen && !dictation.seen, "a message takes the place from the pill")
      check(dictation.phase === "listening" && dictation.shown, "dictation carries on, only its pill is out of sight")
      check(windowOf(osd).visible && card(osd).opacity === 1, "the message's card is drawn")
      check(card(dictation).opacity === 0, "the pill's card is faded out")
      check(Math.abs(windowOf(osd).margins.bottom - Bottom.foot) < 0.5, "the card's foot is the pill's")
      dictation.phase = "transcribing"
      break
    case 3:
      check(Bottom.holder === "osd" && dictation.phase === "transcribing", "the pill's phase changing meanwhile takes nothing back")
      break
    case 4:
    case 5:
    case 6:
      break
    case 7:
      check(!osd.opened && Bottom.holder === "dictation" && dictation.seen, "the pill is back once the message's time is over")
      check(dictation.look === "transcribing" && card(dictation).opacity === 1, "still current, and drawn")
      dictation.phase = "message"
      osd.open(JSON.stringify({ value: "40", max: "100", progressText: "40%", duration: "0" }))
      break
    case 8:
      check(Bottom.holder === "osd", "a level's card takes it too")
      dictation.phase = "idle"
      break
    case 9:
      check(Bottom.holder === "osd" && !dictation.seen, "the pill ending out of sight does not give the place away")
      osd.close()
      break
    case 10:
      check(Bottom.holder === "", "nobody holds it once both are done")
      Bottom.claim("a", 0)
      Bottom.claim("b", 0)
      check(Bottom.holder === "b", "of the same rank the newest holds")
      Bottom.claim("c", 1)
      Bottom.claim("d", 0)
      check(Bottom.holder === "c", "a higher rank holds over a newer, lower one")
      Bottom.release("c")
      check(Bottom.holder === "d", "and the newest of the rest after it")
      Bottom.release("d"); Bottom.release("b"); Bottom.release("a"); Bottom.release("a")
      check(Bottom.holder === "", "released claims are gone")
      console.log("DONE")
      Qt.quit()
      break
    }
  }
}
