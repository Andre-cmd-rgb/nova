import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "../calculator" as Calc
import "../calculator/Calculator.js" as Calculator
import "MenuModel.js" as MenuModel

// Where the menu's items come from: Nova's menu.jsonc with the user's laid
// over it, each read again when it changes; the apps of the shell's
// library and the rows of the two bash providers, added to a menu as it is
// first shown or searched; the answers of every when: and checked:; and
// qalc's answer to a sum typed.
Item {
  id: source

  // The shell's AppLibrary, once the shell has set it.
  required property var apps

  // The catalog (MenuModel.js): none, and not ready, until a file is read.
  property var catalog: MenuModel.catalogFrom([])
  property bool ready: false
  property var answers: MenuModel.noAnswers()

  // The menu files were read again, and the catalog made anew without the
  // rows the providers had added.
  signal reread()
  // Rows came or answers changed.
  signal updated()
  // A provider's rows came.
  signal providerDone()

  function reload() {
    shippedFile.reload()
    userFile.reload()
  }

  // ------------------------------------------------------------ the files

  property var shipped: new Map()
  property var mine: new Map()

  WatchedFile {
    id: shippedFile
    path: Quickshell.env("NOVA_PATH") + "/default/menu.jsonc"
    onLoaded: {
      source.shipped = MenuModel.readMenuFile(text())
      source.rebuild()
    }
  }

  WatchedFile {
    id: userFile
    path: Quickshell.env("HOME") + "/.config/nova/menu.jsonc"
    onLoaded: {
      source.mine = MenuModel.readMenuFile(text())
      source.rebuild()
    }
    onLoadFailed: {
      source.mine = new Map()
      source.rebuild()
    }
  }

  // A provider still running for the catalog before is not heard: its
  // generation is gone.
  property int generation: 0

  function rebuild() {
    generation += 1
    filled = new Set()
    waiting = []
    catalog = MenuModel.catalogOf(shipped, mine)
    ready = true
    askGuards()
    reread()
  }

  // -------------------------------------------------------- the providers

  // The menus filled since the catalog was made, by id, and those waiting
  // for the provider running.
  property var filled: new Set()
  property var waiting: []

  // The bash providers: what lists the values, what prints the one set
  // now, and what sets one; a volatile one runs again each time its menu
  // is entered, so that a font installed since shows. "apps" is the app
  // library; a provider of any other name fills nothing.
  readonly property var providers: new Map([
    ["fonts", { list: "nova-font-list", now: "nova-font-current", set: "nova-font-set", glyph: "", volatile: true }],
    ["power-profiles", { list: "nova-power-profile list", now: "nova-power-profile get", set: "nova-power-profile set", glyph: "󰐋", volatile: false }]
  ])

  // Fills the menu <id> from its provider, once for this catalog: the apps
  // at once, a bash provider after the one running.
  function fill(id) {
    const menu = catalog.items.get(id)
    if (!menu || !menu.provider || filled.has(id)) return
    if (menu.provider === "apps") {
      filled.add(id)
      addApps()
    } else if (providers.has(menu.provider)) {
      if (!lister.running) start(id)
      else if (!waiting.includes(id)) waiting.push(id)
    }
  }

  // A menu entered runs its volatile provider again: the last pick may
  // have changed what it lists. A search does not, or each key would.
  function refill(id) {
    const menu = catalog.items.get(id)
    const kind = menu ? providers.get(menu.provider) : null
    if (kind && kind.volatile) filled.delete(id)
    fill(id)
  }

  // Every provider a search of the menu <menuId> reaches: its own and those
  // of the menus under it, or all of them from the root.
  function fillUnder(menuId) {
    const top = catalog.items.has(menuId) ? menuId : "root"
    for (const item of catalog.items.values()) {
      if (item.provider && (top === "root" || item.id === top || MenuModel.above(catalog, item).includes(top))) fill(item.id)
    }
  }

  function start(id) {
    const kind = providers.get(catalog.items.get(id).provider)
    filled.add(id)
    lister.menuId = id
    lister.kind = kind
    lister.generation = generation
    lister.printed = ""
    // The value set now on the first line, then the values.
    lister.command = ["bash", "-lc", "now=$(" + kind.now + " 2>/dev/null); printf '%s\\n' \"${now//$'\\n'/ }\"; " + kind.list + " 2>/dev/null"]
    lister.running = true
  }

  function startWaiting() {
    if (lister.running) return
    while (waiting.length > 0) {
      const id = waiting.shift()
      if (filled.has(id) || !catalog.items.has(id)) continue
      start(id)
      return
    }
  }

  Process {
    id: lister
    property string menuId: ""
    property var kind: null
    property int generation: 0
    property string printed: ""
    stdout: SplitParser {
      onRead: line => lister.printed += line + "\n"
    }
    onExited: {
      if (lister.generation === source.generation) {
        const set = lister.kind.set
        const rows = MenuModel.providerItems(lister.menuId, lister.printed, lister.kind.glyph, value => set + " " + Util.shellQuote(value))
        source.catalog = MenuModel.withFilled(source.catalog, lister.menuId, rows)
        source.updated()
        source.providerDone()
      }
      source.startWaiting()
    }
  }

  function addApps() {
    if (!apps) return
    catalog = MenuModel.withApps(catalog, MenuModel.appItems(apps))
    updated()
  }

  Connections {
    target: source.apps
    function onAppsChanged() {
      if (source.filled.has("apps")) source.addApps()
    }
  }

  // ------------------------------------------------- when: and checked:

  // Asked each time the catalog is made and the menu opens, which shows the
  // last answers until the new ones come. A run's command cannot change
  // while it runs, and its output is the only answer for its rows: one
  // asked for meanwhile waits for it to end.
  property bool askAgain: false

  function askGuards() {
    if (guards.running) {
      askAgain = true
      return
    }
    askAgain = false
    const script = MenuModel.guardScript(catalog)
    if (!script) {
      answers = MenuModel.noAnswers()
      return
    }
    guards.printed = ""
    guards.command = ["bash", "-lc", script]
    guards.running = true
  }

  Process {
    id: guards
    property string printed: ""
    stdout: SplitParser {
      onRead: line => guards.printed += line + "\n"
    }
    // A run killed part way has answered only the rows it reached, and a
    // row with no answer shows: the last whole answers stand. A signal
    // leaves the exit code at 0, and the status tells.
    onExited: function(code, status) {
      if (code === 0 && status === 0) {
        source.answers = MenuModel.readAnswers(guards.printed)
        source.updated()
      }
      // The run that waited, a turn later, once this one has settled.
      if (source.askAgain) Qt.callLater(source.askGuards)
    }
  }

  // --------------------------------------------------------------- answers

  // The sum the search is ("" for none: Calculator.js); qalc's answers to
  // the sums typed since the search became one, { sum: answer }, an answer
  // being { label, copy }, or null for none; and the answer shown last.
  property string sum: ""
  property var worked: ({})
  property var shown: null
  // A sum asked and not answered yet.
  readonly property bool calculating: sum !== "" && !worked.hasOwnProperty(sum)

  // The answer to <query>, once the keys have rested 50 ms: qalc takes some
  // 30 ms, and a sum typed fast is one run, not one a key. One asked for
  // while qalc runs waits for it, and only the latest waits. Nothing is run
  // for a search that is not a sum, as an app's name is not, and a search
  // that stops being one drops the answers.
  function calculate(query) {
    const next = Calculator.expression(query)
    if (next === sum) return
    // A search that becomes a sum reads the Calculator's unit again: the file
    // is not watched until it is there.
    if (!sum && next) angleFile.reload()
    sum = next
    pondered.stop()
    calculator.drop()
    if (!sum) {
      worked = {}
      shown = null
    } else if (worked.hasOwnProperty(sum)) {
      shown = worked[sum]
    } else {
      pondered.restart()
    }
  }

  // The answer while <query> is the sum. While a sum typed since is worked
  // out, the one shown stays, so that the row does not blink at each key;
  // Return waits for the new one (Menu.qml).
  function answerFor(query) {
    if (!sum || Calculator.expression(query) !== sum) return null
    return worked.hasOwnProperty(sum) ? worked[sum] : shown
  }

  Timer {
    id: pondered
    interval: 50
    onTriggered: calculator.ask(source.sum)
  }

  // An answer that comes once the search is no longer a sum is dropped.
  function settle(sum, found) {
    if (!sum || !source.sum || worked.hasOwnProperty(sum)) return
    const next = Object.assign({}, worked)
    next[sum] = found || null
    worked = next
    if (sum === source.sum) shown = next[sum]
    updated()
  }

  // Angles in the Calculator's unit, which its window keeps (Deg, unless it
  // was turned to Rad): sin(30) is the same here and there, as Ctrl+Return
  // opens it there. Answers in the other unit go when it is turned. The file
  // is read again when it changes, and as a search becomes a sum.
  property string angle: "deg"
  onAngleChanged: {
    worked = {}
    if (sum) {
      calculator.drop()
      pondered.restart()
    }
  }

  WatchedFile {
    id: angleFile
    path: Commons.Color.stateHome + "/nova/calculator.json"
    onLoaded: {
      let kept = null
      try { kept = JSON.parse(text()) } catch (e) {}
      source.angle = kept && kept.angle === "rad" ? "rad" : "deg"
    }
    onLoadFailed: source.angle = "deg"
  }

  Calc.Qalc {
    id: calculator
    settings: ["angle " + source.angle]
    onAnswered: (sum, found) => source.settle(sum, found)
  }
}
