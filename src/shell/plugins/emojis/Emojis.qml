import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "EmojiSearch.js" as EmojiSearch

// The emoji picker (SUPER + CTRL + E): type to search, arrows to move, Enter
// or a click to type the emoji into the window that had the keys, through
// nova-menu-emoji-insert. It has the menu's colours.
Item {
  id: root

  property string novaPath: Quickshell.env("NOVA_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  // Every emoji, from emojis.json, and those the search shows, at most 1000.
  property var emojis: []
  property var results: []

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int contentSpacing: Style.spacing.md
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int cellSize: Math.max(Style.space(44), Style.font.display + Style.spacing.md)
  readonly property int columns: Math.floor((card.width - contentMargin * 2) / cellSize)

  function open(payloadJson) {
    opened = true
    search("")
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    opened = false
  }

  // Closed from inside: the shell is told, so its toggle opens it next.
  function dismiss() {
    opened = false
    if (shell && typeof shell.hide === "function") shell.hide((manifest && manifest.id) || "nova.emojis")
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  function search(text) {
    filterText = text
    selectedIndex = 0
    update()
  }

  function update() {
    results = EmojiSearch.search(emojis, filterText, 1000)
    selectedIndex = Math.max(0, Math.min(selectedIndex, results.length - 1))
    Qt.callLater(function () {
      if (root.results.length > 0) grid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
    })
  }

  // To <index>, kept within the results, and into view.
  function moveTo(index) {
    if (results.length === 0) return
    selectedIndex = Math.max(0, Math.min(index, results.length - 1))
    grid.positionViewAtIndex(selectedIndex, GridView.Contain)
  }

  function insert(index) {
    if (index < 0 || index >= results.length) return
    var emoji = results[index]
    dismiss()
    Quickshell.execDetached(["nova-menu-emoji-insert", emoji])
  }

  // emojis.json is made by tools/emoji-list from Unicode's data: Emoji 18.0's
  // emoji-test.txt and CLDR 49's English annotations.
  FileView {
    path: root.novaPath + "/shell/plugins/emojis/emojis.json"
    onLoaded: {
      root.emojis = EmojiSearch.parse(text())
      if (root.opened) root.update()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nova-emojis"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
    }

    // A click beside the card closes the picker; one on it does nothing.
    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(400), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(500), panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
      padding: root.contentMargin

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          var key = event.key
          if (key === Qt.Key_Escape) {
            if (root.filterText) root.search("")
            else root.dismiss()
          } else if (Util.editsFilter(event, root.filterText)) {
            root.search(Util.editedFilter(event, root.filterText))
          } else if (key === Qt.Key_Left || key === Qt.Key_Right) {
            if (root.results.length > 0)
              root.moveTo(Util.stepIndex(root.selectedIndex, key === Qt.Key_Left ? -1 : 1, root.results.length))
          } else if (key === Qt.Key_Up || key === Qt.Key_Down) {
            root.moveTo(root.selectedIndex + (key === Qt.Key_Up ? -1 : 1) * root.columns)
          } else if (key === Qt.Key_PageUp || key === Qt.Key_PageDown) {
            var rows = Math.max(1, Math.floor(grid.height / root.cellSize))
            root.moveTo(root.selectedIndex + (key === Qt.Key_PageUp ? -1 : 1) * root.columns * rows)
          } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            root.insert(root.selectedIndex)
          } else if (event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.search(root.filterText + event.text)
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Text {
          width: parent.width
          height: root.headerHeight
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: root.filterText || "Search emojis…"
          color: root.foreground
          opacity: root.filterText ? 1 : 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          elide: Text.ElideRight
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          GridView {
            id: grid
            anchors.fill: parent
            model: root.results
            clip: true
            cellWidth: root.cellSize
            cellHeight: root.cellSize
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: cell
              required property int index
              required property string modelData

              width: root.cellSize
              height: root.cellSize
              radius: Style.cornerRadius
              color: index === root.selectedIndex ? root.selectedBackground : "transparent"

              Text {
                anchors.centerIn: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
                text: cell.modelData
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.selectedIndex = cell.index
                onClicked: {
                  root.selectedIndex = cell.index
                  root.insert(cell.index)
                }
              }
            }
          }

          // The touchpad scrolls the grid as GTK does.
          TouchpadScroll {
            anchors.fill: grid
            flickable: grid
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: root.results.length === 0

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "\u{F0209}"
              color: Commons.Color.menu.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: "No matches for “" + root.filterText + "”"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
          }
        }
      }
    }
  }
}
