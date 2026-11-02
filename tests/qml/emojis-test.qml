import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/emojis/EmojiSearch.js" as EmojiSearch

// The emoji picker's search: how it reads emojis.json, what a query finds,
// and that the installed list finds what people look for by name.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  FileView {
    id: installed
    path: Quickshell.env("TEST_PLUGINS") + "/emojis/emojis.json"
    blockLoading: true
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(EmojiSearch.parse("").length === 0 && EmojiSearch.parse("{").length === 0
      && EmojiSearch.parse('{"e":"x"}').length === 0, "a list that is missing, broken or no list is empty")

    var list = EmojiSearch.parse('[{"e":"🐶","k":"Dog Face pet"},{"k":"no emoji"},null,{"e":"🐱"},{"e":"🐕","k":"dog"}]')
    check(list.length === 3 && list[0].k === "dog face pet" && list[1].k === "",
      "entries without an emoji are left out, the words are lower-cased")

    check(EmojiSearch.search(list, "", 1000).join("") === "🐶🐱🐕", "nothing typed: every emoji, in the list's order")
    check(EmojiSearch.search(list, "  DOG ", 1000).join("") === "🐶🐕", "what is typed is trimmed and matched whatever its case")
    check(EmojiSearch.search(list, "og fa", 1000).join("") === "🐶", "a match is anywhere in the words, across a space")
    check(EmojiSearch.search(list, "", 2).join("") === "🐶🐱" && EmojiSearch.search(list, "dog", 1).join("") === "🐶",
      "no more than the limit")

    var emojis = EmojiSearch.parse(installed.text())
    check(emojis.length > 1800 && emojis.every(function (item) { return item.k.length > 0 }),
      "the installed list: every emoji has words to find it by")
    var finds = function (query, emoji) { return EmojiSearch.search(emojis, query, 1000).indexOf(emoji) !== -1 }
    check(finds("dog", "🐶") && finds("cat", "😺") && finds("heart", "❤️") && finds("thumbs up", "👍")
      && finds("smile", "😄") && finds("italy", "🇮🇹") && finds("technologist", "🧑‍💻"),
      "the installed list finds an emoji by its name")
    console.log("DONE")
    Qt.quit()
  }
}
