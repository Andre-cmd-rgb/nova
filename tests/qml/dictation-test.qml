import QtQuick
import Quickshell
import "plugins/dictation/DictationModel.js" as Model

// Dictation's decisions: what SUPER + D going down and coming up does in each
// phase, nova-dictationd's lines as the pill reads them, the microphone's
// level and the wave's, and the lines `nova dictation setup --progress`
// prints. Making the words ready to paste and settling them while they are
// said are nova-dictationd's, and tested there (src/dictation).
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

    check(Model.answer('{"type":"listening"}').type === "listening", "nova-dictationd listens")
    var words = Model.answer('{"type":"text","text":"Hola, \\"Ana\\". "}')
    check(words.type === "text" && words.text === 'Hola, "Ana". ', "its words, as they are pasted")
    check(Model.answer('{"type":"text","text":""}').text === "", "nothing heard is words too, none")
    check(Model.answer('{"type":"error","error":"no-model"}').error === "no-model", "and why it could not")
    check(Model.answer("").type === "" && Model.answer("{").type === "" && Model.answer("null").type === ""
      && Model.answer('{"type":"text","text":3}').type === "" && Model.answer('"text"').type === "",
      "a line that is none of those is nothing")

    check(Model.level(0) === 0 && Model.level(-1) === 0 && Model.level(undefined) === 0, "no signal, no bar")
    check(Model.level(1) === 1, "a full-scale peak fills the bar")
    check(Model.level(0.001) === 0, "a room's hum, -60 dB, hardly moves it")
    var speech = Model.level(0.1)
    check(speech > 0.5 && speech < 0.9, "speech at -20 dB is most of the bar: " + speech.toFixed(2))

    check(Model.voice(0.2, 0.9) === 0.9 && Math.abs(Model.voice(0.9, 0) - 0.792) < 1e-9, "the wave rises with the voice at once, and falls slowly")

    check(Model.progress("progress 42") === 42 && Model.progress("progress 100\n") === 100, "the download's percent")
    check(Model.progress("checking") === -1 && Model.progress("progress") === -1 && Model.progress("") === -1, "anything else is not a percent")
    console.log("DONE")
    Qt.quit()
  }
}
