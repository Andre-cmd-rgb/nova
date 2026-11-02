import QtQuick
import Quickshell
import "plugins/osd/OsdModel.js" as OsdModel

// What the OSD makes of a request: a level and its readout, a message, and
// how long it stays, from the strings nova-osd sends and the numbers the
// shell's keys and panels do.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var keys = OsdModel.parse({ icon: "volume", value: 40 })
    check(keys.hasProgress && keys.value === 40 && keys.message === "40%" && keys.duration === 1200
      && keys.icon === OsdModel.iconFor("volume-high", 40), "a level from the keys: its readout, the speaker, 1.2 s")

    var cli = OsdModel.parse({ icon: "", message: "", value: "20", progressText: "20%", max: "100", duration: "" })
    check(cli.hasProgress && cli.value === 20 && cli.message === "20%" && cli.icon === OsdModel.iconFor("volume-low", 20),
      "nova-osd -p 20: every field a string, no icon, the speaker with one wave")

    check(OsdModel.parse({ value: 150, max: 100 }).value === 100 && OsdModel.parse({ value: -5 }).value === 0,
      "a level is kept within 0 and its maximum")

    var message = OsdModel.parse({ icon: "microphone-muted", message: "Microphone muted", value: 30 })
    check(!message.hasProgress && message.message === "Microphone muted", "a message wins over a level")

    check(OsdModel.parse({ duration: 0 }).duration === 0 && OsdModel.parse({ duration: "abc" }).duration === 1200
      && OsdModel.parse({ duration: -9 }).duration === 0, "0 stays until closed, a duration that is no number is the default")

    check(OsdModel.parse({ icon: "" }).icon === "" && OsdModel.parse({ icon: "constructor" }).icon === "constructor",
      "a name the OSD does not know is shown as it is, one Object has too")

    check(OsdModel.parse({ icon: "Media-Play" }).iconKey === "media-play", "the icon's name is matched whatever its case")
    console.log("DONE")
    Qt.quit()
  }
}
