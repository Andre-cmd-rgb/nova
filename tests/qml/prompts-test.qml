// platform: wayland
// warns: PeerClosedError
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/prompts" as Prompts
import "plugins/prompts/PromptsModel.js" as Model

// Nova's prompts card, as nova-sessiond's duties talk to it on its socket:
// a passphrase asked, answered, said wrong and asked again on the same card,
// then done; a second dialog waiting for the first, which is cancelled; a
// yes or no with a code; a dialog the duty ends; and what the card reads
// and writes, apart.
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  Prompts.Prompts { id: prompts }

  readonly property string socket: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/prompts.sock"

  // The card's window, made only while a card is shown.
  function surface() {
    return prompts.surface
  }

  function cardShown() {
    return surface() !== null && surface().visible
  }

  function inputs() {
    var found = []
    function walk(item) {
      if (!item) return
      if (item.echoMode !== undefined && item.cursorVisible !== undefined) found.push(item)
      for (var i = 0; i < item.children.length; i++) walk(item.children[i])
    }
    if (surface()) walk(surface().contentItem)
    return found
  }

  function shownText(text) {
    var found = false
    function walk(item) {
      if (!item || !item.visible) return
      if (item.text === text) found = true
      for (var i = 0; i < item.children.length; i++) walk(item.children[i])
    }
    if (surface()) walk(surface().contentItem)
    return found
  }

  // Two duties, each a dialog of its own.
  property var heardA: []
  property var heardB: []

  Socket {
    id: dutyA
    path: test.socket
    parser: SplitParser { onRead: data => test.heardA = test.heardA.concat([data]) }
  }

  Socket {
    id: dutyB
    path: test.socket
    parser: SplitParser { onRead: data => test.heardB = test.heardB.concat([data]) }
  }

  function say(duty, object) {
    duty.write(JSON.stringify(object) + "\n")
    duty.flush()
  }

  readonly property var passphrase: ({
    type: "ask", glyph: "drive", title: "“Backup” is encrypted", text: "", code: "",
    fields: [{ id: "passphrase", label: "Enter passphrase", secret: true, value: "" }], accept: "Unlock"
  })

  property var steps: []
  property int tries: 0

  Timer {
    id: next
    interval: 50
    onTriggered: {
      if (test.steps.length === 0) {
        console.log("DONE")
        Qt.quit()
        return
      }
      if (test.steps[0]() === false && test.tries < 100) {
        test.tries++
      } else {
        if (test.tries >= 100) check(false, "a step that never came true (" + test.steps.length + " left)")
        test.tries = 0
        test.steps.shift()
      }
      next.restart()
    }
  }

  Component.onCompleted: {
    var m = Model.parse
    check(m("not json") === null && m('{"type":"later"}') === null && m("[1]") === null, "a line that is not one the card knows is passed over")
    var many = m(JSON.stringify({ type: "ask", fields: [{ id: "a" }, { id: "a" }, { id: "" }, { id: "b", secret: true }, { id: "c" }, { id: "d" }] }))
    check(many.fields.map(function (f) { return f.id }).join() === "a,b,c" && many.fields[1].secret && !many.fields[0].secret,
      "at most three fields, each with an id of its own, a secret only when it says so")
    check(many.accept === "" && many.title === "" && m('{"type":"wrong"}').text === "", "what an ask leaves out is empty")
    check(Model.answerLine([{ id: "user" }, { id: "password" }], ["me", "p \"w\"\n"]) === '{"type":"answer","values":{"user":"me","password":"p \\"w\\"\\n"}}\n',
      "an answer is one line, whatever is typed")
    check(!Model.answerable([{ id: "a" }], [""]) && Model.answerable([], []) && Model.answerable([{ id: "a" }], ["x"]), "answered with every field filled in, or none")

    steps = [
      // The card listens once its folder is made.
      function () {
        if (dutyA.connected) return true
        dutyA.connected = true
        return false
      },
      function () {
        check(!cardShown(), "no card before a question")
        say(dutyA, passphrase)
      },
      function () { return cardShown() },
      function () {
        check(shownText("“Backup” is encrypted") && shownText("Enter passphrase"), "the question's title on its tab, the field saying what it is for")
        var fields = inputs()
        check(fields.length === 1 && fields[0].echoMode === TextInput.Password, "one field, its text as dots")
        prompts.answer()
        check(test.heardA.length === 0, "an empty field is no answer")
        fields[0].text = "one two "
        prompts.answer()
      },
      function () { return test.heardA.length === 1 },
      function () {
        check(test.heardA[0] === '{"type":"answer","values":{"passphrase":"one two "}}', "the passphrase goes to the duty as typed")
        check(inputs()[0].text === "" && prompts.checking && shownText("Checking..."), "the field is emptied, and says it is checking")
        say(dutyA, { type: "wrong", text: "That passphrase did not open “Backup”." })
      },
      function () { return prompts.wrong },
      function () {
        check(cardShown() && shownText("That passphrase did not open “Backup”.") && shownText("Wrong"), "a wrong answer: the card stays, and says so")
      },
      function () { return !prompts.wrong },
      function () {
        inputs()[0].text = "right"
        prompts.answer()
      },
      function () { return test.heardA.length === 2 },
      function () {
        check(test.heardA[1] === '{"type":"answer","values":{"passphrase":"right"}}', "and is answered again on the same card")
        say(dutyA, { type: "done" })
      },
      function () { return !cardShown() },
      function () { return !dutyA.connected },
      function () {
        check(true, "done: the card goes, and the dialog closes")
        dutyA.connected = true
        dutyB.connected = true
      },
      function () { return dutyA.connected && dutyB.connected },
      function () {
        say(dutyA, passphrase)
        say(dutyB, { type: "ask", glyph: "bluetooth", title: "Pair with “Pixel 8”", text: "Does “Pixel 8” show this code?", code: "123456", fields: [], accept: "Pair" })
      },
      function () { return cardShown() && prompts.dialogs.length === 2 },
      function () {
        check(shownText("“Backup” is encrypted") && !shownText("123456"), "a second dialog waits for the first")
        prompts.cancel()
      },
      function () { return test.heardA.length === 3 && !dutyA.connected },
      function () {
        check(test.heardA[2] === '{"type":"cancel"}', "Escape cancels: the duty is told, and the dialog closes")
      },
      function () { return shownText("123456") },
      function () {
        check(shownText("Pair with “Pixel 8”") && shownText("Does “Pixel 8” show this code?") && shownText("Pair") && shownText("Cancel"),
          "then the next: a code to compare, and the answers Cancel and the duty's")
        check(inputs().length === 0, "a yes or no has no field")
        prompts.choose(1)
      },
      function () { return test.heardB.length === 1 },
      function () {
        check(test.heardB[0] === '{"type":"answer","values":{}}', "the duty's answer is an answer with nothing typed")
        check(shownText("Checking..."), "and says it is checking")
        // The duty ends the dialog itself, as when the device calls the pairing off.
        dutyB.connected = false
      },
      function () { return !cardShown() },
      function () {
        check(prompts.dialogs.length === 0, "a dialog its duty closed ends, and the card goes")
        dutyA.connected = true
      },
      function () { return dutyA.connected },
      function () {
        say(dutyA, { type: "ask", glyph: "bluetooth", title: "Pair with “MX Keys”", text: "Type this code on “MX Keys”, then Return.", code: "482913", fields: [] })
      },
      function () { return cardShown() },
      function () {
        check(shownText("482913") && shownText("Cancel") && !shownText("Done") && !shownText("OK"), "a code to type on the other device: Cancel alone")
        prompts.choose(1)
        check(test.heardA.length === 3, "and nothing to answer but Cancel")
        prompts.cancel()
      },
      function () { return test.heardA.length === 4 },
      function () {
        check(test.heardA[3] === '{"type":"cancel"}', "which cancels")
        check(m(JSON.stringify({ type: "ask", choices: [{ id: "a" }, { id: "a" }, { id: "b" }], chosen: "z", toggles: [{ id: "choice" }, { id: "t", value: true }] })).chosen === "a",
          "a list keeps each id once, and chooses the first when what is chosen is not in it")
        check(m(JSON.stringify({ type: "ask", toggles: [{ id: "choice" }, { id: "t", value: true }] })).toggles.map(function (t) { return t.id + t.value }).join() === "ttrue",
          "a switch may not take the choice's name")
        check(m('{"type":"ask","alone":true}').alone === false && m('{"type":"ask"}').cancel === "Cancel", "a message needs its one answer; Cancel is Cancel unless the duty says")
        dutyA.connected = true
      },
      function () { return dutyA.connected },
      function () {
        say(dutyA, { type: "ask", glyph: "share", title: "Share your screen", text: "", code: "", fields: [], accept: "Share", cancel: "Not Now",
          choices: [{ id: "screen:eDP-1", label: "Built-in display", detail: "2560 × 1600", glyph: "monitor", section: "Screens" },
                    { id: "screen:DP-1", label: "Dell U2723QE", detail: "3840 × 2160", glyph: "monitor", section: "Screens" },
                    { id: "window:93", label: "Notes", detail: "foot", glyph: "window", section: "Windows" }],
          chosen: "screen:DP-1", toggles: [{ id: "remember", label: "Allow it again without asking", value: false }] })
      },
      function () { return cardShown() && shownText("Dell U2723QE  ·  3840 × 2160") },
      function () {
        check(shownText("Screens") && shownText("Windows") && shownText("Notes  ·  foot"), "a list in sections, each named once")
        check(shownText("Not Now") && shownText("Share") && shownText("Allow it again without asking"), "Cancel in the duty's words, its answer, and the switch")
        check(prompts.chosenId === "screen:DP-1", "what the duty chose is chosen")
        prompts.chooseNext(1)
        prompts.chooseNext(1)
        check(prompts.chosenId === "window:93", "the arrows go down the list, and stop at its end")
        prompts.chooseNext(-1)
        prompts.flip(0)
        prompts.choose(1)
      },
      function () { return test.heardA.length === 5 },
      function () {
        check(test.heardA[4] === '{"type":"answer","values":{"choice":"screen:DP-1","remember":"true"}}', "the answer is the choice and the switch")
        say(dutyA, { type: "done" })
      },
      function () { return !dutyA.connected },
      function () { dutyA.connected = true },
      function () { return dutyA.connected },
      function () {
        say(dutyA, { type: "ask", glyph: "key", title: "Passphrase", text: "The key was imported.", code: "", fields: [], accept: "OK", alone: true })
      },
      function () { return cardShown() && shownText("The key was imported.") },
      function () {
        check(shownText("OK") && !shownText("Cancel"), "a message has its one answer")
        prompts.cancel()
      },
      function () { return test.heardA.length === 6 },
      function () {
        check(test.heardA[5] === '{"type":"answer","values":{}}', "and Escape gives it")
      }
    ]
    next.start()
  }
}
