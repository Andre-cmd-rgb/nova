import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "MenuModel.js" as Model

// Nova's menu: the apps, settings and commands of menu.jsonc on a card over
// the screen, walked with the keys or the pointer and searched by typing.
// It is also nova-menu-select's chooser, a list to pick from or a line to
// type into. shell.qml keeps it loaded, calls open() with the payload of
// `nova-shell shell summon nova.menu`, close() to hide it, and refresh() and
// ping() for nova menu; it reads `opened` to toggle it.
Item {
  id: root

  // Set by shell.qml once the plugin has loaded.
  property string novaPath: Quickshell.env("NOVA_PATH")
  property var shell: null
  property var manifest: null

  // The installed apps, the shell's one AppLibrary.
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  // -------------------------------------------------------------- the calls

  // {"menu": route} (or "initialMenu") opens the menu at the route; a "mode"
  // of "select" or "input" opens the chooser (openChooser). A "fontFamily"
  // is the menu's font from then on.
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (notJson) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily
    if (payload.mode === "select" || payload.mode === "input") root.openChooser(payload)
    else root.openRoute(payload.initialMenu || payload.menu || "root")
  }

  function close() {
    root.cancel()
  }

  // Reads both menu files again.
  function refresh() {
    defaultFile.reload()
    userFile.reload()
    return "ok"
  }

  function ping() { return "ok" }

  // ------------------------------------------------------------------ state

  property bool opened: false
  // "menu", or the chooser's "select" or "input".
  property string mode: "menu"
  readonly property bool choosing: mode !== "menu"
  // The menu shown, and those walked through to it, for Back.
  property string current: "root"
  property var trail: []
  // What has been typed: a search, or the chooser's filter or line.
  property string query: ""
  property int selectedIndex: 0

  // The menu's tree (MenuModel.js), from the two files' entries.
  property var defaultEntries: []
  property var userEntries: []
  property var tree: ({ items: ({}), itemOrder: [] })
  property bool loaded: false

  // The last answers of the when: and checked: script, by id.
  property var whenResults: ({})
  property var checkedResults: ({})
  property bool guardsPending: false

  // The menus whose provider has filled them, by id; the bash providers
  // waiting for providerRun; and the tree they were asked from, whose rows
  // a provider that ends after the menu files are read again does not add.
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0

  // The chooser, and the nova-menu-select waiting on it, if one is.
  property string chooserPrompt: ""
  property var chooserOptions: []
  property int chooserWidth: 300
  property int chooserMaxHeight: 0
  ChooserRequest { id: request }

  // The app the uninstall question is about, { appId, label }, or null.
  property var uninstalling: null
  onOpenedChanged: if (!opened) uninstalling = null

  // The rows the list shows, in the list's model too.
  property var rows: []
  ListModel { id: shown }

  // ------------------------------------------------------------------- look

  property string fontFamily: Style.font.menuFamily
  // The [menu] colours of shell.toml, each with its alpha.
  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  property color selectedBorder: Commons.Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  // Every row keeps room for the cursor's border, so the cursor moving
  // shifts no text.
  readonly property real rowBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int contentSpacing: Style.spacing.md
  readonly property int baseRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  readonly property int detailRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  // How much of the first row below the fold shows: enough to read as a row
  // cut short rather than a border.
  readonly property int rowPeek: Math.round(baseRowHeight * 0.55)
  readonly property int rowSpacing: Style.spacing.xs
  readonly property int dividerHeight: Style.space(17)

  // Screen Recording's and Font's rows are long, and get a wider card.
  readonly property var wideMenus: ["capture.screenrecord", "style.font"]
  readonly property int cardWidth: Math.min(choosing ? Style.space(chooserWidth) : Style.space(wideMenus.indexOf(current) >= 0 ? 520 : 300), panel.width - Style.gapsOut * 2)
  property int visibleRowsHeight: listHeight()
  readonly property int cardHeight: Math.min(contentMargin * 2 + headerHeight + (mode === "input" ? 0 : contentSpacing + visibleRowsHeight), panel.height - Style.gapsOut * 2)

  // A row's line under the label shows while a search narrows the menu, and
  // always in the chooser, where it is the caller's.
  function rowHeight(detail) {
    return (query || choosing) && detail ? detailRowHeight : baseRowHeight
  }

  // The room the rows have before the card runs off the screen, or past the
  // top a search has pinned it at. It reads cardTop, not effectiveCardTop:
  // the centred top comes from the card's height, which this decides.
  function availableRowsHeight() {
    var top = panel.cardTop >= 0 ? panel.cardTop : Style.gapsOut
    var room = panel.height - top - Style.gapsOut - contentMargin * 2 - headerHeight - contentSpacing
    // The menu the card opened on sets the most it grows to: a longer menu
    // walked into scrolls instead.
    if (panel.maxRowsHeight >= 0) room = Math.min(room, panel.maxRowsHeight)
    // A card taller than this reads as a page, not a menu.
    return Math.min(room, Math.round(panel.height * 0.7))
  }

  function listHeight() {
    if (mode === "input") return 0
    if (rows.length === 0) return baseRowHeight
    var room = availableRowsHeight()
    if (choosing && chooserMaxHeight > 0) room = Math.min(room, Style.space(chooserMaxHeight))
    var withLine = query || choosing ? detailRowHeight : baseRowHeight
    var bottoms = Model.rowBottoms(rows, baseRowHeight, withLine, rowSpacing, dividerHeight)
    return Model.foldedHeight(bottoms, room, rowPeek, rowSpacing, baseRowHeight)
  }

  function item(id) {
    return tree.items[id] || null
  }

  // ------------------------------------------------------------- the files

  // The default menu.jsonc and the user's, each read again when it changes;
  // the user's is laid over the defaults a field at a time.
  FileView {
    id: defaultFile
    path: root.novaPath + "/default/menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.defaultEntries = Model.parseMenuJsonc(text())
      root.rebuildTree()
    }
    onFileChanged: reload()
  }

  FileView {
    id: userFile
    path: Quickshell.env("HOME") + "/.config/nova/menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.userEntries = Model.parseMenuJsonc(text())
      root.rebuildTree()
    }
    onLoadFailed: {
      root.userEntries = []
      root.rebuildTree()
    }
    onFileChanged: reload()
  }

  // A new tree drops every provider's rows, and a provider still running
  // for the old one is not heard.
  function rebuildTree() {
    var next = Model.mergeMenuSources(defaultEntries, userEntries)
    providerRevision += 1
    providersLoaded = ({})
    providerQueue = []
    tree = next
    loaded = true
    evaluateGuards()
    if (!opened) return
    rebuildDisplay()
    if (choosing) return
    if (query.trim()) loadProvidersUnder()
    else loadProvider(current)
  }

  // --------------------------------------------------------------- providers

  // A bash provider prints a "label<TAB>value<TAB>current" line a row. One
  // that is volatile runs again each time its menu is entered: a font
  // installed since the shell started shows up.
  readonly property var providers: ({
    "fonts": {
      script: "current=$(nova-font-current 2>/dev/null); nova-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "nova-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(nova-power-profile get 2>/dev/null); nova-power-profile list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "󰐋",
      actionFor: function(value) { return "nova-power-profile set " + Util.shellQuote(value) }
    }
  })

  // Fills the menu <id> from its provider, once: the apps at once, from
  // AppLibrary, which gives them their icons, their launch and their
  // removal; a bash provider by providerRun, after the one running.
  function loadProvider(id) {
    var entry = item(id)
    if (!entry || !entry.provider || providersLoaded[id]) return
    if (entry.provider === "apps") {
      providersLoaded[id] = true
      addApps()
    } else if (providerRun.running) {
      if (providerQueue.indexOf(id) < 0) providerQueue = providerQueue.concat([id])
    } else {
      startProvider(id)
    }
  }

  // Each provider of a menu a search reaches: under the menu shown, or all.
  function loadProvidersUnder() {
    var menuId = item(current) ? current : "root"
    for (var i = 0; i < tree.itemOrder.length; i++) {
      var entry = item(tree.itemOrder[i])
      if (!entry || !entry.provider || providersLoaded[entry.id]) continue
      if (menuId !== "root" && entry.id !== menuId && !Model.isUnder(tree.items, entry.id, menuId)) continue
      loadProvider(entry.id)
    }
  }

  function startProvider(id) {
    var entry = item(id)
    var spec = entry ? providers[entry.provider] : null
    if (!spec) return
    providersLoaded[id] = true
    providerRun.menuId = id
    providerRun.provider = entry.provider
    providerRun.revision = providerRevision
    providerRun.collected = ""
    providerRun.command = ["bash", "-lc", spec.script]
    providerRun.running = true
  }

  function startQueuedProvider() {
    if (providerRun.running) return
    while (providerQueue.length > 0) {
      var id = providerQueue.shift()
      var entry = item(id)
      if (!entry || !entry.provider || providersLoaded[id]) continue
      startProvider(id)
      return
    }
  }

  // Entering a menu is when a volatile list is run again: its last pick may
  // have changed it. A search does not, or each key would start it over.
  function forgetVolatile(id) {
    var entry = item(id)
    var spec = entry && entry.provider ? providers[entry.provider] : null
    if (spec && spec.volatile) providersLoaded[id] = false
  }

  function addApps() {
    if (!appLibrary) return
    var apps = Model.appItems(appLibrary.sortedEntries(""), appLibrary.entryName, appLibrary.entrySubtext)
    tree = Model.withApps(tree, apps)
    if (opened) rebuildDisplay()
  }

  function addProviderRows(text, menuId, provider) {
    var spec = providers[provider]
    if (!spec) return
    tree = Model.withProviderRows(tree, menuId, Model.providerItems(menuId, text, spec.icon, spec.actionFor))
    if (opened) rebuildDisplay()
  }

  Process {
    id: providerRun
    property string menuId: ""
    property string provider: ""
    property string collected: ""
    property int revision: 0
    stdout: SplitParser {
      onRead: function(line) { providerRun.collected += line + "\n" }
    }
    onExited: {
      if (providerRun.revision === root.providerRevision) {
        root.addProviderRows(providerRun.collected, providerRun.menuId, providerRun.provider)
        if (root.query.trim()) root.loadProvidersUnder()
      }
      root.startQueuedProvider()
    }
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      if (root.providersLoaded["apps"]) root.addApps()
    }
  }

  // ------------------------------------------------------ when: and checked:

  // Every when: (does the row show) and checked: (does it have a ✓) is a
  // bash expression, all of them run as one script (Model.guardScript)
  // whenever the tree changes and each time the menu opens, which shows the
  // last answers until the new ones come.
  function evaluateGuards() {
    // A run's command cannot change while it runs, and its output is the
    // only answer for its rows: a second run started over it would never
    // start, and keep the half the first had printed. It waits instead.
    if (guardRun.running) {
      guardsPending = true
      return
    }
    guardsPending = false
    var script = Model.guardScript(tree.items)
    if (!script) {
      whenResults = ({})
      checkedResults = ({})
      return
    }
    guardRun.collected = ""
    guardRun.command = ["bash", "-lc", script]
    guardRun.running = true
  }

  Process {
    id: guardRun
    property string collected: ""
    stdout: SplitParser {
      onRead: function(line) { guardRun.collected += line + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      // A run killed part way has answered only the rows it reached, and a
      // row whose when: went unanswered shows: the last whole answers stand.
      // A signal leaves the exit code at 0; the status tells.
      if (exitCode === 0 && exitStatus === 0) {
        var answers = Model.readGuards(guardRun.collected)
        root.whenResults = answers.when
        root.checkedResults = answers.checked
        if (root.opened) root.rebuildDisplay()
      }
      // The run that waited, a turn later, once this one has settled.
      if (root.guardsPending) Qt.callLater(root.evaluateGuards)
    }
  }

  // ----------------------------------------------------------------- opening

  // A route is an id or an alias (Model.resolveRoute). An action's route
  // runs the action, and a link's opens the menu it points to.
  function openRoute(route) {
    var id = Model.resolveRoute(tree, route)
    var entry = tree.items[id]
    if (entry && entry.kind === "action" && entry.action) {
      cancel()
      run(entry.action)
      return "ok"
    }
    if (entry && entry.kind === "link" && entry.target) id = entry.target
    openMenu(id)
    return "ok"
  }

  // A chooser still waiting is answered as cancelled: the menu takes its
  // place.
  function openMenu(id) {
    request.release()
    mode = "menu"
    current = item(id) ? id : "root"
    trail = []
    query = ""
    selectedIndex = 0
    pointerGate.reset()
    evaluateGuards()
    opened = true
    rebuildDisplay()
    forgetVolatile(current)
    loadProvider(current)
    // Icons placed after the shell started (on a first install, for one)
    // are found when the menu opens.
    if (appLibrary) appLibrary.refreshIcons()
    Qt.callLater(focusKeys)
  }

  // nova-menu-select's chooser: its "prompt", its "options" (Model.chooserRows)
  // or, for "input", a line to type; the files the pick is written to
  // ("selectionFile", "doneFile"); and its "width" and "maxHeight".
  function openChooser(payload) {
    mode = payload.mode === "input" ? "input" : "select"
    chooserPrompt = String(payload.prompt || (mode === "input" ? "Input" : "Select"))
    chooserOptions = Array.isArray(payload.options) ? payload.options : []
    request.begin(String(payload.selectionFile || ""), String(payload.doneFile || ""))
    chooserWidth = Math.max(1, Number(payload.width || 300))
    chooserMaxHeight = Math.max(0, Number(payload.maxHeight || 0))
    current = "root"
    trail = []
    query = ""
    selectedIndex = 0
    pointerGate.reset()
    opened = true
    rebuildDisplay()
    Qt.callLater(focusKeys)
  }

  function focusKeys() {
    keyCatcher.forceActiveFocus()
  }

  // ----------------------------------------------------------------- the rows

  // Lists the chooser's options, what a search finds, or the menu shown.
  // The list empties first, so rows that cannot be worked out leave it
  // empty rather than showing the last ones.
  function rebuildDisplay() {
    show([])
    if (mode === "input" || (!choosing && !loaded)) return
    var next
    if (choosing) {
      next = Model.chooserRows(chooserOptions, query)
    } else {
      current = item(current) ? current : "root"
      var search = query.trim()
      next = search ? Model.searchRows(tree, current, search, whenResults, checkedResults)
        : Model.menuRows(tree, current, whenResults, checkedResults)
    }
    show(next)
    selectedIndex = Math.max(0, Math.min(selectedIndex, next.length - 1))
    Qt.callLater(revealCursor)
  }

  // The list starts again at its top. Rows put back into a list still
  // scrolled are laid out from where it was scrolled to, and its origin
  // would move that far on with each new list.
  function show(next) {
    rows = next
    shown.clear()
    list.contentY = list.originY
    if (next.length > 0) shown.append(next)
  }

  // Scrolls the cursor's row into view with the next row peeking past it,
  // the way it moves: a row flush with the edge hides the one beyond and the
  // fold that says there is more.
  function revealCursor() {
    if (shown.count === 0) return
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
    var at = list.itemAtIndex(selectedIndex)
    if (!at) return
    var reach = rowPeek + rowSpacing
    if (selectedIndex < shown.count - 1) {
      var lowest = Math.max(list.originY, list.originY + list.contentHeight - list.height)
      var below = at.y + at.height + reach - (list.contentY + list.height)
      if (below > 0) list.contentY = Math.min(list.contentY + below, lowest)
    }
    if (selectedIndex > 0) {
      var above = list.contentY - (at.y - reach)
      if (above > 0) list.contentY = Math.max(list.contentY - above, list.originY)
    }
  }

  // ------------------------------------------------------------ moving about

  // The cursor <delta> rows on: one row wraps round the ends, a page stops
  // at them.
  function move(delta) {
    if (shown.count === 0) return
    pointerGate.reset()
    selectedIndex = Util.stepIndex(selectedIndex, delta, shown.count)
    revealCursor()
  }

  function search(text) {
    panel.freezeCardTop()
    query = text
    selectedIndex = 0
    pointerGate.reset()
    if (!choosing && query.trim()) loadProvidersUnder()
    rebuildDisplay()
  }

  // Shows the menu <id> (the root for one that is not there), remembered
  // for Back when <remember>. From the pointer, the row under it takes the
  // cursor at once.
  function enter(id, remember, fromPointer) {
    panel.freezeCardTop()
    if (!item(id)) id = "root"
    if (remember && id !== current) trail = trail.concat([current])
    current = id
    query = ""
    selectedIndex = 0
    if (fromPointer) pointerGate.allowInitialSample()
    else pointerGate.reset()
    rebuildDisplay()
    forgetVolatile(id)
    loadProvider(id)
  }

  // Back to the menu before, or up to the parent of one opened by a route.
  function goBack() {
    if (current === "root") return
    if (trail.length > 0) {
      var previous = trail[trail.length - 1]
      trail = trail.slice(0, -1)
      enter(previous, false)
      return
    }
    var entry = item(current)
    enter(entry && entry.parent ? entry.parent : "root", false)
  }

  // Does what the row at <index> is for: enters a menu, launches an app,
  // runs a command, or picks a chooser's option, its line too when it has
  // one. In the chooser's input it gives the line typed.
  function activate(index, fromPointer) {
    if (uninstalling) return
    if (mode === "input") {
      choose(query)
      return
    }
    if (index < 0 || index >= shown.count) return
    var row = shown.get(index)
    if (choosing) {
      choose(row.detail ? row.label + "\t" + row.detail : row.label)
    } else if (row.kind === "menu" || row.kind === "link") {
      enter(row.target || row.itemId, true, fromPointer)
    } else if (row.kind === "app") {
      var appId = row.appId
      var label = row.label
      opened = false
      query = ""
      if (appLibrary) appLibrary.launch(appId, label)
    } else if (!row.itemId) {
      cancel()
    } else {
      opened = false
      query = ""
      run(row.action)
    }
  }

  function run(action) {
    var command = String(action || "")
    if (command) Util.execDetached(command)
  }

  function choose(value) {
    opened = false
    query = ""
    finish(value)
  }

  // Answers the chooser, with null as cancelled; with none waiting, closes.
  function finish(value) {
    if (!request.finish(value)) opened = false
  }

  function cancel() {
    if (choosing) finish(null)
    opened = false
    query = ""
  }

  // ---------------------------------------------------------------- uninstall

  // Delete asks to uninstall the app under the cursor, with Uninstall chosen.
  function askUninstall() {
    if (selectedIndex < 0 || selectedIndex >= shown.count) return
    var row = shown.get(selectedIndex)
    if (!row || row.kind !== "app") return
    confirm.selectedIndex = 1
    uninstalling = { appId: row.appId, label: row.label }
  }

  function keepApp() {
    uninstalling = null
    confirm.selectedIndex = 1
    pointerGate.reset()
    Qt.callLater(focusKeys)
  }

  function uninstall() {
    var app = uninstalling
    uninstalling = null
    if (!app) return
    cancel()
    if (appLibrary) appLibrary.remove(app.appId, app.label)
  }

  // --------------------------------------------------------------------- keys

  // Escape clears a search, or closes; Backspace and Left go back when
  // nothing is typed; Up, Down, Page Up and Page Down move; Return, Enter
  // and Right do what the row is for; Delete asks to uninstall an app; text
  // searches. While the uninstall question is up, it has the keys.
  function pressKey(event) {
    if (uninstalling) return confirm.handleKey(event)
    var key = event.key
    var step = stepFor(key)
    if (key === Qt.Key_Delete) askUninstall()
    else if (key === Qt.Key_Escape) query ? search("") : cancel()
    else if (Util.editsFilter(event, query)) search(Util.editedFilter(event, query))
    else if ((key === Qt.Key_Backspace || key === Qt.Key_Left) && !query) goBack()
    else if (step !== 0) move(step)
    else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Right) activate(selectedIndex)
    else if (typed(event)) search(query + event.text)
    else return false
    return true
  }

  function stepFor(key) {
    switch (key) {
    case Qt.Key_Up: return -1
    case Qt.Key_Down: return 1
    case Qt.Key_PageUp: return -6
    case Qt.Key_PageDown: return 6
    }
    return 0
  }

  // A character typed as itself, shifted or not.
  function typed(event) {
    var code = event.text && event.text.length === 1 ? event.text.charCodeAt(0) : 0
    return code >= 32 && code !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)
  }

  // ------------------------------------------------------------------ pointer

  // Rows slide under a pointer that stands still, which Qt reports as hover;
  // only a real move takes the cursor.
  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  function pointAt(index, row, mouse) {
    if (pointerGate.moved(row, mouse)) selectedIndex = index
  }

  // ------------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened && root.loaded
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nova-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // The card opens centred. The first search key or move pins its top
    // where it is, and from then on it grows and shrinks downward instead of
    // jumping to a new centre each time; the rows' height then is the most
    // they grow to. Closing frees both.
    property int cardTop: -1
    property int maxRowsHeight: -1
    readonly property int centeredTop: Math.max(Style.gapsOut, Math.round((height - root.cardHeight) / 2))
    readonly property int effectiveCardTop: cardTop >= 0 ? cardTop : centeredTop

    function freezeCardTop() {
      if (!visible || cardTop >= 0) return
      cardTop = effectiveCardTop
      maxRowsHeight = root.visibleRowsHeight
    }

    onVisibleChanged: {
      if (visible) return
      cardTop = -1
      maxRowsHeight = -1
    }

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(root.cardHeight, panel.height - Style.gapsOut - panel.effectiveCardTop)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: panel.effectiveCardTop
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      // A click on the card is not one on the scrim.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.uninstalling ? 20 : 0
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.pressKey(event)) event.accepted = true
        }

        ConfirmDialog {
          id: confirm
          anchors.fill: parent
          z: 10
          opened: root.uninstalling !== null
          message: "Do you want to uninstall " + ((root.uninstalling && root.uninstalling.label) || "") + "?"
          confirmText: "Uninstall"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.keepApp()
          onConfirmed: root.uninstall()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // The search, or what is shown: the chooser's prompt, the menu's
        // title or label.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.query || (root.choosing ? root.chooserPrompt : root.menuTitle()) + "…"
            color: root.foreground
            opacity: root.query ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: root.visibleRowsHeight

          ListView {
            id: list
            anchors.fill: parent
            model: shown
            clip: true
            spacing: root.rowSpacing
            boundsBehavior: Flickable.StopAtBounds

            // A search's rows deeper than the menu, under a line.
            section.property: "section"
            section.criteria: ViewSection.FullString
            section.delegate: Item {
              required property string section
              width: ListView.view.width
              height: section === "drilldown" ? root.dividerHeight : 0
              visible: section === "drilldown"

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.spacing.hairline
                color: Util.alpha(root.foreground, 0.2)
              }
            }

            delegate: MenuRow {}
          }

          // The touchpad scrolls the list as GTK does.
          TouchpadScroll {
            anchors.fill: list
            flickable: list
          }

          // A fade at each edge the list has rows hidden past, as strong as
          // how much is: at rest the row cut short marks the fold, and these
          // follow the scroll, so a jump from the last row to the first
          // lands faded already.
          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: list.contentHeight > list.height
              ? Math.max(0, Math.min(1, (list.contentY - list.originY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: root.background }
              GradientStop { position: 1; color: Util.alpha(root.background, 0) }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: list.contentHeight > list.height
              ? Math.max(0, Math.min(1, (list.originY + list.contentHeight - list.height - list.contentY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: Util.alpha(root.background, 0) }
              GradientStop { position: 1; color: root.background }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: shown.count === 0 && root.mode !== "input"

            Text {
              width: Style.space(320)
              text: "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: Style.space(320)
              textFormat: Text.PlainText
              text: root.query ? "No matches for “" + root.query + "”" : "Nothing here yet"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }

  function menuTitle() {
    var entry = item(current)
    return entry ? entry.title || entry.label : "Go"
  }

  // A row of the list: its glyph or app icon, its label with the line under
  // it, and a › on one that opens a menu.
  component MenuRow: BorderSurface {
    id: row
    required property int index
    required property string kind
    required property string icon
    required property string iconFont
    required property string appIcon
    required property string label
    required property string detail

    readonly property bool hasCursor: index === root.selectedIndex
    readonly property bool isApp: kind === "app"
    readonly property bool hasIcon: icon.length > 0 || isApp
    readonly property color ink: hasCursor ? root.selectedText : root.foreground
    // The glyph, the icon and the › are centred on the label's line.
    readonly property real labelMiddle: lines.y + title.y + title.height / 2

    width: ListView.view.width
    height: root.rowHeight(detail)
    radius: root.cornerRadius
    color: hasCursor ? root.selectedBackground : "transparent"
    borderSpec: hasCursor ? root.selectedBorderSpec : Border.none()

    Text {
      id: glyph
      visible: row.hasIcon && !row.isApp
      anchors.left: parent.left
      anchors.leftMargin: root.rowBorderLeft + Style.space(8)
      y: row.labelMiddle - height / 2
      width: Style.space(36)
      textFormat: Text.PlainText
      text: row.icon
      color: row.ink
      font.family: row.iconFont.length > 0 ? row.iconFont : root.fontFamily
      font.pixelSize: Style.font.iconLarge
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }

    Image {
      visible: row.isApp
      anchors.left: parent.left
      anchors.leftMargin: root.rowBorderLeft + Style.space(8) + (Style.space(36) - width) / 2
      y: row.labelMiddle - height / 2
      width: Style.font.iconLarge
      height: Style.font.iconLarge
      fillMode: Image.PreserveAspectFit
      // Decoded at the screen's pixels: one decoded at the logical size is
      // blurred when scaled up on a HiDPI screen.
      sourceSize.width: width * Screen.devicePixelRatio
      sourceSize.height: height * Screen.devicePixelRatio
      source: row.isApp && root.appLibrary ? root.appLibrary.iconSource(row.appIcon) : ""
      asynchronous: true
    }

    Column {
      id: lines
      anchors.left: row.hasIcon ? glyph.right : parent.left
      anchors.leftMargin: row.hasIcon ? Style.space(6) : root.rowBorderLeft + Style.space(18)
      anchors.right: chevron.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        id: title
        width: parent.width
        textFormat: Text.PlainText
        text: row.label
        color: row.ink
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.weight: Font.Medium
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: (root.query || row.kind === "choice") && row.detail.length > 0
        textFormat: Text.PlainText
        text: row.detail
        color: root.foreground
        opacity: 0.52
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }

    Text {
      id: chevron
      visible: row.kind === "menu" || row.kind === "link"
      anchors.right: parent.right
      anchors.rightMargin: root.rowBorderRight + Style.space(8)
      y: row.labelMiddle - height / 2
      width: Style.space(14)
      textFormat: Text.PlainText
      text: "›"
      color: row.ink
      opacity: 0.36
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      font.weight: Font.Normal
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.pointAt(row.index, row, { x: pointer.mouseX, y: pointer.mouseY })
      onPositionChanged: function(mouse) { root.pointAt(row.index, row, mouse) }
      onClicked: {
        root.selectedIndex = row.index
        root.activate(row.index, true)
      }
    }
  }
}
