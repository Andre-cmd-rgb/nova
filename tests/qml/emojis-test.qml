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

    var joined = EmojiSearch.parse('[{"e":"😍","k":"smiling face with heart-eyes"},{"e":"👎","k":"thumbs down -1"},{"e":"💯","k":"hundred points 100"}]')
    check(EmojiSearch.search(joined, "heart_eyes", 9).join("") === "😍" && EmojiSearch.search(joined, "Heart-Eyes", 9).join("") === "😍"
      && EmojiSearch.search(joined, "heart eyes", 9).join("") === "😍", "_ and a - between letters are spaces, typed or in the list")
    check(EmojiSearch.search(joined, "-1", 9).join("") === "👎", "a - that joins no words stays one")

    var ranked = EmojiSearch.parse('[{"e":"🥴","k":"woozy face intoxicated"},{"e":"😺","k":"grinning cat"},{"e":"🙀","k":"weary cat"},'
      + '{"e":"🏷️","k":"label (category)"},{"e":"🐱","k":"cat face"}]')
    check(EmojiSearch.search(ranked, "cat", 9).join("") === "😺🙀🏷️🐱🥴",
      "a word that begins with what is typed comes first, then one with it inside, each in the list's order")
    check(EmojiSearch.search(ranked, "cat", 3).join("") === "😺🙀🏷️" && EmojiSearch.search(ranked, "at", 9).join("") === "🥴😺🙀🏷️🐱",
      "the limit counts after the order; inside words only, the list's order")

    var emojis = EmojiSearch.parse(installed.text())
    check(emojis.length > 1800 && emojis.every(function (item) { return item.k.length > 0 }),
      "the installed list: every emoji has words to find it by")
    var finds = function (query, emoji) { return EmojiSearch.search(emojis, query, 1000).indexOf(emoji) !== -1 }
    check(finds("dog", "🐶") && finds("cat", "😺") && finds("heart", "❤️") && finds("thumbs up", "👍")
      && finds("smile", "😄") && finds("italy", "🇮🇹") && finds("technologist", "🧑‍💻"),
      "the installed list finds an emoji by its name")
    check(finds("heart_eyes", "😍") && finds("face_with_tears_of_joy", "😂") && finds("partying_face", "🥳")
      && finds("t-shirt", "👕") && finds("t shirt", "👕"), "and by GitHub's name for it, words joined by _ or -")
    var first = function (query) { return EmojiSearch.search(emojis, query, 1000)[0] }
    check(first("cat") === "😺" && first("lock") === "🔒" && first("rain") === "⛈️" && first("dog") !== "🌭",
      "in the installed list, the first emoji for a word has it as a word")
    console.log("DONE")
    Qt.quit()
  }
}
