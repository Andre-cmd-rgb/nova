import QtQuick
import Quickshell
import "plugins/osd/OsdModel.js" as Face

// What the OSD makes of a request: a level and its readout, a message, and
// how long it stays, from the strings nova-osd sends and the numbers the
// shell's keys and panels do; and where each piece goes on the card.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var keys = Face.parse({ icon: "volume", value: 40 })
    check(keys.level && keys.fill === 0.4 && keys.words === "40%" && keys.duration === 1200
      && keys.glyph === Face.iconFor("volume-high", 40), "a level from the keys: its readout, the speaker, 1.2 s")

    var cli = Face.parse({ icon: "", message: "", value: "20", progressText: "20%", max: "100", duration: "" })
    check(cli.level && cli.fill === 0.2 && cli.words === "20%" && cli.glyph === Face.iconFor("volume-low", 20),
      "nova-osd -p 20: every field a string, no icon, the speaker with one wave")

    check(Face.parse({ value: 150, max: 100 }).fill === 1 && Face.parse({ value: -5 }).fill === 0
      && Face.parse({ value: 3, max: 4, progressText: "3 of 4" }).words === "3 of 4",
      "a level is kept within 0 and its maximum, its readout as given")

    var message = Face.parse({ icon: "microphone-muted", message: "Microphone muted", value: 30 })
    check(!message.level && message.fill === 0 && message.words === "Microphone muted", "a message wins over a level")

    check(Face.parse({ duration: 0 }).duration === 0 && Face.parse({ duration: "abc" }).duration === 1200
      && Face.parse({ duration: -9 }).duration === 0, "0 stays until closed, a duration that is no number is the default")

    check(Face.parse({ icon: "" }).glyph === Face.iconFor("volume-muted", -1) && Face.parse({ icon: "constructor" }).glyph === "constructor",
      "a name the OSD does not know is shown as it is, one Object has too")

    check(Face.parse({ icon: "Media-Play" }).glyph === Face.iconFor("media-play") && Face.parse({ icon: "Media-Play" }).fromPlayer
      && Face.parse({ icon: "player-next" }).fromPlayer && !Face.parse({ icon: "volume" }).fromPlayer,
      "the icon's name is matched whatever its case, and a player's is known")

    var sizes = { ink: 20.4, widestInk: 25.2, readout: 40.5, words: 30, gap: 16, bar: 142, wordsMax: 190 }
    var level = Face.layout(keys, sizes)
    check(level.ink === 21 && level.column === 26 && level.barX === 42 && level.textX === 200 && level.textWidth === 41
      && level.width === 241, "a level: the icon's column as wide as the widest icon, the bar, the readout")
    sizes.words = 500
    var long = Face.layout(message, sizes)
    check(long.column === 21 && long.textX === 32 && long.textWidth === 190 && long.width === 222,
      "words two thirds of a gap after the icon, cut at their room")
    check(Face.layout(Face.parse({ icon: "keyboard", message: "" }), sizes).width === 21, "an icon alone: its ink")
    console.log("DONE")
    Qt.quit()
  }
}
