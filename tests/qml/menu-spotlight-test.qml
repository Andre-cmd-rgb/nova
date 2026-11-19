// platform: wayland
// stub: bin/qalc qalc
// stub: bin/wl-copy record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/menu"
import "plugins/calculator/Calculator.js" as Calculator
import "plugins/menu/MenuModel.js" as MenuModel

// What the menu's search answers besides apps and menus: a sum or a
// conversion, put the way qalc reads it, its answer read back, and the menu
// with a stand-in qalc: one run for a sum typed fast, none for a word, the
// answer first with the cursor on it, the one before kept while the next is
// worked out, and Return copying it with a plain minus, the new one once it
// comes, Ctrl+Return opening it in the Calculator. And Settings' pages,
// which Nova's menu.jsonc offers to a search under the words their pages
// are called by.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  Menu { id: menu }

  FileView { id: callsFile; path: test.home + "/stub-calls"; blockAllReads: true; printErrors: false }
  FileView { id: runsFile; path: test.home + "/qalc-calls"; blockAllReads: true; printErrors: false }
  FileView {
    id: shippedMenu
    path: Quickshell.env("TEST_PLUGINS") + "/../../default/menu.jsonc"
    blockLoading: true
  }

  function lines(file) {
    file.reload()
    return file.text().trim().split("\n").filter(Boolean)
  }

  // <next> once <ready> holds, looked at every 50 ms for up to 5 s.
  function when(ready, next, what) {
    waiter.ready = ready
    waiter.next = next
    waiter.what = what
    waiter.tries = 0
    waiter.restart()
  }

  Timer {
    id: waiter
    property var ready: null
    property var next: null
    property string what: ""
    property int tries: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (ready()) {
        stop()
        next()
      } else if (++tries > 100) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(sums)

  function sums() {
    const asked = {
      "2*(3+4)": "2*(3+4)", "15% of 80": "15% × 80", "50 % of 200": "50 % × 200",
      "5 km in miles": "5 km to -miles", "10 kg to lb": "10 kg to -lb", "12 in to cm": "12 in to -cm",
      "60 mph in km/h": "60 mph to -km/h", "72 f in c": "72 °F to -°C", "72°F to °C": "72 °F to -°C",
      "300 k to c": "300 K to -°C", "-40 C IN F": "-40 °C to -°F","255 to hex": "255 to hex",
      "2 x 3": "2 × 3", "  2+2 = ": "2+2", "-5 - 2": "-5 - 2", "sqrt(2)": "sqrt(2)", "100 usd to eur": "100 usd to -eur"
    }
    const wrong = Object.keys(asked).filter(query => Calculator.expression(query) !== asked[query])
    check(wrong.length === 0, "sums and conversions are put qalc's way: in for to, one unit, the scales' letters, % of, x (" + wrong.map(query => query + " → " + Calculator.expression(query)).join("; ") + ")")
    const words = ["firefox", "2024", "3.5", "1,000", "report 2024", "IMG_2024.jpg", "2024-11-17 notes", "~/notes 2",
      "ms 2024", "notes in 2024", "5g", "$100 to eur", "what's 2+2?", "pi"]
    const taken = words.filter(query => Calculator.expression(query) !== "")
    check(taken.length === 0, "a word, a number alone, a file's name, a date, a path or money is no sum (" + taken.join("; ") + ")")
    const words2 = Calculator.command("-5 - 2")
    check(words2[words2.length - 1] === " -5 - 2" && Calculator.command("2+2").slice(0, 5).join(" ") === "qalc -defaults -nocurrencies -set limimpl 1"
      && Calculator.command("2+2").indexOf("-time") > 0, "qalc runs with its own settings, no currencies, unknown words as errors, a time limit, and a minus that is no option")

    const read = (printed, expression) => {
      const found = Calculator.answer(printed, expression || "")
      return found ? found.label + "|" + found.copy : "none"
    }
    check(read("2 × (3 + 4) = 14\n") === "14|14" && read("10 / 4 = 5/2 = 2 + 1/2 = 2.5") === "2.5|2.5"
      && read("5 kilometers ≈ 3.106855961 mi") === "3.106855961 mi|3.106855961 mi" && read("60 mph = 96.56064 km/h") === "96.56064 km/h|96.56064 km/h"
      && read("2^64 ≈ 1.844674407E19") === "1.844674407E19|1.844674407E19" && read("(−5) − 2 = −7") === "−7|-7"
      && read("255 = 0xFF", "255 to hex") === "0xFF|0xFF",
      "the answer is the last step, a unit kept, copied with a plain minus; a base's digits too")
    const refused = ["error: \"x\" is not a valid variable/function/unit.\n0 = 0", "warning: Misplaced operator(s) \"+\" ignored\n2 = 2",
      "are − 1 = 1 a − 1", "2 × x × 3 = 6x", "now + (1 day) ≈ \"2026-11-18T16:09:10\"", "[2  (5 + 1)] = [2  6]", "5 m − 3 kg = 5 m − 3 kg",
      "", "14"].filter(printed => Calculator.answer(printed, "") !== null)
    check(refused.length === 0, "an error, a warning, an expression left over, a date or a vector is no answer (" + refused.join("; ") + ")")
    const row = MenuModel.answerRows({ label: "−7", copy: "-7" })
    check(row.length === 1 && row[0].kind === "answer" && row[0].label === "−7" && row[0].command === "wl-copy -- '-7'"
      && MenuModel.answerRows(null).length === 0, "an answer is one row, whose command copies it")

    settings()
  }

  // Settings' pages in Nova's menu.jsonc, found by their names and a few
  // other words, each under Settings, and before Update's rows of the same
  // name; one this computer has not got is not offered.
  function settings() {
    const catalog = MenuModel.catalogOf(MenuModel.readMenuFile(shippedMenu.text()), new Map())
    const first = (query, when) => {
      const rows = MenuModel.searchRows(catalog, "root", query, { when: new Map(Object.entries(when || {})), checked: new Map() })
      return rows.length ? rows[0].key + "|" + rows[0].line : ""
    }
    const pages = { "bluetooth": "bluetooth", "wi-fi": "wifi", "wifi": "wifi", "displays": "displays", "display": "displays",
      "battery": "battery", "volume": "sound", "trackpad": "keyboard", "dark mode": "appearance", "keyboard": "keyboard" }
    const wrong = Object.keys(pages).filter(query => first(query) !== "settings." + pages[query] + "|Settings")
    check(wrong.length === 0, "a search for a page's name or another word for it offers that Settings page first (" + wrong.map(query => query + " → " + first(query)).join("; ") + ")")
    check(first("bluetooth", { "settings.bluetooth": false }) === "update.restart.bluetooth|Update › Restart",
      "a page this computer has not got is not offered")
    // Limine's snapshot restore has "subvolume" among its keywords.
    const restore = { id: "limine-snapper-restore", keywords: ["snapshot", "restore", "btrfs", "subvolume"], icon: "" }
    const library = {
      sortedEntries: () => [{ entry: restore }],
      entrySubtext: entry => "",
      entryName: entry => "Limine-snapper-restore"
    }
    const withRestore = MenuModel.withApps(catalog, MenuModel.appItems(library))
    const top = MenuModel.searchRows(withRestore, "root", "volume", MenuModel.noAnswers())
    check(top.length > 1 && top[0].key === "settings.sound" && top.some(row => row.key === "apps.limine-snapper-restore"),
      "a word for a page goes ahead of an app that has it only inside a word of its own (" + top.map(row => row.key).join(", ") + ")")
    check(catalog.items.get("settings.wifi").command === "nova-settings wifi" && MenuModel.menuRows(catalog, "root", MenuModel.noAnswers(), false).every(row => !row.key.startsWith("settings.")),
      "a page opens Settings at it, and the menu itself lists none of them")

    // What closes every app asks first: an Enter on a search opens the
    // question, and only the row under it does it.
    const closesAll = ["nova-system-logout", "nova-system-reboot", "nova-recovery", "nova-system-shutdown"]
    const doing = Array.from(catalog.items.values()).filter(item => closesAll.includes(item.command))
    const found = ["restart", "reboot", "recovery", "shut down", "log out", "power"].filter(query =>
      MenuModel.searchRows(catalog, "root", query, MenuModel.noAnswers()).some(row => closesAll.includes(catalog.items.get(row.key).command)))
    check(doing.length === 4 && found.length === 0,
      "a restart, a shutdown and a log out are never a search's row (" + found.join(", ") + ")")
    const asks = id => {
      const rows = MenuModel.menuRows(catalog, id, MenuModel.noAnswers(), false)
      return catalog.items.get(id).kind === "menu" && rows.length === 1 && rows[0].key === id + ".now"
    }
    check(["system.reboot", "system.recovery", "system.shutdown", "system.logout"].every(asks)
      && first("restart to recovery") === "system.recovery|System" && first("shut down") === "system.shutdown|System",
      "each is a question in System, with the one row that does it")

    menu.open("{}")
    menu.filter("2*(3+4)")
    check(menu.calculating && menu.rows.length === 0, "a sum's answer is a moment coming, meanwhile without a word of no matches")
    when(() => menu.rows.length === 1, answered, "a sum is answered")
  }

  function answered() {
    const runs = lines(runsFile)
    check(menu.rows[0].kind === "answer" && menu.rows[0].label === "14" && menu.cursor === 0 && !menu.calculating,
      "the answer is the first row, and the cursor is on it")
    check(runs.length === 1 && runs[0] === "2*(3+4)|C.UTF-8|" + Quickshell.env("XDG_RUNTIME_DIR") + "/nova/calculator",
      "qalc ran once, in English, writing only into the runtime folder (" + runs.join("; ") + ")")
    menu.press({ key: Qt.Key_Return, modifiers: Qt.NoModifier, text: "\r" })
    when(() => lines(callsFile).length === 1, copied, "Return copies the answer")
  }

  function copied() {
    check(lines(callsFile)[0] === "wl-copy -- 14" && !menu.opened, "Return copies the answer, and the menu closes")
    menu.open("{}")
    for (const typed of ["1", "12", "12*", "12*3"]) menu.filter(typed)
    menu.filter("firefox")
    menu.filter("12*3")
    when(() => menu.rows.length === 1, fast, "a sum typed fast is answered")
  }

  function fast() {
    const runs = lines(runsFile).map(line => line.split("|")[0])
    check(runs.length === 2 && runs[1] === "12*3" && menu.rows[0].label === "36",
      "a sum typed fast is one run of qalc, and a word none (" + runs.join("; ") + ")")
    menu.filter("5 km in miles")
    when(() => menu.rows.length === 1 && menu.rows[0].label !== "36", conversion, "a conversion is answered")
  }

  function conversion() {
    check(menu.rows[0].label === "3.106855961 mi", "a conversion is answered in the unit asked for")
    const runs = lines(runsFile).length
    menu.filter("12*3")
    check(!menu.calculating && menu.rows.length === 1 && menu.rows[0].label === "36" && lines(runsFile).length === runs,
      "a sum worked out earlier in the same search is answered at once, without qalc")
    menu.filter("12*3x")
    when(() => !menu.calculating, () => {
      check(menu.rows.length === 0, "a sum qalc cannot work out has no row, and leaves none of the last")
      menu.filter("-5 - 2")
      when(() => menu.rows.length === 1, () => {
        check(menu.rows[0].label === "−7", "an answer below zero shows its minus")
        menu.press({ key: Qt.Key_Return, modifiers: Qt.NoModifier, text: "\r" })
        when(() => lines(callsFile).length === 2, () => {
          check(lines(callsFile)[1] === "wl-copy -- -7", "and is copied with a plain one")
          awaited()
        }, "Return copies a negative answer")
      }, "a sum with a leading minus is answered")
    }, "qalc says no to a sum it cannot work out")
  }

  // While the sum typed since is worked out, the answer before stays, so
  // the row does not blink at each key; Return then waits for the new
  // answer and copies that. A search that was no sum in between leaves none
  // to show.
  function awaited() {
    menu.open("{}")
    menu.filter("12*3")
    when(() => menu.rows.length === 1 && !menu.calculating, () => {
      menu.filter("firefox")
      menu.filter("5 km in miles")
      check(menu.calculating && menu.rows.length === 0, "a word in between leaves no answer before to show")
      when(() => menu.rows.length === 1 && !menu.calculating, () => {
        menu.filter("2*(3+4)")
        check(menu.calculating && menu.rows.length === 1 && menu.rows[0].label === "3.106855961 mi" && menu.cursor === 0,
          "while the next sum is worked out, the answer before stays, with the cursor on it")
        menu.press({ key: Qt.Key_Return, modifiers: Qt.NoModifier, text: "\r" })
        check(menu.opened && lines(callsFile).length === 2, "Return meanwhile copies nothing yet")
        when(() => lines(callsFile).length === 3, () => {
          check(lines(callsFile)[2] === "wl-copy -- 14" && !menu.opened, "and copies the new answer once it comes")
          calculator()
        }, "Return copies the answer that came")
      }, "a conversion is answered again")
    }, "a sum is answered again")
  }

  // Ctrl+Return on the answer opens the sum in the Calculator, as it was
  // typed, and closes the menu; with no answer under the cursor it does
  // nothing.
  function calculator() {
    const summoned = []
    menu.shell = { appLibrary: null, summon: (id, payload) => summoned.push(id + " " + payload) }
    menu.open("{}")
    menu.filter("12*3")
    when(() => menu.rows.length === 1 && !menu.calculating, () => {
      menu.press({ key: Qt.Key_Return, modifiers: Qt.ControlModifier, text: "\r" })
      check(summoned.length === 1 && summoned[0] === 'nova.calculator {"expression":"12*3"}' && !menu.opened && lines(callsFile).length === 3,
        "Ctrl+Return on the answer opens the sum in the Calculator, copies nothing, and closes the menu (" + summoned.join("; ") + ")")
      menu.open("{}")
      menu.filter("settings")
      menu.press({ key: Qt.Key_Return, modifiers: Qt.ControlModifier, text: "\r" })
      check(summoned.length === 1 && menu.opened, "with no answer under the cursor, Ctrl+Return does nothing")
      angles()
    }, "12*3 is answered again")
  }

  // Angles are in the Calculator's unit, as its window keeps it, so that a
  // sum opened there with Ctrl+Return is the same: degrees, as the
  // Calculator starts, and radians once it is turned to them.
  function angles() {
    menu.filter("sin(30)")
    when(() => menu.rows.length === 1 && menu.rows[0].label === "0.5", () => {
      // The Calculator turned to radians, a file it had not written before.
      menu.filter("")
      kept.running = true
    }, "sin(30) is in degrees, as the Calculator starts")
  }

  Process {
    id: kept
    command: ["sh", "-c", 'mkdir -p "${1%/*}" && printf "%s\\n" "$2" >"$1"', "sh",
      (Quickshell.env("XDG_STATE_HOME") || test.home + "/.local/state") + "/nova/calculator.json",
      JSON.stringify({ mode: "scientific", angle: "rad" })]
    onExited: {
      menu.filter("sin(30)")
      test.when(() => menu.rows.length === 1 && menu.rows[0].label === "−0.9880316241", test.finish,
        "the Calculator turned to radians, a sum in the menu is worked out in them")
    }
  }
}
