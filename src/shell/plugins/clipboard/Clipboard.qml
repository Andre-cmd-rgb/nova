import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ClipboardHistory.js" as ClipboardHistory

// The clipboard (SUPER + CTRL + V): the history's 50 newest entries a
// search finds, a line each, and the one under the cursor whole beside
// them. Return pastes it, Shift+Return copies it, Alt+Return opens it;
// Delete drops it, and Shift+Delete, once confirmed, clears the history.
Item {
  id: clipboard

  property bool opened: false
  property string query: ""
  property int cursor: 0
  // The cursor is drawn once the keys or the pointer have put it somewhere:
  // a history just cleared has none, and Return first brings it back.
  property bool cursorShown: false
  property bool confirmingClear: false

  // What the picker shows for each entry, worked out again only when the
  // history has changed since.
  property var views: []
  property bool viewsStale: true

  readonly property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)

  // The shell's summon, hide and toggle.
  function open(payload) {
    opened = true
    query = ""
    cursor = 0
    cursorShown = true
    pointerGate.reset()
    refresh()
    Qt.callLater(picker.takeKeys)
  }

  function close() {
    keepHistory()
    opened = false
  }

  function toggle() {
    if (opened) close()
    else open("{}")
  }

  // ---------------------------------------------------------------- the rows

  // The rows for the history and the search, the cursor kept within them.
  function refresh() {
    if (viewsStale) {
      views = ClipboardHistory.views(history.entries)
      viewsStale = false
    }
    var found = ClipboardHistory.rows(views, query, 50)
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
    cursor = rows.count === 0 ? 0 : Math.max(0, Math.min(cursor, rows.count - 1))
    Qt.callLater(function () {
      if (rows.count > 0) list.positionViewAtIndex(clipboard.cursor, ListView.Contain)
    })
  }

  function search(text) {
    query = text
    cursor = 0
    cursorShown = true
    pointerGate.reset()
    refresh()
  }

  // The cursor <delta> rows on: one row wraps round the ends, more stop at
  // them. With no cursor drawn, the first move puts it on the first row, or
  // the last.
  function move(delta) {
    if (rows.count === 0) return
    pointerGate.reset()
    if (!cursorShown) {
      cursorShown = true
      cursor = delta < 0 ? rows.count - 1 : 0
    } else {
      cursor = Util.stepIndex(cursor, delta, rows.count)
    }
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  function moveTo(index) {
    if (rows.count === 0) return
    pointerGate.reset()
    cursorShown = true
    cursor = Math.max(0, Math.min(index, rows.count - 1))
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  // The pointer takes the cursor only when it moves itself, not when a row
  // slides under it.
  function point(index, row, mouse) {
    if (!pointerGate.moved(row, mouse)) return
    cursorShown = true
    cursor = index
  }

  // ---------------------------------------------------------------- the history

  // Drops the entry of row <index>; the cursor stays on the row that takes
  // its place, or on the last.
  function remove(index) {
    if (index < 0 || index >= rows.count) return
    history.drop(rows.get(index).historyIndex)
    if (rows.count <= 1) {
      cursor = 0
      cursorShown = false
    } else if (cursor >= rows.count - 1) {
      cursor = rows.count - 2
    }
    pointerGate.reset()
    refresh()
  }

  function askClear() {
    if (history.entries.length === 0) return
    clearDialog.selectedIndex = 1
    confirmingClear = true
  }

  function keepHistory() {
    confirmingClear = false
    pointerGate.reset()
    Qt.callLater(picker.takeKeys)
  }

  function clear() {
    history.clear()
    cursor = 0
    cursorShown = false
    pointerGate.reset()
    confirmingClear = false
    refresh()
    Qt.callLater(picker.takeKeys)
  }

  // Row <index> pasted, copied or opened by Nova's helpers, the picker
  // shut. An image goes from its file; text by its place in the history
  // and the md5 of its entryKey, which the helper checks, so that a copy
  // landing meanwhile, which moves every entry down one, is not taken for
  // it. The md5 and not the text, as anyone can read a command line.
  function use(index, how) {
    if (index < 0 || index >= rows.count) return
    var row = rows.get(index)
    opened = false
    var which = ["--history-index", String(row.historyIndex),
      "--history-md5", Qt.md5(ClipboardHistory.entryKey(history.entries[row.historyIndex]))]
    if (how === "open")
      Quickshell.execDetached(["nova-clipboard-open"].concat(which))
    else if (row.entryType === "image")
      Quickshell.execDetached(["nova-clipboard-paste-file"].concat(how === "copy" ? ["--copy-only"] : [], [row.mime, row.path]))
    else if (row.fullText)
      Quickshell.execDetached(["nova-clipboard-paste-text", how === "copy" ? "--copy-only" : "--shift-insert"].concat(which))
  }

  // The keys the search leaves: Delete, the arrows, Home and End, Return.
  function rowKeys(event) {
    var key = event.key
    var alt = event.modifiers & Qt.AltModifier
    var shift = event.modifiers & Qt.ShiftModifier
    if (key === Qt.Key_Delete) {
      if (shift) askClear()
      else remove(cursor)
    } else if (key === Qt.Key_Up || key === Qt.Key_Down || key === Qt.Key_PageUp || key === Qt.Key_PageDown) {
      move(key === Qt.Key_Up ? -1 : key === Qt.Key_Down ? 1 : key === Qt.Key_PageUp ? -6 : 6)
    } else if (key === Qt.Key_Home || key === Qt.Key_End) {
      moveTo(key === Qt.Key_Home ? 0 : rows.count - 1)
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      if (!cursorShown) cursorShown = rows.count > 0
      else use(cursor, alt ? "open" : shift ? "copy" : "paste")
    } else {
      return
    }
    event.accepted = true
  }

  History {
    id: history
    onEntriesChanged: clipboard.viewsStale = true
    onUpdated: if (clipboard.opened) clipboard.refresh()
  }

  ListModel { id: rows }

  PointerMoveGate {
    id: pointerGate
    referenceItem: picker.card
  }

  // ---------------------------------------------------------------- the card

  SearchPicker {
    id: picker
    surfaceName: "nova-clipboard"
    opened: clipboard.opened
    query: clipboard.query
    placeholder: "Search clipboard…"
    cardWidth: Style.space(875)
    cardHeight: Style.space(600)
    empty: rows.count === 0
    emptyGlyph: "\u{F014C}"
    emptyText: history.entries.length === 0 ? "Clipboard is empty" : "No matches for “" + clipboard.query + "”"

    onSearched: function (text) { clipboard.search(text) }
    onDismissed: clipboard.close()
    onKeyPressed: function (event) { clipboard.rowKeys(event) }

    dialog: ConfirmDialog {
      id: clearDialog
      parent: picker.card
      anchors.fill: parent
      z: 20
      opened: clipboard.confirmingClear
      message: "Delete entire clipboard history?"
      confirmText: "Delete"
      background: Commons.Color.menu.background
      foreground: Commons.Color.menu.text
      scrim: Commons.Color.menu.scrim
      selectedBackground: Commons.Color.menu.selectedBackground
      selectedText: Commons.Color.menu.selectedText
      fontFamily: Style.font.menuFamily
      cornerRadius: Style.cornerRadius
      onCanceled: clipboard.keepHistory()
      onConfirmed: clipboard.clear()
    }

    // The entries, a line each.
    Item {
      width: parent.width / 2
      height: parent.height
      clip: true

      ListView {
        id: list
        anchors.fill: parent
        anchors.rightMargin: Style.spacing.panelPadding
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

          readonly property bool hasCursor: clipboard.cursorShown && index === clipboard.cursor
          readonly property bool hasImage: previewImage.length > 0

          width: ListView.view.width
          height: clipboard.rowHeight
          radius: Style.cornerRadius
          color: hasCursor ? Commons.Color.menu.selectedBackground : "transparent"

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            anchors.topMargin: Style.space(8)
            anchors.bottomMargin: Style.space(8)
            spacing: Style.space(10)

            // Decoded at the row's size: the entry is the image copied, a
            // screenshot or a photo, and the history is always loaded.
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
              width: parent.width - (row.hasImage ? parent.height + parent.spacing : 0)
              height: parent.height
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              text: row.previewText
              color: row.hasCursor ? Commons.Color.menu.selectedText : Commons.Color.menu.text
              opacity: row.entryType === "image" || row.entryType === "file" ? 0.72 : 1.0
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              elide: Text.ElideRight
              wrapMode: Text.NoWrap
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: function (mouse) {
              clipboard.point(row.index, row, mouse)
            }
            onClicked: {
              clipboard.cursorShown = true
              clipboard.cursor = row.index
              clipboard.use(row.index, "paste")
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
      x: parent.width / 2
      width: parent.width / 2
      height: parent.height
      clip: true

      readonly property var entry: rows.count > 0 && clipboard.cursor >= 0 && clipboard.cursor < rows.count ? rows.get(clipboard.cursor) : null

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.normalBorderWidth
        color: Util.alpha(Commons.Color.menu.border, 0.28)
      }

      Text {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.panelPadding
        visible: pane.entry && !pane.entry.previewImage
        verticalAlignment: Text.AlignTop
        textFormat: Text.PlainText
        text: pane.entry ? pane.entry.fullText : ""
        color: Commons.Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.title
        wrapMode: Text.WrapAnywhere
        elide: Text.ElideRight
      }

      // At the pane's size, as the rows are at theirs.
      Image {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.panelPadding
        visible: pane.entry && pane.entry.previewImage
        source: pane.entry ? pane.entry.previewImage : ""
        sourceSize: Qt.size(width, height)
        fillMode: Image.PreserveAspectFit
        verticalAlignment: Image.AlignTop
        asynchronous: true
        smooth: true
      }
    }
  }
}
