import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "MenuModel.js" as MenuModel

// Nova's menu: the apps, settings and commands of menu.jsonc on a card over
// the screen, walked with the keys or the pointer and searched by typing;
// and nova-menu-select's chooser, a list to pick from. The shell keeps it
// loaded: `nova-shell shell summon nova.menu` hands open() its payload, hide
// calls close(), nova menu's refresh and ping call refresh() and ping(), and
// toggle reads opened.
Item {
  id: plugin

  // Set by the shell once the plugin has loaded.
  property var shell: null
  readonly property var apps: shell ? shell.appLibrary : null

  // -------------------------------------------------------------- the calls

  // {"menu": route} opens the menu at the route; {"mode": "select", ...}
  // the chooser (showChooser).
  function open(payload) {
    let asked = {}
    try {
      asked = JSON.parse(payload || "{}")
    } catch (notJson) { }
    if (asked.mode === "select") showChooser(asked)
    else openAt(asked.menu || "root")
  }

  function close() {
    dismiss()
  }

  // Reads both menu files again.
  function refresh() {
    source.reload()
    return "ok"
  }

  function ping() {
    return "ok"
  }

  // ------------------------------------------------------------------ state

  property bool opened: false
  readonly property bool ready: source.ready
  // The chooser, while it is up: its prompt, its options, and the card's
  // width and the rows' most height it asked for.
  property bool choosing: false
  property var chooser: ({ prompt: "", options: [], width: 300, maxHeight: 0 })
  // The menu shown, and the menus walked through to it, for Back.
  property string here: "root"
  property var walked: []
  // What has been typed: a search, or the chooser's filter.
  property string typed: ""
  // The row the keys act on, and the rows listed (MenuModel.js).
  property int cursor: 0
  property var rows: []
  // The app the uninstall question asks about, { appId, label }, or null.
  // Closing drops the question, and so does a menu or a chooser opened over
  // it: it would keep the keys, and Return would uninstall the app.
  property var asking: null
  onOpenedChanged: if (!opened) asking = null

  // What the card's head shows with nothing typed in a menu: its title, or
  // its label.
  readonly property string title: {
    const shown = source.catalog.items.get(here)
    return shown ? shown.title || shown.label : "Go"
  }

  // ---------------------------------------------------------------- opening

  // A route is an id or an alias (MenuModel.resolve); one of a command runs
  // it.
  function openAt(route) {
    const id = MenuModel.resolve(source.catalog, route)
    const item = source.catalog.items.get(id)
    if (item && item.kind === "action" && item.command) {
      dismiss()
      run(item.command)
    } else {
      showMenu(id)
    }
  }

  // The menu <id>, or the root for one that is not there, as it is now: its
  // when: and checked: asked again, its provider run, and icons placed since
  // the shell started (on a first install) found. A chooser still waiting
  // is answered as cancelled.
  function showMenu(id) {
    request.release()
    asking = null
    choosing = false
    here = source.catalog.items.has(id) ? id : "root"
    walked = []
    typed = ""
    cursor = 0
    gate.reset()
    window.unpin()
    source.askGuards()
    opened = true
    relist()
    source.refill(here)
    if (apps) apps.refreshIcons()
    Qt.callLater(window.takeKeys)
  }

  // nova-menu-select's chooser: its prompt, its options (MenuModel.choiceRows),
  // the files the pick goes to (ChooserRequest), and its width and maxHeight.
  function showChooser(asked) {
    asking = null
    choosing = true
    chooser = {
      prompt: String(asked.prompt || "Select"),
      options: Array.isArray(asked.options) ? asked.options : [],
      width: Math.max(1, Number(asked.width || 300)),
      maxHeight: Math.max(0, Number(asked.maxHeight || 0))
    }
    request.begin(String(asked.selectionFile || ""), String(asked.doneFile || ""))
    here = "root"
    walked = []
    typed = ""
    cursor = 0
    gate.reset()
    window.unpin()
    opened = true
    relist()
    Qt.callLater(window.takeKeys)
  }

  // ------------------------------------------------------------- the rows

  // Lists the chooser's options, what a search finds, or the menu shown;
  // nothing until a menu file is read. Rows that cannot be worked out leave
  // the list empty rather than showing the last.
  function relist() {
    let next = []
    try {
      if (choosing) {
        next = MenuModel.choiceRows(chooser.options, typed)
      } else if (ready) {
        if (!source.catalog.items.has(here)) here = "root"
        next = typed.trim() ? MenuModel.searchRows(source.catalog, here, typed, source.answers)
          : MenuModel.menuRows(source.catalog, here, source.answers, typed !== "")
      }
    } finally {
      rows = next
      window.show(next)
    }
    if (!choosing && !ready) return
    cursor = Math.max(0, Math.min(cursor, next.length - 1))
    Qt.callLater(window.reveal)
  }

  Connections {
    target: source

    // A new catalog has none of the providers' rows the last had.
    function onReread() {
      if (!plugin.opened) return
      plugin.relist()
      if (plugin.choosing) return
      if (plugin.typed.trim()) source.fillUnder(plugin.here)
      else source.fill(plugin.here)
    }

    function onUpdated() {
      if (plugin.opened) plugin.relist()
    }

    function onProviderDone() {
      if (plugin.typed.trim()) source.fillUnder(plugin.here)
    }
  }

  // ------------------------------------------------------------ moving about

  // The cursor <step> rows on: a row at a time wraps round the ends, a page
  // stops at them.
  function move(step) {
    if (rows.length === 0) return
    gate.reset()
    cursor = Util.stepIndex(cursor, step, rows.length)
    window.reveal()
  }

  // What is typed is now <text>: the search, or the chooser's filter. A
  // search runs the providers of every menu it reaches.
  function filter(text) {
    window.pin()
    typed = text
    cursor = 0
    gate.reset()
    if (!choosing && typed.trim()) source.fillUnder(here)
    relist()
  }

  // Into the menu <id> (the root for one that is not there), remembered for
  // Back when <remember>. From the pointer, the row under it takes the
  // cursor at once.
  function go(id, remember, byPointer) {
    window.pin()
    const into = source.catalog.items.has(id) ? id : "root"
    if (remember && into !== here) walked = walked.concat([here])
    here = into
    typed = ""
    cursor = 0
    if (byPointer) gate.allowInitialSample()
    else gate.reset()
    relist()
    source.refill(into)
  }

  // Back to the menu before, or up to the menu above one a route opened.
  function back() {
    if (here === "root") return
    if (walked.length > 0) {
      const before = walked[walked.length - 1]
      walked = walked.slice(0, -1)
      go(before, false)
    } else {
      const shown = source.catalog.items.get(here)
      go(shown && shown.parent ? shown.parent : "root", false)
    }
  }

  // Does what the row at <index> is for: picks the chooser's option, its
  // line too when it has one; enters a menu; launches an app; runs a
  // command.
  function take(index, byPointer) {
    const row = rows[index]
    if (asking || !row) return
    if (choosing) {
      answer(row.line ? row.label + "\t" + row.line : row.label)
    } else if (row.kind === "menu") {
      go(row.key, true, byPointer)
    } else {
      opened = false
      typed = ""
      if (row.kind !== "app") run(row.command)
      else if (apps) apps.launch(row.appId, row.label)
    }
  }

  function run(command) {
    if (command) Util.execDetached(command)
  }

  // Closes, the chooser's caller given <pick>.
  function answer(pick) {
    opened = false
    typed = ""
    request.finish(pick)
  }

  // Closes, the chooser's caller answered as cancelled.
  function dismiss() {
    if (choosing) request.finish(null)
    opened = false
    typed = ""
  }

  // ------------------------------------------------------------- uninstall

  // Delete asks whether to uninstall the app under the cursor, Uninstall
  // chosen.
  function askUninstall() {
    const row = rows[cursor]
    if (!row || row.kind !== "app") return
    window.question.selectedIndex = 1
    asking = { appId: row.appId, label: row.label }
  }

  function keep() {
    asking = null
    gate.reset()
    Qt.callLater(window.takeKeys)
  }

  function uninstall() {
    const app = asking
    asking = null
    if (!app) return
    dismiss()
    if (apps) apps.remove(app.appId, app.label)
  }

  // ------------------------------------------------------------------ keys

  readonly property var steps: new Map([[Qt.Key_Up, -1], [Qt.Key_Down, 1], [Qt.Key_PageUp, -6], [Qt.Key_PageDown, 6]])

  // Escape clears what is typed, or closes; Backspace and Left go back when
  // nothing is; Up, Down, Page Up and Page Down move; Return, Enter and
  // Right do what the row is for; Delete asks to uninstall an app; text is
  // typed. While the uninstall question is up, it has the keys.
  function press(event) {
    const key = event.key
    if (asking) return window.question.handleKey(event)
    if (key === Qt.Key_Delete) askUninstall()
    else if (key === Qt.Key_Escape) typed ? filter("") : dismiss()
    else if (Util.editsFilter(event, typed)) filter(Util.editedFilter(event, typed))
    else if ((key === Qt.Key_Backspace || key === Qt.Key_Left) && !typed) back()
    else if (steps.has(key)) move(steps.get(key))
    else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Right) take(cursor)
    else if (isText(event)) filter(typed + event.text)
    else return false
    return true
  }

  // A key that types its character: a printable one, shifted or not, from
  // the keyboard or from its keypad, which Qt marks with a modifier of its
  // own.
  function isText(event) {
    const code = event.text.length === 1 ? event.text.charCodeAt(0) : 0
    const typing = Qt.ShiftModifier | Qt.KeypadModifier
    return code >= 32 && code !== 127 && (event.modifiers & ~typing) === 0
  }

  // --------------------------------------------------------------- pointer

  // Rows slide under a pointer standing still, which Qt reports as hover;
  // only a real move takes the cursor.
  function pointAt(index, row, mouse) {
    if (gate.moved(row, mouse)) cursor = index
  }

  // ------------------------------------------------------------- the parts

  MenuSource {
    id: source
    apps: plugin.apps
  }

  ChooserRequest {
    id: request
  }

  PointerMoveGate {
    id: gate
    referenceItem: window.card
  }

  MenuWindow {
    id: window
    menu: plugin
  }
}
