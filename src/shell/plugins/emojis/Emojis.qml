import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../clipboard" as Clipboard
import "EmojiSearch.js" as EmojiSearch

// The emoji picker (SUPER + CTRL + E), drawn as the clipboard is: type to
// search, the arrows to move, Return or a click to type the emoji into the
// window that had the keys, through nova-menu-emoji-insert.
Item {
  id: emojis

  property var shell: null
  property var manifest: null
  property bool opened: false

  // Every emoji in emojis.json, and the ones the search finds, 1000 at most.
  property var all: []
  property string query: ""
  property var found: []
  property int cursor: 0

  readonly property int cellSize: Math.max(Style.space(44), Style.font.display + Style.spacing.md)
  // The grid's columns, for Up and Down: as many as GridView lays out in
  // its width, one at least.
  readonly property int columns: Math.max(1, Math.floor(grid.width / cellSize))

  // The shell's summon and hide.
  function open(payloadJson) {
    opened = true
    search("")
    Qt.callLater(picker.takeKeys)
  }

  function close() {
    opened = false
  }

  // Closed from inside: the shell is told, so that its toggle opens it next.
  function dismiss() {
    opened = false
    if (shell && typeof shell.hide === "function") shell.hide((manifest && manifest.id) || "nova.emojis")
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  // ---------------------------------------------------------------- search

  function search(text) {
    query = text
    cursor = 0
    find()
  }

  // The search run again, on the same query or on emojis just loaded.
  function find() {
    found = EmojiSearch.search(all, query, 1000)
    cursor = Math.max(0, Math.min(cursor, found.length - 1))
    pointerGate.reset()
    Qt.callLater(function () {
      if (emojis.found.length > 0) grid.positionViewAtIndex(emojis.cursor, GridView.Contain)
    })
  }

  // The cursor to <index>, kept within what was found, and in view.
  function moveTo(index) {
    if (found.length === 0) return
    cursor = Math.max(0, Math.min(index, found.length - 1))
    pointerGate.reset()
    grid.positionViewAtIndex(cursor, GridView.Contain)
  }

  // The pointer takes the cursor only when it moves itself, not when the
  // grid scrolls, or a search fills it again, under a pointer at rest.
  function point(index, cell, mouse) {
    if (pointerGate.moved(cell, mouse)) cursor = index
  }

  function insert(index) {
    if (index < 0 || index >= found.length) return
    var emoji = found[index]
    dismiss()
    Quickshell.execDetached(["nova-menu-emoji-insert", emoji])
  }

  // Left and Right step through the emojis, round the ends; Up and Down go
  // a row, Page Up and Page Down a grid's height, stopping at the ends.
  function stepKeys(event) {
    var key = event.key
    if (key === Qt.Key_Left || key === Qt.Key_Right) {
      if (found.length > 0) moveTo(Util.stepIndex(cursor, key === Qt.Key_Left ? -1 : 1, found.length))
    } else if (key === Qt.Key_Up || key === Qt.Key_Down) {
      moveTo(cursor + (key === Qt.Key_Up ? -1 : 1) * columns)
    } else if (key === Qt.Key_PageUp || key === Qt.Key_PageDown) {
      var rows = Math.max(1, Math.floor(grid.height / cellSize))
      moveTo(cursor + (key === Qt.Key_PageUp ? -1 : 1) * columns * rows)
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      insert(cursor)
    } else {
      return
    }
    event.accepted = true
  }

  // emojis.json is made by tools/emoji-list from Unicode's data: Emoji
  // 18.0's emoji-test.txt and CLDR 49's English annotations.
  PointerMoveGate {
    id: pointerGate
    referenceItem: picker.card
  }

  FileView {
    path: Quickshell.env("NOVA_PATH") + "/shell/plugins/emojis/emojis.json"
    onLoaded: {
      emojis.all = EmojiSearch.parse(text())
      if (emojis.opened) emojis.find()
    }
  }

  // ---------------------------------------------------------------- the card

  Clipboard.SearchPicker {
    id: picker
    surfaceName: "nova-emojis"
    opened: emojis.opened
    query: emojis.query
    placeholder: "Search emojis…"
    cardWidth: Style.space(400)
    cardHeight: Style.space(500)
    empty: emojis.found.length === 0
    emptyGlyph: "\u{F0209}"
    emptyText: "No matches for “" + emojis.query + "”"

    onSearched: function (text) { emojis.search(text) }
    onDismissed: emojis.dismiss()
    onKeyPressed: function (event) { emojis.stepKeys(event) }

    GridView {
      id: grid
      anchors.fill: parent
      model: emojis.found
      clip: true
      cellWidth: emojis.cellSize
      cellHeight: emojis.cellSize
      boundsBehavior: Flickable.StopAtBounds

      delegate: Rectangle {
        id: cell
        required property int index
        required property string modelData

        width: emojis.cellSize
        height: emojis.cellSize
        radius: Style.cornerRadius
        color: index === emojis.cursor ? Commons.Color.menu.selectedBackground : "transparent"

        Text {
          anchors.centerIn: parent
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: cell.modelData
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.display
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPositionChanged: function (mouse) {
            emojis.point(cell.index, cell, mouse)
          }
          onClicked: {
            emojis.cursor = cell.index
            emojis.insert(cell.index)
          }
        }
      }
    }

    // The touchpad scrolls the grid as GTK does.
    TouchpadScroll {
      anchors.fill: grid
      flickable: grid
    }
  }
}
