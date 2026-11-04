import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/menu"
import "plugins/menu/MenuModel.js" as MenuModel
import "services/AppSearch.js" as AppSearch

// The menu: a user file's entry changes only what it names, a comma inside a
// string is the string's, comments may stand after entries, a label may be a
// number, an id may be a name JavaScript objects have, a menu its when:
// hides keeps what is under it out of search, a when: bash cannot read or
// that exits answers only for its own row, two apps of one name keep one
// order, a provider's values each get a row, and a chooser still waiting
// when another takes its place is answered as cancelled.
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

  // Search answers with every when: as given, by id.
  function answered(when) {
    return { when: new Map(Object.entries(when)), checked: new Map() }
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    const shipped = MenuModel.readMenuFile('{ "settings": { "label": "Settings", "icon": "S", "action": "nova-settings" } }')
    const mine = MenuModel.readMenuFile('{ "settings": { "icon": "X" }, }')
    const settings = MenuModel.catalogOf(shipped, mine).items.get("settings")
    check(settings.icon === "X" && settings.label === "Settings" && settings.command === "nova-settings"
      && settings.kind === "action", "a user entry naming only an icon keeps the label and action")

    const read = MenuModel.readMenuFile('{\n  // a comment\n  "a": { "label": "x,}", "action": "echo \\"y,]\\" ,]", },\n}')
    check(read.size === 1 && read.get("a").label === "x,}" && read.get("a").action === 'echo "y,]" ,]',
      "a comma inside a string stays, a trailing one goes")

    const commented = MenuModel.readMenuFile('{ "a": { "label": "A" }, // the first\n  /* the second, */ "b": { "label": "B" } /* the end */ }')
    check(commented.size === 2 && commented.get("a").label === "A" && commented.get("b").label === "B",
      "comments after an entry and in blocks leave every entry read")

    const odd = MenuModel.catalogOf(MenuModel.readMenuFile(
      '{ "mine": { "label": 2048, "action": "a" }, "constructor": { "label": "Builder", "action": "b" }, "toString": { "label": "Words", "action": "c" } }'), new Map())
    const found = query => MenuModel.searchRows(odd, "root", query, MenuModel.noAnswers()).map(row => row.key).join(",")
    check(odd.items.get("mine").label === "2048" && found("20") === "mine" && found("m") === "mine",
      "a label written as a number is shown and searched as its text, and spoils no other search")
    check(found("builder") === "constructor" && found("words") === "toString",
      "entries named constructor and toString are listed and found")

    const nested = MenuModel.catalogOf(MenuModel.readMenuFile(
      '{ "tools": { "label": "Tools", "when": "false" }, "tools.hammer": { "label": "Hammer", "action": "a" }, "tools.kit": { "label": "Kit" }, '
      + '"tools.kit.saw": { "label": "Saw", "action": "b" }, "bench": { "label": "Bench" }, "bench.vise": { "label": "Vise", "action": "c" } }'), new Map())
    const seek = (menuId, query, when) => MenuModel.searchRows(nested, menuId, query, answered(when)).map(row => row.key).join(",")
    check(seek("root", "hammer", { tools: false }) === "" && seek("root", "saw", { tools: false }) === "" && seek("root", "vise", { tools: false }) === "bench.vise",
      "search finds nothing under a menu its when: hides, and the rest as before")
    check(seek("root", "hammer", { tools: true }) === "tools.hammer" && seek("root", "saw", { tools: true }) === "tools.kit.saw" && seek("tools", "saw", { tools: false }) === "tools.kit.saw",
      "search finds what is under a menu its when: shows, and within the menu itself")

    const files = [{ id: "org.b.Files", name: "Files" }, { id: "org.a.Files", name: "Files" }, { id: "org.c.Editor", name: "Editor" }]
    const order = entries => AppSearch.sortedEntries(entries, null).map(row => row.entry.id).join(",")
    check(order(files) === "org.c.Editor,org.a.Files,org.b.Files" && order(files.slice().reverse()) === order(files),
      "two apps of one name are listed in one order, whatever order they come in")

    const fonts = MenuModel.providerItems("style.font", "Fira Code\nJetBrains Mono\n  Fira Code  \n\nFira-Code\n", "F", value => "set " + value)
    check(fonts.map(row => row.id + "=" + row.icon + "=" + row.command).join(" ")
      === "style.font.jetbrains-mono=F=set JetBrains Mono style.font.fira-code=✓=set Fira Code style.font.fira-code-=F=set Fira-Code",
      "a provider's values each get a row, the one set now a ✓, and two of one id one each")

    const guarded = MenuModel.catalogOf(MenuModel.readMenuFile(
      '{ "leaving": { "label": "Leaving", "when": "exit 1", "action": "d" }, "staying": { "label": "Staying", "when": "left=1; exit 0", "action": "e" }, '
      + '"here": { "label": "Here", "when": "[[ -z ${left-} ]]", "action": "f" }, "on": { "label": "On", "when": "true", "action": "a" }, "broken": { "label": "Broken", "when": "((( ", "action": "b" }, "it\'s": { "label": "Quoted", "checked": "true", "action": "c" } }'), new Map())
    guards.command = ["bash", "-c", MenuModel.guardScript(guarded)]

    // first: a menu takes its place. second: a chooser, third, which is
    // answered.
    begin("first")
    request.release()
    begin("second")
    begin("third")
    check(request.finish("b") && request.closedPath === "" && !request.finish(null), "an answered request is answered once")
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
        const answers = MenuModel.readAnswers(text)
        test.check(answers.when.get("on") === true && answers.when.get("broken") !== true && answers.checked.get("it's") === true,
          "a when: bash cannot read hides its own row, and leaves the others their answers")
        test.check(answers.when.get("leaving") === false && answers.when.get("staying") === true && answers.when.get("here") === true,
          "a when: that exits or sets a variable answers for its own row alone (" + JSON.stringify(Array.from(answers.when)) + ")")
        console.log("DONE")
        Qt.quit()
      }
    }
  }
}
