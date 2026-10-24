import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/menu"
import "plugins/menu/MenuModel.js" as MenuModel

// The menu: a user file's entry changes only what it names, a comma inside a
// string is the string's, and a chooser still waiting when another takes its
// place is answered as cancelled.
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
        console.log("DONE")
        Qt.quit()
      }
    }
  }
}
