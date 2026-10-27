import QtQuick
import Quickshell
import "plugins/dictation/DictationModel.js" as Model

// Dictation's decisions: what SUPER + D going down and coming up does in each
// phase, the transcript made ready to paste, the microphone's level as a
// bar, and the lines `nova dictation setup --progress` prints.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(Model.onPress("idle") === "start", "a press starts listening")
    check(Model.onPress("message") === "start" && Model.onPress("done") === "start", "and over a message or the check")
    check(Model.onPress("listening") === "finish", "a press while listening finishes, hands-free or not")
    check(Model.onPress("offer") === "setup", "a press over the model's offer downloads it")
    check(Model.onPress("transcribing") === "none" && Model.onPress("downloading") === "none", "a press while working waits")

    check(Model.onRelease("listening", false, 1200) === "finish", "letting go after a hold finishes")
    check(Model.onRelease("listening", false, 120) === "hands-free", "letting go after a tap keeps listening")
    check(Model.onRelease("listening", false, Model.tapMs) === "finish", "a press as long as a tap's limit is a hold")
    check(Model.onRelease("listening", true, 120) === "none", "the release of the press that finished hands-free does nothing")
    check(Model.onRelease("transcribing", false, 1200) === "none" && Model.onRelease("idle", false, 50) === "none", "nor does one with nothing listening")

    check(Model.clean(" And so,  my fellow\nAmericans ") === "And so, my fellow Americans", "one line, single spaces, trimmed")
    check(Model.clean("Ask not what your country can do for you.") === "Ask not what your country can do for you. ", "a finished sentence gets a space for the next")
    check(Model.clean("¿Qué tal?") === "¿Qué tal? " && Model.clean("¡Hola!") === "¡Hola! ", "a question and an exclamation are finished too")
    check(Model.clean("") === "" && Model.clean("  \n ") === "" && Model.clean(null) === "", "silence is nothing to paste")

    check(Model.level(0) === 0 && Model.level(-1) === 0 && Model.level(undefined) === 0, "no signal, no bar")
    check(Model.level(1) === 1, "a full-scale peak fills the bar")
    check(Model.level(0.001) === 0, "a room's hum, -60 dB, hardly moves it")
    var speech = Model.level(0.1)
    check(speech > 0.5 && speech < 0.9, "speech at -20 dB is most of the bar: " + speech.toFixed(2))

    var levels = Model.pushLevel([], 0.5, 4)
    check(JSON.stringify(levels) === "[0,0,0,0.5]", "the first level comes in on the right")
    levels = Model.pushLevel([0.1, 0.2, 0.3, 0.4], 0.5, 4)
    check(JSON.stringify(levels) === "[0.2,0.3,0.4,0.5]", "and the oldest goes out on the left")

    check(Model.progress("progress 42") === 42 && Model.progress("progress 100\n") === 100, "the download's percent")
    check(Model.progress("checking") === -1 && Model.progress("progress") === -1 && Model.progress("") === -1, "anything else is not a percent")

    check(Model.clock(0) === "0:00" && Model.clock(7.9) === "0:07" && Model.clock(102) === "1:42", "the hands-free clock")
    console.log("DONE")
    Qt.quit()
  }
}
