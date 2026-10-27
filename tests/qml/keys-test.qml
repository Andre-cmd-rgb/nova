import QtQuick
import Quickshell
import "plugins/services/keys/KeysModel.js" as Model

// The volume, brightness and keyboard backlight keys' steps, as
// nova-audio-output-volume, nova-brightness-display and
// nova-brightness-keyboard take them.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(Model.volumeStep(0.5, 5) === 55 && Model.volumeStep(0.5, -5) === 45, "a volume step up and down, in whole percents")
    check(Model.volumeStep(0.333, 1) === 34, "from PipeWire's fraction, rounded")
    check(Model.volumeStep(0.98, 5) === 100 && Model.volumeStep(0.02, -5) === 0, "no further than 100 or 0")
    check(Model.volumeStep(1.2, 5) === 100 && Model.volumeStep(1.2, -5) === 115, "up stops at 100 even from above; down steps")
    check(Model.volumeStep(undefined, 5) === 5, "an unread volume counts as none")
    check(Model.volumeMore(95, 5) && !Model.volumeMore(100, 5) && !Model.volumeMore(0, -1) && Model.volumeMore(1, -1), "a held volume key stops at either end")
    check(Model.volumeIcon(40, false) === "volume-high" && Model.volumeIcon(40, true) === "volume-muted" && Model.volumeIcon(0, false) === "volume-muted", "struck through, muted or silent")

    check(Model.brightnessStep(50, "up") === 55 && Model.brightnessStep(50, "down") === 45, "brightness by 5")
    check(Model.brightnessStep(3, "up") === 4 && Model.brightnessStep(5, "down") === 4 && Model.brightnessStep(5, "up") === 10, "by 1 at the dim end")
    check(Model.brightnessStep(98, "up") === 100 && Model.brightnessStep(1, "down") === 1 && Model.brightnessStep(1, "down-fine") === 1, "never past 100 or below 1")
    check(Model.brightnessStep(50, "up-fine") === 51 && Model.brightnessStep(30, "max") === 100 && Model.brightnessStep(30, "min") === 1, "by 1 with Alt, all the way with Shift")
    check(Model.brightnessMore(55, "up") && !Model.brightnessMore(100, "up") && !Model.brightnessMore(1, "down-fine") && !Model.brightnessMore(100, "max"), "a held brightness key stops at either end, and Shift's at once")
    check(Model.backlightPercent("150\n", "600\n") === 25 && Model.backlightPercent("", "600") === -1 && Model.backlightPercent("5", "0") === -1, "a backlight's raw value in percent, or unread")
    check(Model.ddcStep("up") === "+5%" && Model.ddcStep("down-fine") === "1%-" && Model.ddcStep("min") === "1%", "an external display's step, as nova-brightness-display-ddc takes it")

    check(Model.keyboardStep(0, 2, "up") === 1 && Model.keyboardStep(2, 2, "up") === 2 && Model.keyboardStep(1, 2, "down") === 0, "a keyboard light of three levels, a level at a time")
    check(Model.keyboardStep(100, 512, "up") === 151 && Model.keyboardStep(30, 512, "down") === 0, "a tenth of a long range, to the top or off")
    check(Model.keyboardStep(1, 2, "cycle") === 2 && Model.keyboardStep(2, 2, "cycle") === 0, "cycle goes round past the top to off")
    check(Model.keyboardMore(1, 2, "up") && !Model.keyboardMore(2, 2, "up") && !Model.keyboardMore(0, 2, "down") && !Model.keyboardMore(1, 2, "cycle"), "a held keyboard key stops at either end, and cycle at once")

    console.log("DONE")
    Qt.quit()
  }
}
