import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ClipboardHistory.js" as ClipboardHistory

// The clipboard history: what was copied, text and images, newest first. Two
// wl-paste watchers run capture.sh at every copy and the entry it prints goes
// to the top of $XDG_STATE_HOME/nova/clipboard-history.json, 300 at most. The
// picker shows the 50 newest a search finds, the one under the cursor in full
// beside them: Return pastes it, Shift+Return copies it, Alt+Return opens it,
// Delete drops it and Shift+Delete, once confirmed, clears the history.
Item {
  id: root

  property string novaPath: Quickshell.env("NOVA_PATH")
  readonly property string historyPath: Commons.Color.stateHome + "/nova/clipboard-history.json"
  readonly property string helpers: novaPath + "/shell/plugins/clipboard/"
  readonly property int historyLimit: 300

  property var history: []
  // What the picker shows for each entry, worked out again only when the
  // history has changed since.
  property var shown: []
  property bool shownStale: true
  onHistoryChanged: shownStale = true

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  // The cursor is drawn once the keys or the pointer have moved it; a picker
  // just cleared has none, and Return first brings it back.
  property bool cursorShown: false
  property bool confirmingClear: false

  // The [menu] section's colours: a theme that styles the menu styles the
  // clipboard too.
  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(875), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)

  // The shell's summon, hide and toggle.
  function open(payload) {
    opened = true
    filterText = ""
    selectedIndex = 0
    cursorShown = true
    pointerGate.reset()
    refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    keepHistory()
    opened = false
  }

  function toggle() {
    if (opened) close()
    else open("{}")
  }

  // -------------------------------------------------------------- history

  function load(text) {
    history = ClipboardHistory.parse(text)
    if (opened) refresh()
    pruneSoon.restart()
  }

  function save() {
    historyFile.setText(JSON.stringify(history.slice(0, historyLimit), null, 2) + "\n")
    pruneSoon.restart()
  }

  // A line capture.sh printed: the entry copied, at the top.
  function record(line) {
    var item = ClipboardHistory.parseLine(line)
    if (!item) return
    history = ClipboardHistory.added(history, item, historyLimit)
    save()
    if (opened) refresh()
  }

  function askClear() {
    if (history.length === 0) return
    clearConfirm.selectedIndex = 1
    confirmingClear = true
  }

  function keepHistory() {
    confirmingClear = false
    pointerGate.reset()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function clear() {
    history = []
    save()
    selectedIndex = 0
    cursorShown = false
    pointerGate.reset()
    confirmingClear = false
    refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  // Drops the entry of row <index>; the cursor stays on the row that takes
  // its place, or the last.
  function remove(index) {
    if (index < 0 || index >= rows.count) return
    history = ClipboardHistory.removed(history, rows.get(index).historyIndex)
    save()
    if (rows.count <= 1) {
      selectedIndex = 0
      cursorShown = false
    } else if (selectedIndex >= rows.count - 1) {
      selectedIndex = rows.count - 2
    }
    pointerGate.reset()
    refresh()
  }

  // ---------------------------------------------------------------- picker

  // The rows for the history and the search, the cursor kept within them.
  function refresh() {
    if (shownStale) {
      shown = ClipboardHistory.views(history)
      shownStale = false
    }
    var found = ClipboardHistory.rows(shown, filterText, 50)
    rows.clear()
    for (var i = 0; i < found.length; i++) {
      rows.append({
        entryType: found[i].entryType,
        fullText: found[i].fullText,
        previewText: found[i].previewText,
        previewImage: found[i].previewImage ? Util.fileUrl(found[i].previewImage) : "",
        path: found[i].path,
        mime: found[i].mime,
        historyIndex: found[i].index
      })
    }
    selectedIndex = rows.count === 0 ? 0 : Math.max(0, Math.min(selectedIndex, rows.count - 1))
    Qt.callLater(function () {
      if (rows.count > 0) list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  // The cursor <delta> rows on: one row wraps round the ends, more stop at
  // them. With no cursor drawn, the first move puts it on the first row, or
  // the last.
  function move(delta) {
    if (rows.count === 0) return
    pointerGate.reset()
    if (!cursorShown) {
      cursorShown = true
      selectedIndex = delta < 0 ? rows.count - 1 : 0
    } else {
      selectedIndex = Util.stepIndex(selectedIndex, delta, rows.count)
    }
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function moveTo(index) {
    if (rows.count === 0) return
    pointerGate.reset()
    cursorShown = true
    selectedIndex = Math.max(0, Math.min(index, rows.count - 1))
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function setFilter(text) {
    filterText = text
    selectedIndex = 0
    cursorShown = true
    pointerGate.reset()
    refresh()
  }

  // The pointer moves the cursor only when it moves itself, not when a row
  // slides under it.
  function point(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    cursorShown = true
    selectedIndex = index
  }

  // ---------------------------------------------------------------- actions

  // Row <index> pasted, copied or opened, by the helpers, the picker shut. An
  // image is pasted from its file; text by its place in the history and the
  // md5 of its entryKey, which the helper checks, so a copy that lands
  // meanwhile and moves every entry down one is not mistaken for it. The md5,
  // not the text, as anyone can read a command line.
  function use(index, how) {
    if (index < 0 || index >= rows.count) return
    var row = rows.get(index)
    opened = false
    var entry = ["--history-index", String(row.historyIndex),
      "--history-md5", Qt.md5(ClipboardHistory.entryKey(history[row.historyIndex]))]
    if (how === "open")
      Quickshell.execDetached(["nova-clipboard-open"].concat(entry))
    else if (row.entryType === "image")
      Quickshell.execDetached(["nova-clipboard-paste-file"].concat(how === "copy" ? ["--copy-only"] : [], [row.mime, row.path]))
    else if (row.fullText)
      Quickshell.execDetached(["nova-clipboard-paste-text", how === "copy" ? "--copy-only" : "--shift-insert"].concat(entry))
  }

  ListModel { id: rows }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.load(text())
    onLoadFailed: root.load("[]")
    onFileChanged: reload()
  }

  // --------------------------------------------------------------- watchers

  // Watchers a shell before this one left are ended first. Ours end with the
  // shell however it ends: setpriv has the kernel signal them when it goes.
  Component.onCompleted: reap.running = true

  Process {
    id: reap
    command: ["pkill", "-f", "wl-paste .*--watch .*/shell/plugins/clipboard/capture\\.sh"]
    onExited: {
      current.running = true
      textWatch.running = true
      imageWatch.running = true
    }
  }

  // What is on the clipboard as the shell starts.
  Process {
    id: current
    command: [root.helpers + "capture.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.record(text)
    }
  }

  Process {
    id: textWatch
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "text", "--watch", root.helpers + "capture.sh", "text"]
    onExited: rewatch.restart()
    stdout: SplitParser {
      onRead: function (line) { root.record(line) }
    }
  }

  Process {
    id: imageWatch
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "image/png", "--watch", root.helpers + "capture.sh", "image/png"]
    onExited: rewatch.restart()
    stdout: SplitParser {
      onRead: function (line) { root.record(line) }
    }
  }

  // A watcher that dies would stop the history without a sign: copying still
  // works and the picker still shows what it had. It is started again.
  Timer {
    id: rewatch
    interval: 1000
    onTriggered: {
      if (!textWatch.running) textWatch.running = true
      if (!imageWatch.running) imageWatch.running = true
    }
  }

  // Images the history no longer names are deleted, by prune-images.sh, five
  // seconds after it last changed or was read.
  Timer {
    id: pruneSoon
    interval: 5000
    onTriggered: {
      if (prune.running) {
        restart()
        return
      }
      var named = []
      for (var i = 0; i < root.history.length; i++)
        if (root.history[i].type === "image") named.push(root.history[i].path)
      prune.command = [root.helpers + "prune-images.sh"].concat(named)
      prune.running = true
    }
  }

  Process { id: prune }

  // ----------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nova-clipboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.confirmingClear ? 20 : 0
        focus: true

        // Typing searches, edited as everywhere in the shell; Escape clears
        // the search, then closes. While the clear is being confirmed, the
        // dialog has the keys.
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (root.confirmingClear) {
            if (clearConfirm.handleKey(event)) event.accepted = true
            return
          }
          var key = event.key
          var alt = event.modifiers & Qt.AltModifier
          var shift = event.modifiers & Qt.ShiftModifier
          if (key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
          } else if (key === Qt.Key_Delete) {
            if (shift) root.askClear()
            else root.remove(root.selectedIndex)
          } else if (key === Qt.Key_Up || key === Qt.Key_Down || key === Qt.Key_PageUp || key === Qt.Key_PageDown) {
            root.move(key === Qt.Key_Up ? -1 : key === Qt.Key_Down ? 1 : key === Qt.Key_PageUp ? -6 : 6)
          } else if (key === Qt.Key_Home || key === Qt.Key_End) {
            root.moveTo(key === Qt.Key_Home ? 0 : rows.count - 1)
          } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            if (!root.cursorShown) root.cursorShown = rows.count > 0
            else root.use(root.selectedIndex, alt ? "open" : shift ? "copy" : "paste")
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
          } else {
            return
          }
          event.accepted = true
        }

        ConfirmDialog {
          id: clearConfirm

          anchors.fill: parent
          opened: root.confirmingClear
          z: 10
          message: "Delete entire clipboard history?"
          confirmText: "Delete"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.keepHistory()
          onConfirmed: root.clear()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // The search, or what it is for.
        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search clipboard…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          Row {
            anchors.fill: parent
            spacing: 0

            // The entries, a line each.
            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              ListView {
                id: list
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: rows
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: row
                  required property int index
                  required property string entryType
                  required property string previewText
                  required property string fullText
                  required property string previewImage

                  readonly property bool hasCursor: root.cursorShown && index === root.selectedIndex
                  readonly property bool hasImage: previewImage.length > 0

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: hasCursor ? root.selectedBackground : "transparent"

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    anchors.topMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(8)
                    spacing: Style.space(10)

                    // Decoded at the row's size: the entry is the image copied,
                    // a screenshot or a photo, and the history is always loaded.
                    Image {
                      visible: row.hasImage
                      width: visible ? parent.height : 0
                      height: parent.height
                      source: row.previewImage
                      sourceSize: Qt.size(height, height)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      smooth: true
                    }

                    // Files and images in grey, text as it is.
                    Text {
                      textFormat: Text.PlainText
                      width: parent.width - (row.hasImage ? parent.height + parent.spacing : 0)
                      height: parent.height
                      text: row.previewText
                      color: row.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      opacity: row.entryType === "image" || row.entryType === "file" ? 0.72 : 1.0
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      verticalAlignment: Text.AlignVCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: function (mouse) {
                      root.point(row.index, row, mouse)
                    }
                    onClicked: {
                      root.cursorShown = true
                      root.selectedIndex = row.index
                      root.use(row.index, "paste")
                    }
                  }
                }
              }

              // The touchpad scrolls the list as GTK does.
              TouchpadScroll {
                anchors.fill: list
                flickable: list
              }
            }

            // The entry under the cursor, whole: its text, or its image.
            Item {
              id: pane
              width: parent.width / 2
              height: parent.height
              clip: true

              property var entry: rows.count > 0 && root.selectedIndex >= 0 && root.selectedIndex < rows.count ? rows.get(root.selectedIndex) : null

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.28)
              }

              Text {
                textFormat: Text.PlainText
                visible: pane.entry && !pane.entry.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                text: pane.entry ? pane.entry.fullText : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                verticalAlignment: Text.AlignTop
              }

              // At the pane's size, as the rows are at theirs.
              Image {
                visible: pane.entry && pane.entry.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                source: pane.entry ? pane.entry.previewImage : ""
                sourceSize: Qt.size(width, height)
                fillMode: Image.PreserveAspectFit
                verticalAlignment: Image.AlignTop
                asynchronous: true
                smooth: true
              }
            }
          }

          // Nothing to show: an empty history, or a search that finds none.
          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: rows.count === 0

            Text {
              text: "\u{F014C}"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.history.length === 0 ? "Clipboard is empty" : "No matches for “" + root.filterText + "”"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
