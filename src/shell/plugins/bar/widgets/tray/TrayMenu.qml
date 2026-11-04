import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A tray icon's menu, drawn by the shell: QsMenuEntry.display() hands a
// menu to Qt's own, which Quickshell gives only to a shell in QApplication
// mode, and Nova's is not, so an app whose menu is all submenus could not be
// used. A submenu takes the place of the rows it opens from, under a heading
// with its name that leads back out. The first level leaves out an entry
// that only repeats the app's name, and a separator at its top.
PopupCard {
  id: card

  // The tray item whose menu it is.
  property var item: null
  property color ink
  property string face

  // The submenus gone into, outermost first, each { lister, title }. Each
  // level keeps a lister (a QsMenuOpener) of its own: an entry belongs to the
  // lister of the level it is on, so one lister for all would free the very
  // entry it shows.
  property var trail: []
  readonly property var here: trail.length > 0 ? trail[trail.length - 1] : null
  readonly property real headingHeight: heading.visible ? heading.implicitHeight : 0

  // A new level is drawn at once, so its row under the pointer would take a
  // second click meant for the row before it: clicks wait 250 ms after each
  // change of level.
  property bool steadying: false

  signal chosen()

  // The menu of <source>, from its first level. The levels go first: the
  // old item's entries go with it, and the listers hold some of them.
  function load(source) {
    rewind()
    item = source
  }

  // Into the submenu of <entry>, called <title>, and out of it.
  function descend(entry, title) {
    // Before the rows change, so the level shows from its top, and while the
    // row clicked is still there.
    rows.contentY = 0
    var lister = listerKind.createObject(card, { menu: entry })
    if (!lister) return
    trail = trail.concat([{ lister: lister, title: title }])
    steady()
  }

  function ascend() {
    if (!here) return
    rows.contentY = 0
    var left = here
    trail = trail.slice(0, -1)
    left.lister.destroy()
    steady()
  }

  // Back to the first level, scrolled to its top: a Flickable keeps its
  // place across a new model tall enough, so a menu closed scrolled down
  // would open scrolled down. The trail empties before a lister goes, so
  // that no binding reads one half freed, and the innermost goes first, as
  // its entry is its parent's.
  function rewind() {
    steadying = false
    steadyClock.stop()
    rows.contentY = 0
    var gone = trail
    trail = []
    for (var i = gone.length - 1; i >= 0; i--) gone[i].lister.destroy()
  }

  function steady() {
    steadying = true
    steadyClock.restart()
  }

  padding: Style.space(8)
  borderColor: Qt.rgba(ink.r, ink.g, ink.b, 0.45)
  contentWidth: fittedContentWidth(Style.space(232))
  contentHeight: fittedContentHeight(headingHeight + list.implicitHeight, Style.space(420))

  // The card fades out over 140 ms, still visible: it goes back to the first
  // level once it has gone, as a submenu swapped for that mid-fade would
  // flash and move.
  onVisibleChanged: if (!visible) rewind()

  // Not drawn, so kept out of the card's content, which takes only items.
  readonly property QsMenuOpener firstLevel: QsMenuOpener {
    menu: card.item ? card.item.menu : null
  }

  readonly property Component listerKind: Component {
    QsMenuOpener {}
  }

  readonly property Timer steadyClock: Timer {
    interval: 250
    onTriggered: card.steadying = false
  }

  Column {
    id: frame
    anchors.fill: parent

    // In a submenu, its name, leading back out: above the rows rather than
    // scrolled with them, so the way back is always in sight.
    Column {
      id: heading
      width: frame.width
      visible: card.here !== null

      Item {
        width: heading.width
        implicitHeight: Style.space(30)

        Lit { on: back.containsMouse }

        Words {
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          text: "‹"
        }

        Words {
          anchors.leftMargin: Style.space(28)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          text: card.here ? card.here.title : ""
          elide: Text.ElideRight
        }

        MouseArea {
          id: back
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (!card.steadying) card.ascend()
        }
      }

      Item {
        width: heading.width
        implicitHeight: Style.space(11)

        Line {}
      }
    }

    Flickable {
      id: rows
      width: frame.width
      height: frame.height - card.headingHeight
      contentWidth: width
      contentHeight: list.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height

      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: list
        width: rows.width

        Repeater {
          model: card.here ? card.here.lister.children : firstLevel.children

          Entry {}
        }
      }
    }
  }

  // One entry: a separator's line, or a row with a tick for a check or radio
  // entry, its icon, its words and an arrow for a submenu. One the app turns
  // off is faded and takes no click.
  component Entry: Item {
    id: entry

    required property var modelData
    required property int index
    readonly property string words: String(modelData.text || "")
    readonly property bool line: modelData.isSeparator
    readonly property bool repeat: {
      if (card.here !== null) return false
      if (line) return index <= 1
      var app = card.item ? String(card.item.title || card.item.id || "") : ""
      return index === 0 && modelData.hasChildren && words.toLowerCase() === app.toLowerCase()
    }

    visible: !repeat
    width: list.width
    implicitHeight: line ? Style.space(11) : Style.space(30)
    opacity: modelData.enabled ? 1.0 : 0.45

    Line { visible: entry.line }

    Item {
      anchors.fill: parent
      visible: !entry.line

      Lit { on: pointer.containsMouse && entry.modelData.enabled }

      Words {
        visible: entry.modelData.buttonType !== QsMenuButtonType.None
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        text: entry.modelData.checkState === Qt.Checked ? "\uf00c" : ""
      }

      Image {
        id: picture
        visible: String(entry.modelData.icon || "") !== ""
        anchors.left: parent.left
        anchors.leftMargin: Style.space(24)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16)
        height: Style.space(16)
        // At the screen's pixels: at the logical size a PNG blurs on HiDPI.
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        fillMode: Image.PreserveAspectFit
        source: entry.modelData.icon
      }

      Words {
        anchors.leftMargin: picture.visible ? Style.space(46) : Style.space(28)
        anchors.right: arrow.left
        anchors.rightMargin: Style.space(8)
        text: entry.words
        elide: Text.ElideRight
      }

      Words {
        id: arrow
        visible: entry.modelData.hasChildren
        anchors.left: undefined
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        text: "›"
      }

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        enabled: entry.modelData.enabled
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
          if (card.steadying) return
          if (entry.modelData.hasChildren) {
            card.descend(entry.modelData, entry.words)
            return
          }
          entry.modelData.triggered()
          card.chosen()
        }
      }
    }
  }

  // Words in a row, at its left unless placed otherwise.
  component Words: Text {
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    color: card.ink
    font.family: card.face
    font.pixelSize: Style.font.bodySmall
  }

  // The fill of a row under the pointer.
  component Lit: Rectangle {
    property bool on: false
    anchors.fill: parent
    radius: Math.max(2, Style.cornerRadius)
    color: on ? Style.hoverFillFor(card.ink, card.ink) : "transparent"
  }

  // A separator's line.
  component Line: Rectangle {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    height: 1
    color: Commons.Color.popups.border
    opacity: 0.45
  }
}
