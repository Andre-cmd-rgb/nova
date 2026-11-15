import QtQuick
import Quickshell
import "plugins/dictation/DictationModel.js" as Model

// Dictation's decisions: what SUPER + D going down and coming up does in each
// phase, the transcript made ready to paste without its fillers and
// stutters, the sentences settled while it listens, the microphone's level
// and the wave's, and the lines `nova dictation setup --progress` prints.
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

    check(Model.clean("I have an appointment at at 6 and and then I I see.") === "I have an appointment at 6 and then I see. ", "a stuttered word is said once")
    check(Model.clean("I, I think so.") === "I think so. ", "and so is one with a comma between")
    check(Model.clean("Um, so we went, uh, home.") === "So we went home. ", "fillers go, with their commas, and pass a sentence's capital on")
    check(Model.clean("I went home, um.") === "I went home. ", "and a full stop back")
    check(Model.clean("Ehm, allora ci vediamo alle cinque.") === "Allora ci vediamo alle cinque. ", "in Italian too")
    check(Model.clean("Eh? What did you say?") === "Eh? What did you say? ", "\"Eh?\" is a question, and stays")
    check(Model.clean("That that is fine, I had had enough. No no no, very very good.") === "That that is fine, I had had enough. No no no, very very good. ", "words said twice on purpose stay")
    check(Model.clean("It is 2 2 km away.") === "It is 2 2 km away. " && Model.clean("um") === "", "and so do numbers; a filler alone is nothing")

    var look = Model.parseLook("end 21.40\npiece 8.80 sentence My fellow Americans, this day has come.\npiece 11.44 soft At nine o'clock,\nrest mission control")
    check(look.end === 21.4 && look.pieces.length === 2 && look.pieces[0].at === 8.8 && look.pieces[1].kind === "soft"
      && look.pieces[1].text === "At nine o'clock," && look.rest === "mission control", "a look's answer: its end, its pieces and the rest")
    check(Model.lookText(look) === "My fellow Americans, this day has come. At nine o'clock, mission control", "a look's words, all of them")
    check(Model.parseLook("end 1.20\nrest ").rest === "" && Model.lookText(Model.parseLook("end 1.20\nrest ")) === "", "a look that heard nothing")
    check(look.whole && !Model.parseLook("").whole && !Model.parseLook("end 21.40\npiece 8.80 sentence Cut.").whole && !Model.parseLook("rest a").whole,
      "an answer is whole from its end line to its rest line")
    check(Model.useful({ from: 0, until: 20 }, look) && !Model.useful({ from: 0, until: 22 }, look) && !Model.useful({ from: 21.4, until: 0 }, look)
      && !Model.useful({ from: 0, until: 0 }, Model.parseLook("")), "a look is of use only whole and newer than what was heard")

    var heard = Model.unheard()
    heard = Model.settle(heard, look)
    check(heard.text === "" && heard.from === 0 && heard.last === look && heard.tail === Model.lookText(look) && heard.until === 21.4,
      "one look settles nothing: there is nothing to agree with yet")
    var again = Model.parseLook("end 23.00\npiece 8.84 sentence My fellow Americans, this day has come.\npiece 11.40 soft At nine o'clock,\nrest mission control in Houston")
    heard = Model.settle(heard, again)
    check(heard.text === "My fellow Americans, this day has come." && heard.from === 8.84 && heard.last === null
      && heard.tail === "At nine o'clock, mission control in Houston" && heard.until === 23,
      "two looks agreeing on a sentence settle it, cut where the newer one says; a comma waits")
    var thinking = Model.settle({ text: "", from: 0, last: Model.parseLook("end 9.00\npiece 4.10 sentence I have an appointment at.\nrest Five.") },
      Model.parseLook("end 11.00\nrest I have an appointment at five. With the doctor"))
    check(thinking.text === "" && thinking.from === 0, "a full stop at a pause to think, gone once the sentence went on, settles nothing")
    var abbreviated = Model.parseLook("end 9.00\npiece 3.00 sentence I saw Dr.\nrest Smith today")
    check(Model.settle({ text: "", from: 0, last: abbreviated }, abbreviated).text === "", "\"Dr.\" is not a sentence's end")
    var long = Model.parseLook("end 30.00\npiece 14.00 soft We talked about the trip, the hotel and the flights,\nrest and then")
    check(Model.settle({ text: "", from: 0, last: long }, long).text === "We talked about the trip, the hotel and the flights,"
      && Model.settle({ text: "", from: 10, last: long }, long).text === "", "a comma will do once the part is " + Model.softAfter + " s long, not before")

    check(Model.join("", "Hello.") === "Hello." && Model.join("Done.", "Next one.") === "Done. Next one.", "a sentence after a sentence")
    check(Model.join("At nine o'clock this morning,", "Mission control lost contact.") === "At nine o'clock this morning, mission control lost contact.",
      "after a cut at a comma, the next part goes on in lower case")
    check(Model.join("I said,", "I think.") === "I said, I think." && Model.join("Hello,", "NASA said.") === "Hello, NASA said."
      && Model.join("and,", "Dr. Smith came.") === "and, Dr. Smith came." && Model.join("a crew of seven,", "Lieutenant Colonel Anderson.") === "a crew of seven, Lieutenant Colonel Anderson.",
      "what looks like a name keeps its capital")

    check(Model.heardAll({ until: 30 }, 29.5) && !Model.heardAll({ until: 30 }, 29.7) && !Model.heardAll({ until: 0 }, 0),
      "the newest look heard it all when the voice stopped before it, with time to spare")

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
