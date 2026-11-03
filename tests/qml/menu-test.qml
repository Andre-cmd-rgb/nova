import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/menu"
import "plugins/menu/MenuModel.js" as MenuModel

// The menu: a user file's entry changes only what it names, a comma inside a
// string is the string's, comments may stand after entries, a label may be a
// number, an id may be a name JavaScript objects have, a when: bash cannot
// read hides only its own row, and a chooser still waiting when another
// takes its place is answered as cancelled.
ShellRoot {
  id: test

  property string dir: Quickshell.env("HOME")

  ChooserRequest { id: request }

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function begin(name) {
    request.begin(dir + "/" + name + ".selection", dir + "/" + name + ".done")
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var defaults = MenuModel.parseMenuJsonc('{ "settings": { "label": "Settings", "icon": "S", "action": "nova-settings" } }')
    var user = MenuModel.parseMenuJsonc('{ "settings": { "icon": "X" }, }')
    var settings = MenuModel.mergeMenuSources(defaults, user).items.settings
    check(settings.icon === "X" && settings.label === "Settings" && settings.action === "nova-settings"
      && settings.kind === "action", "a user entry naming only an icon keeps the label and action")

    var parsed = MenuModel.parseMenuJsonc('{\n  // a comment\n  "a": { "label": "x,}", "action": "echo \\"y,]\\" ,]", },\n}')
    check(parsed.length === 1 && parsed[0].label === "x,}" && parsed[0].action === 'echo "y,]" ,]',
      "a comma inside a string stays, a trailing one goes")

    var commented = MenuModel.parseMenuJsonc('{ "a": { "label": "A" }, // the first\n  /* the second, */ "b": { "label": "B" } /* the end */ }')
    check(commented.length === 2 && commented[0].label === "A" && commented[1].label === "B",
      "comments after an entry and in blocks leave every entry read")

    var odd = MenuModel.mergeMenuSources(MenuModel.parseMenuJsonc(
      '{ "mine": { "label": 2048, "action": "a" }, "constructor": { "label": "Builder", "action": "b" }, "toString": { "label": "Words", "action": "c" } }'), [])
    function found(query) { return MenuModel.searchRows(odd, "root", query, {}, {}).map(function(row) { return row.itemId }).join(",") }
    check(odd.items.mine.label === "2048" && found("20") === "mine" && found("m") === "mine",
      "a label written as a number is shown and searched as its text, and spoils no other search")
    check(found("builder") === "constructor" && found("words") === "toString",
      "entries named constructor and toString are listed and found")

    var guarded = MenuModel.mergeMenuSources(MenuModel.parseMenuJsonc(
      '{ "on": { "label": "On", "when": "true", "action": "a" }, "broken": { "label": "Broken", "when": "((( ", "action": "b" }, "it\'s": { "label": "Quoted", "checked": "true", "action": "c" } }'), [])
    guards.command = ["bash", "-c", MenuModel.guardScript(guarded.items)]

    // first: a menu takes its place. second: a chooser, third, which is
    // answered.
    begin("first")
    request.release()
    begin("second")
    begin("third")
    check(request.finish("b") && !request.active && !request.finish(null), "an answered request is answered once")
    answers.running = true
  }

  Process {
    id: answers
    command: ["bash", "-c", 'sleep 1; cd "$1" && for f in first second third; do printf "%s:%s:%s " "$f" "$([ -e "$f.done" ] && echo done)" "$(cat "$f.selection" 2>/dev/null)"; done', "bash", test.dir]
    stdout: StdioCollector {
      onStreamFinished: {
        test.check(text === "first:done: second:done: third:done:b ",
          "a request another takes the place of is answered as cancelled, the last with its pick (" + text + ")")
        guards.running = true
      }
    }
  }

  Process {
    id: guards
    stdout: StdioCollector {
      onStreamFinished: {
        var answers = MenuModel.readGuards(text)
        test.check(answers.when.on === true && answers.when.broken !== true && answers.checked["it's"] === true,
          "a when: bash cannot read hides its own row, and leaves the others their answers")
        console.log("DONE")
        Qt.quit()
      }
    }
  }
}
