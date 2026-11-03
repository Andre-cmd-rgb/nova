import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The window the clipboard and the emoji picker are drawn in: a card over
// the dimmed screen, in the [menu] colours, the search on its first line
// and what the search finds under it, or a glyph and a line when it finds
// nothing. The card has the keys. Typing searches, edited as everywhere in
// the shell, and Escape clears the search, then closes; the picker's own
// keys come to keyPressed first, which accepts the ones it takes.
PanelWindow {
  id: picker

  required property string surfaceName
  property bool opened: false
  property string query: ""
  property string placeholder: ""
  // The card's size where the screen has room for it.
  property int cardWidth: 0
  property int cardHeight: 0
  // What the card shows when the search finds nothing.
  property bool empty: false
  property string emptyGlyph: ""
  property string emptyText: ""
  // A dialog over the card: while it is open, every key is its own.
  property Item dialog: null

  readonly property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int gap: Style.spacing.md
  property alias card: card
  // What the picker puts under the search goes here.
  default property alias content: found.data

  // The search as it is to be: typed, edited or cleared.
  signal searched(string text)
  // Escape on an empty search, or a click beside the card.
  signal dismissed()
  signal keyPressed(var event)

  function takeKeys() {
    keyCatcher.forceActiveFocus()
  }

  // A key that types a character: not a control character, not Delete.
  function types(event) {
    return event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
  }

  visible: opened
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: picker.surfaceName
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
    onClicked: picker.dismissed()
  }

  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: Math.min(picker.cardWidth, picker.width - Style.gapsOut * 2)
    height: Math.min(picker.cardHeight, picker.height - Style.gapsOut * 2)
    radius: Style.cornerRadius
    color: Commons.Color.menu.background
    borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
    padding: Style.spacing.panelPadding

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
        if (picker.dialog && picker.dialog.opened) {
          if (picker.dialog.handleKey(event)) event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape) {
          if (picker.query) picker.searched("")
          else picker.dismissed()
        } else if (Util.editsFilter(event, picker.query)) {
          picker.searched(Util.editedFilter(event, picker.query))
        } else {
          picker.keyPressed(event)
          if (event.accepted || !picker.types(event)) return
          picker.searched(picker.query + event.text)
        }
        event.accepted = true
      }
    }

    Column {
      anchors.fill: parent
      anchors.leftMargin: card.contentLeftInset
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      spacing: picker.gap

      // The search, or what it is for.
      Item {
        width: parent.width
        height: picker.headerHeight

        Text {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: picker.query || picker.placeholder
          color: Commons.Color.menu.text
          opacity: picker.query ? 1 : 0.58
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.heading
          elide: Text.ElideRight
        }
      }

      Item {
        id: found
        width: parent.width
        height: parent.height - picker.headerHeight - picker.gap

        // Above whatever the picker draws when it has nothing to show.
        Column {
          anchors.centerIn: parent
          z: 1
          spacing: Style.space(8)
          visible: picker.empty

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: picker.emptyGlyph
            color: Commons.Color.menu.selectedText
            opacity: 0.8
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: picker.emptyText
            color: Commons.Color.menu.text
            opacity: 0.7
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
          }
        }
      }
    }
  }
}
