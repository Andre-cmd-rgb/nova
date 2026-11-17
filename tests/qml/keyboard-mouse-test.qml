import QtQuick
import Quickshell
import "plugins/settings/KeyboardModel.js" as Model

// The Keyboard & Mouse page's rules: xkb's layouts read from its list, by
// name; the ones found as a name is typed; the chosen ones moved and taken
// out; the keys that switch them; and the pointer's speed in words.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(one, other) {
    return JSON.stringify(one) === JSON.stringify(other)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    // As evdev.lst has them, a model and an option around them.
    const listing = [
      "! model", "  pc105           Generic 105-key PC", "",
      "! layout", "  us              English (US)", "  de              German", "  ru              Russian", "",
      "! variant", "  intl            us: English (US, intl., with dead keys)", "  nodeadkeys      de: German (no dead keys)", "",
      "! option", "  grp:alts_toggle      Both Alts together", ""
    ].join("\n")
    const known = Model.layouts(listing)
    check(same(known.map(k => k.value), ["us", "us:intl", "de", "de:nodeadkeys", "ru"]), "layouts and variants, by name, and no model or option: " + known.map(k => k.value))
    check(known[3].name === "German (no dead keys)", "a variant by its own name")
    check(Model.layouts("").length === 0 && Model.layouts(undefined).length === 0, "no list, no layouts")

    check(Model.nameOf(known, "de:nodeadkeys") === "German (no dead keys)" && Model.nameOf(known, "xx") === "xx", "a layout's name, or its code where xkb has none")

    check(same(Model.matching(known, "german", []).map(k => k.value), ["de", "de:nodeadkeys"]), "found by a word of the name, in any case")
    check(same(Model.matching(known, "us dead", []).map(k => k.value), ["us:intl"]), "every word must match")
    check(same(Model.matching(known, "de:nodeadkeys", []).map(k => k.value), ["de:nodeadkeys"]), "by its code")
    check(same(Model.matching(known, "german", ["de"]).map(k => k.value), ["de:nodeadkeys"]), "and not one chosen already")
    check(Model.matching(known, "", ["us"]).length === 4, "nothing typed: all but those chosen")

    const list = ["us", "de", "ru"]
    check(same(Model.moved(list, 2, -1), ["us", "ru", "de"]) && same(Model.moved(list, 0, 1), ["de", "us", "ru"]), "moved up and down")
    check(same(Model.moved(list, 0, -1), list) && same(Model.moved(list, 2, 1), list) && same(Model.moved(list, 5, 1), list), "not past either end")
    check(same(Model.moved(list, 1, 0), ["us", "ru"]), "a step of none takes it out")
    check(same(list, ["us", "de", "ru"]), "and the list it was given stays as it was")

    const nonLatin = ["ru", "gr"]
    check(same(Model.ahead(["ru", "de"], nonLatin), ["us", "ru", "de"]) && same(Model.ahead(["ru", "de", "us:intl"], nonLatin), ["us:intl", "ru", "de"]),
      "a non-Latin layout first gets US ahead of it: the one among them, else one more")
    check(same(Model.ahead(["de", "ru"], nonLatin), ["de", "ru"]) && same(Model.ahead([], nonLatin), []) && same(Model.ahead(["ru"], undefined), ["ru"]),
      "and none for a Latin one first, or no list")
    check(Model.room(["us", "de"], nonLatin) === 2 && Model.room(["ru", "de", "fr"], nonLatin) === 0 && Model.room(["ru", "us", "fr"], nonLatin) === 1,
      "room for four in all, the US counted")

    check(same(Model.switches("alts").map(s => s.value), ["alts", "alt-shift", "ctrl-shift", "none"]), "the keys Settings offers")
    check(Model.switches("other").slice(-1)[0].label === "Custom", "and one of the user's own, as Custom")

    check(Model.speedText(0) === "Normal" && Model.speedText(0.04) === "Normal" && Model.speedText(-0.3) === "Slower" && Model.speedText(1) === "Faster", "the pointer's speed in words")

    console.log("DONE")
    Qt.quit()
  }
}
