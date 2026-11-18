import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "StoreModel.js" as Model

// The App Center: one window to find apps, install them, open them and
// remove them, from Nova's own builds (Chrome, VS Code), Arch Linux's
// repositories and Flathub, as one list. It owns nothing of its own:
//
//   nova-apps-catalog    the apps, from the AppStream catalogs on this
//                        computer, as one file it reads (~/.cache/nova/apps)
//   nova-apps-installed  which of them are installed, and from where
//   nova-apps-refresh    Flathub's catalog fetched again once a day
//   nova-apps-run        an install or a removal, as a user service of its
//                        own, which goes on with the window closed; how far
//                        it is, in $XDG_RUNTIME_DIR/nova/apps/status.json
//
// Updates are not here: Nova's updater keeps the apps up to date with the
// rest (Settings, Updates; nova update).
//
// Summoned by the shell, from the menu, the CLI or an appstream:// link:
//   nova-shell shell summon nova.store '{"app":"org.gimp.GIMP"}'
//   nova-shell shell summon nova.store '{"search":"paint"}'
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "nova.store"

  property bool closingFromHost: false
  property string page: "discover"
  readonly property var pages: Model.pages

  // The search's words as typed, and as searched for, a moment later.
  property string query: ""
  property string searched: ""
  // The app whose page is open, by ID; one asked for before the catalog
  // was read waits in <wanted>.
  property string shownId: ""
  property string wanted: ""
  // Where Back goes: the page, or the search.
  property string backLabel: "Back"

  property var catalog: null
  property bool catalogFailed: false
  property bool refreshFailed: false
  property var installed: null
  property var allJobs: ({})
  // An install or removal asked for and not begun: { id: seconds }.
  property var pending: ({})
  property real openedAt: 0
  property real installedAt: 0
  property string failure: ""
  property var queue: []
  property bool watching: false

  readonly property var apps: catalog ? catalog.apps : []
  readonly property var shown: catalog && shownId ? catalog.byId[shownId] || null : null
  readonly property var jobs: Model.visibleJobs(allJobs, openedAt)
  readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/apps"

  // ---- what the pages ask of it -------------------------------------------

  function statusOf(app) {
    return Model.status(app, installed, jobs, Model.asked(app, jobs, pending))
  }

  function canOpen(app) {
    return Model.launchWords(app, Model.installedFrom(app, installed)).length > 0
  }

  function show(app) {
    if (!app) return
    backLabel = searched !== "" ? "Search" : Model.pageLabel(page) || "Back"
    // Made anew for another app, rather than the last one's page kept.
    shownId = ""
    shownId = app.id
  }

  function back() {
    shownId = ""
    Qt.callLater(function () { keys.forceActiveFocus() })
  }

  function install(app, kind) {
    var argv = ["nova-apps-run", "install", app.id]
    var from = kind || (app.sources && app.sources.length > 0 ? app.sources[0].kind : "")
    if (from) argv.push("--from", from)
    ask(app, argv)
  }

  function remove(app) {
    ask(app, ["nova-apps-run", "remove", app.id])
  }

  function ask(app, argv) {
    var next = Object.assign({}, pending)
    next[app.id] = Math.floor(Date.now() / 1000)
    pending = next
    run(argv)
  }

  function launch(app) {
    var words = Model.launchWords(app, Model.installedFrom(app, installed))
    if (words.length > 0) Quickshell.execDetached(words)
  }

  function choose(id) {
    seek("")
    shownId = ""
    page = id
  }

  // The search's words, typed in its field or not, searched for at once.
  function seek(words) {
    searchField.text = words
    query = words
    searched = words.trim()
  }

  function step(delta) {
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].id === page) {
        choose(pages[(i + delta + pages.length) % pages.length].id)
        return
      }
    }
    choose(pages[0].id)
  }

  // ---- lifecycle ------------------------------------------------------------

  // The store opens on its front page, or on the page, the app or the
  // search asked for, never where it was when it last closed.
  function open(payloadJson) {
    closingFromHost = false
    var payload = {}
    try {
      payload = JSON.parse(String(payloadJson || "{}")) || {}
    } catch (e) {
      // An unparseable payload asks for nothing.
    }
    page = pages.some(function (p) { return p.id === payload.page }) ? payload.page : pages[0].id
    seek(typeof payload.search === "string" ? payload.search : "")
    shownId = ""
    wanted = typeof payload.app === "string" ? payload.app : ""
    backLabel = Model.pageLabel(page)
    failure = ""
    openedAt = Math.floor(Date.now() / 1000)
    forget.stop()
    if (window.visible && elsewhere()) close()
    if (!window.visible) measureRoom()
    window.visible = true
    load()
    findWanted()
    Qt.callLater(function () { searchField.forceActiveFocus() })
  }

  function load() {
    if (!catalogProc.running) catalogProc.running = true
    if (!installedProc.running) readInstalled()
    if (!refreshProc.running) refreshProc.running = true
  }

  function readInstalled() {
    installedAt = Math.floor(Date.now() / 1000)
    installedProc.running = true
  }

  function findWanted() {
    if (!wanted || !catalog) return
    var word = wanted
    var app = Model.find(catalog, word)
    wanted = ""
    if (app) {
      show(app)
    } else {
      // Not one the catalog knows by that: looked for instead.
      seek(word)
    }
  }

  // The room on the focused screen, where the window opens, as Settings
  // takes it.
  property size room: Qt.size(Style.space(960), Style.space(640))

  // How much bigger than its usual size it opens: more on a bigger screen.
  property real growth: 1

  function measureRoom() {
    // Without Hyprland (a test, a smoke run) there is no screen in focus to
    // measure, and the window keeps its usual size.
    var hyprland = !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    var name = hyprland && Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) {
        room = Qt.size(screens[i].width - Style.space(48), screens[i].height - Style.space(80))
        growth = Util.windowGrowth(screens[i].width, screens[i].height, Style.spaceScale)
        return
      }
    }
  }

  function elsewhere() {
    if (!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")) return false
    var focused = Hyprland.focusedWorkspace
    return focused !== null && Util.onAnotherWorkspace(Hyprland.toplevels.values, window.title, focused.id)
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  // Asks run one at a time, in order; one that fails says why at the foot.
  function run(argv) {
    failure = ""
    var next = queue.slice()
    next.push(argv)
    queue = next
    pump()
  }

  function pump() {
    if (actionProc.running || queue.length === 0) return
    var next = queue.slice()
    actionProc.command = next.shift()
    queue = next
    actionProc.running = true
  }

  onQueryChanged: settle.restart()
  onSearchedChanged: if (searched !== "") shownId = ""

  Timer {
    id: settle
    interval: 120
    onTriggered: root.searched = root.query.trim()
  }

  // A pending ask that never began (one for the app was under way already)
  // is let go of.
  Timer {
    interval: 5000
    repeat: true
    running: Object.keys(root.pending).length > 0
    onTriggered: {
      var now = Math.floor(Date.now() / 1000)
      var next = {}
      for (var id in root.pending)
        if (now - root.pending[id] < 30) next[id] = root.pending[id]
      root.pending = next
    }
  }

  // The catalog is some megabytes once read: let go of a while after the
  // window closes, and read again as it opens.
  Timer {
    id: forget
    interval: 300000
    onTriggered: {
      root.catalog = null
      catalogFile.path = ""
    }
  }

  // ---- processes --------------------------------------------------------------

  Process {
    id: catalogProc
    command: ["nova-apps-catalog"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text).trim()
        if (path === "") return
        // Read as the path is set, and again whenever the file is made anew.
        if (catalogFile.path !== path) catalogFile.path = path
        else if (!root.catalog) catalogFile.reload()
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.catalog) root.catalogFailed = true
    }
  }

  FileView {
    id: catalogFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      var read = Model.read(text())
      if (read) {
        root.catalog = read
        root.catalogFailed = false
        root.findWanted()
      } else if (!root.catalog) {
        root.catalogFailed = true
      }
    }
    onFileChanged: reload()
  }

  Process {
    id: installedProc
    command: ["nova-apps-installed"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text))
          if (parsed && typeof parsed === "object") root.installed = parsed
        } catch (e) {
          // A bad read keeps what is on screen.
        }
      }
    }
  }

  Process {
    id: refreshProc
    command: ["nova-apps-refresh"]
    // A catalog made anew is read as its file changes.
    onExited: function (exitCode) { root.refreshFailed = exitCode !== 0 }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      id: actionErrors
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        var message = String(actionErrors.text || "").trim().split("\n").pop()
        root.failure = message.length > 0 ? message : "That did not work (exit " + exitCode + ")."
        root.pending = ({})
      }
      root.pump()
    }
  }

  // The jobs' status, watched once its folder is there: Quickshell sees a
  // file appear in a folder that is, not in one made after it looked.
  Process {
    command: ["mkdir", "-p", root.runDir]
    running: true
    onExited: root.watching = true
  }

  FileView {
    path: root.watching ? root.runDir + "/status.json" : ""
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && typeof parsed === "object") root.allJobs = parsed
      } catch (e) {
        // Written whole, then moved into place: a bad read is someone else's.
      }
      // One that ended changed what is installed.
      if (Model.endedSince(root.allJobs, root.installedAt) && !installedProc.running) root.readInstalled()
    }
    onFileChanged: reload()
  }

  // ---- pieces -------------------------------------------------------------------

  component Heading: Text {
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.heading
    font.bold: true
    textFormat: Text.PlainText
  }

  // ---- window ---------------------------------------------------------------------

  FloatingWindow {
    id: window
    title: "App Center"
    visible: false
    color: Commons.Color.background
    implicitWidth: Math.min(Style.space(960 * root.growth), root.room.width)
    implicitHeight: Math.min(Style.space(640 * root.growth), root.room.height)
    minimumSize: Qt.size(Math.min(Style.space(680), root.room.width), Math.min(Style.space(480), root.room.height))

    onVisibleChanged: {
      if (!visible) {
        forget.restart()
        if (!root.closingFromHost && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
      }
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          if (root.shownId !== "") root.back()
          else if (root.query !== "") root.seek("")
          else root.requestClose()
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) {
          searchField.forceActiveFocus()
          searchField.selectAll()
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Tab || event.key === Qt.Key_PageDown)) {
          root.step(1)
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Backtab || event.key === Qt.Key_PageUp)) {
          root.step(-1)
          event.accepted = true
        } else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_Left && root.shownId !== "") {
          root.back()
          event.accepted = true
        }
      }

      // A mouse's back button goes back too.
      TapHandler {
        acceptedButtons: Qt.BackButton
        onTapped: if (root.shownId !== "") root.back()
      }

      // ---- sidebar ----------------------------------------------------------
      Rectangle {
        id: sidebar
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.space(200)
        color: Qt.alpha(Commons.Color.foreground, 0.03)

        TextField {
          id: searchField
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          anchors.topMargin: Style.space(18)
          placeholderText: "Search"
          onTextChanged: root.query = text
          // Return opens the first app found.
          onAccepted: {
            root.searched = root.query.trim()
            var found = Model.search(root.apps, root.searched, 1)
            if (found.length > 0) root.show(found[0])
          }
        }

        Flickable {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: searchField.bottom
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(12)
          anchors.topMargin: Style.space(14)
          contentHeight: entries.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          clip: true

          Column {
            id: entries
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.pages

              delegate: Item {
                id: entry
                required property var modelData
                required property int index
                readonly property bool selected: root.page === modelData.id && root.searched === ""
                readonly property real gap: modelData.group && index > 0 ? Style.space(14) : 0
                width: parent.width
                height: gap + Style.space(32)

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Style.space(32)
                  radius: Style.cornerRadius
                  color: entry.selected ? Style.selectedFill : (hover.hovered ? Style.hoverFill : "transparent")

                  HoverHandler { id: hover }
                  TapHandler { onTapped: root.choose(entry.modelData.id) }

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)
                    Text {
                      width: Style.space(18)
                      text: entry.modelData.icon
                      color: entry.selected ? Commons.Color.accent : Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.icon
                      horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                      text: entry.modelData.label
                      color: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: entry.selected
                    }
                  }
                }
              }
            }
          }
        }
      }

      Rectangle {
        anchors.left: sidebar.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Qt.alpha(Commons.Color.foreground, 0.08)
      }

      // ---- the page -----------------------------------------------------------
      Loader {
        id: content
        anchors.left: sidebar.right
        anchors.leftMargin: 1
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: failureBar.visible ? failureBar.top : parent.bottom
        // Made only while the window is open.
        active: window.visible
        sourceComponent: {
          if (!root.catalog) return waitingView
          if (root.shownId !== "" && root.shown) return appView
          if (root.searched !== "") return resultsView
          if (root.page === "discover") return discoverView
          if (root.page === "installed") return installedView
          return categoryView
        }
      }

      Rectangle {
        id: failureBar
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.failure.length > 0
        height: visible ? failureText.implicitHeight + Style.space(16) : 0
        color: Qt.alpha(Commons.Color.urgent, 0.15)

        Text {
          id: failureText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: Style.space(16)
          text: root.failure
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }
        TapHandler { onTapped: root.failure = "" }
      }
    }
  }

  // ---- views ------------------------------------------------------------------------

  // The catalog, while it is read, or when it cannot be.
  Component {
    id: waitingView
    Item {
      Caption {
        anchors.centerIn: parent
        text: root.catalogFailed ? "The list of apps could not be read." : "Loading…"
      }
    }
  }

  // The front page: the best-known apps, then a few of each kind, chosen by
  // hand, and the way to all of them.
  Component {
    id: discoverView
    ScrollView {
      id: scroll
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

      Item {
        width: scroll.availableWidth
        implicitHeight: front.implicitHeight

        TouchpadScroll {
          anchors.fill: parent
          z: -1
          flickable: scroll.contentItem
        }

        Column {
          id: front
          width: parent.width
          padding: Style.space(28)
          spacing: Style.space(26)
          readonly property real inner: width - leftPadding - rightPadding

          Column {
            width: front.inner
            spacing: Style.space(6)
            Text {
              text: "Discover"
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
              textFormat: Text.PlainText
            }
            Caption {
              width: parent.width
              visible: !root.catalog.flathub && root.refreshFailed
              text: "Flathub could not be reached, so its apps are missing."
            }
          }

          Repeater {
            model: Model.shelves()

            delegate: Column {
              id: shelf
              required property var modelData
              readonly property var picks: Model.featured(root.apps, modelData.id)
              readonly property int columns: Math.max(1, Math.floor(front.inner / Style.space(300)))
              visible: picks.length > 0
              width: front.inner
              spacing: Style.space(8)

              Item {
                width: parent.width
                height: Math.max(title.implicitHeight, all.implicitHeight)
                Heading {
                  id: title
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: shelf.modelData.label
                }
                Button {
                  id: all
                  visible: shelf.modelData.id !== "popular"
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "See All"
                  onClicked: root.choose(shelf.modelData.id)
                }
              }

              Grid {
                columns: shelf.columns
                Repeater {
                  model: shelf.picks
                  delegate: AppTile {
                    required property var modelData
                    width: shelf.width / shelf.columns
                    app: modelData
                    store: root
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // A list of apps in tiles: a category's, or what a search found.
  component AppGrid: GridView {
    id: grid
    property var store: null
    property string title: ""
    property string note: ""
    readonly property real margin: Style.space(28)
    // A tile's icon in line with the title, its hover wider.
    readonly property real inset: Style.space(10)
    readonly property int columns: Math.max(1, Math.floor((width - 2 * margin) / Style.space(300)))
    clip: true
    leftMargin: margin - inset
    rightMargin: margin - inset
    bottomMargin: margin
    cellWidth: Math.floor((width - 2 * (margin - inset)) / columns)
    cellHeight: Style.space(68)
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar {}

    TouchpadScroll { flickable: grid }

    header: Column {
      width: grid.width - 2 * (grid.margin - grid.inset)
      leftPadding: grid.inset
      rightPadding: grid.inset
      topPadding: Style.space(28)
      bottomPadding: Style.space(16)
      spacing: Style.space(6)
      Text {
        width: parent.width - parent.leftPadding - parent.rightPadding
        text: grid.title
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
      Caption {
        width: parent.width - parent.leftPadding - parent.rightPadding
        visible: text.length > 0
        text: grid.note
      }
    }

    delegate: AppTile {
      required property var modelData
      width: grid.cellWidth
      app: modelData
      store: grid.store
    }
  }

  Component {
    id: categoryView
    AppGrid {
      store: root
      title: Model.pageLabel(root.page)
      model: Model.inCategory(root.apps, root.page)
    }
  }

  Component {
    id: resultsView
    AppGrid {
      store: root
      readonly property var found: Model.search(root.apps, root.searched, 60)
      title: "Results for “" + root.searched + "”"
      note: found.length === 0 ? "Nothing found." : ""
      model: found
    }
  }

  // What is installed, by name, with Open and Remove at hand.
  Component {
    id: installedView
    ListView {
      id: list
      readonly property real margin: Style.space(28)
      readonly property real inset: Style.space(10)
      clip: true
      leftMargin: margin - inset
      rightMargin: margin - inset
      bottomMargin: margin
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar {}
      model: root.installed ? Model.installedApps(root.apps, root.installed) : []

      TouchpadScroll { flickable: list }

      header: Column {
        width: list.width - 2 * (list.margin - list.inset)
        leftPadding: list.inset
        rightPadding: list.inset
        topPadding: Style.space(28)
        bottomPadding: Style.space(16)
        spacing: Style.space(6)
        Text {
          text: "Installed"
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.display
          font.bold: true
          textFormat: Text.PlainText
        }
        Caption {
          width: parent.width - parent.leftPadding - parent.rightPadding
          visible: list.count === 0
          text: root.installed ? "No apps are installed." : "Loading…"
        }
      }

      delegate: InstalledRow {
        required property var modelData
        width: list.width - 2 * (list.margin - list.inset)
        app: modelData
        store: root
      }
    }
  }

  // An installed app: where it came from, Open, and Remove after a second
  // click.
  component InstalledRow: Item {
    id: row
    property var app: null
    property var store: null
    property bool confirming: false
    readonly property var st: row.store.statusOf(app)
    implicitHeight: Style.space(56)

    Rectangle {
      anchors.fill: parent
      anchors.topMargin: Style.space(1)
      anchors.bottomMargin: Style.space(1)
      radius: Style.cornerRadius
      color: hover.hovered ? Style.hoverFill : "transparent"
    }
    HoverHandler {
      id: hover
      cursorShape: Qt.PointingHandCursor
    }
    TapHandler { onTapped: row.store.show(row.app) }

    AppIcon {
      id: icon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      app: row.app
      size: Style.space(36)
    }

    Column {
      anchors.left: icon.right
      anchors.leftMargin: Style.space(12)
      anchors.right: buttons.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)
      Text {
        width: parent.width
        text: row.app ? row.app.name : ""
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
      Caption {
        width: parent.width
        visible: row.st.action !== "busy"
        text: row.st.error || Model.installedText(row.app, row.store.installed)
        color: row.st.error ? Commons.Color.urgent : Commons.Color.foreground
        opacity: row.st.error ? 1 : 0.6
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
      }
      ProgressLine {
        visible: row.st.action === "busy"
        width: Math.min(parent.width, Style.space(240))
        fraction: row.st.progress
      }
    }

    Row {
      id: buttons
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Caption {
        anchors.verticalCenter: parent.verticalCenter
        visible: row.st.action === "busy"
        text: row.st.text
      }
      Button {
        visible: row.st.action === "open" && row.store.canOpen(row.app) && !row.confirming
        text: "Open"
        bordered: true
        onClicked: row.store.launch(row.app)
      }
      Button {
        visible: row.st.action === "open" && row.st.removable && !row.confirming
        text: "Remove…"
        bordered: true
        onClicked: row.confirming = true
      }
      Caption {
        anchors.verticalCenter: parent.verticalCenter
        visible: row.confirming && row.st.action === "open"
        text: row.st.removeNote
      }
      Button {
        visible: row.confirming && row.st.action === "open"
        text: "Remove Now"
        bordered: true
        foreground: Commons.Color.urgent
        onClicked: {
          row.confirming = false
          row.store.remove(row.app)
        }
      }
      Button {
        visible: row.confirming && row.st.action === "open"
        text: "Cancel"
        bordered: true
        onClicked: row.confirming = false
      }
    }
  }

  Component {
    id: appView
    ScrollView {
      id: scroll
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

      Item {
        width: scroll.availableWidth
        implicitHeight: appPage.implicitHeight

        TouchpadScroll {
          anchors.fill: parent
          z: -1
          flickable: scroll.contentItem
        }

        AppPage {
          id: appPage
          width: parent.width
          app: root.shown
          store: root
        }
      }
    }
  }
}
