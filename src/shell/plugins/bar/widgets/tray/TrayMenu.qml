import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "MenuEntries.js" as MenuEntries

// A tray icon's menu, drawn by the shell: QsMenuEntry.display() hands a
// menu to Qt's own, which Quickshell gives only to a shell in QApplication
// mode, and Nova's is not, so an app whose menu is all submenus could not be
// used. A submenu takes the place of the rows it opens from, under a heading
// with its name that leads back out. The first level leaves out an entry
// that only repeats the app's name, and ends with Quit, which ends the app
// for good (nova-tray-quit), when the app is one Quit can end.
//
// The card opens when the tray wants it (`wanted`) and it has something to
// show: an icon with no entry of its own and no Quit opens nothing, and one
// whose app fills its menu late opens once it has. It is as tall as the
// entries it shows, growing and shrinking as the app changes its menu while
// it is open (Steam fills its own after it opens), held only to the room the
// screen has below the bar. A menu taller than
// that scrolls, with a sign at the edge where more is out of sight, which
// scrolls on while it is pointed at: a row cut in half is never the only
// hint, as it once was for Steam's Exit Steam, under a card held to 420
// pixels.
BarPopup {
  id: card

  // The tray item whose menu it is, and whether the tray wants its menu open.
  property var item: null
  property bool wanted: false
  property color ink
  property string face

  // The submenus gone into, outermost first, each { lister, title }. Each
  // level keeps a lister (a QsMenuOpener) of its own: an entry belongs to the
  // lister of the level it is on, so one lister for all would free the very
  // entry it shows.
  property var trail: []
  readonly property var here: trail.length > 0 ? trail[trail.length - 1] : null
  readonly property real headingHeight: heading.visible ? heading.implicitHeight : 0
  readonly property real footerHeight: footer.visible ? footer.implicitHeight : 0

  // The entries of the level shown, as a list, and which of them are left
  // out (MenuEntries.leftOut): read by each row, by its index.
  readonly property var levelModel: here ? here.lister.children : entries
  readonly property var levelEntries: Array.isArray(levelModel) ? levelModel : levelModel ? levelModel.values : []
  readonly property var leftOut: MenuEntries.leftOut(levelEntries, here === null,
    item ? String(item.title || item.id || "") : "")

  // Whether more of the level is out of sight above the rows, or below.
  readonly property bool moreAbove: rows.contentY > 0.5
  readonly property bool moreBelow: rows.contentY + rows.height < rows.contentHeight - 0.5

  // Whether Quit can end the app behind the icon, and the app's name to say
  // it by (none when the app has none to go by): nova-tray-quit's answer,
  // asked each time the menu opens, as the app may have gone or come back.
  property bool canQuit: false
  property string quitName: ""
  // The number of the last question asked, which only its answer carries,
  // and the questions still out, each a process of its own until it is over
  // (read by the tests: one never over would stay for good).
  property int asked: 0
  property int asking: 0

  // A new level is drawn at once, so its row under the pointer would take a
  // second click meant for the row before it: clicks wait 250 ms after each
  // change of level.
  property bool steadying: false

  // The menu's measures: a row's height and a separator's; the column of
  // the tick, where an icon starts and how big it is, where the words start
  // with an icon and without; the margin at each end of a row; how fast the
  // rows glide while a sign of more is pointed at. What the app turns off
  // and the separators are drawn faint; the card's edge is every bar card's.
  readonly property int rowHeight: Style.space(30)
  readonly property int lineHeight: Style.space(11)
  readonly property int tickWidth: Style.space(22)
  readonly property int iconStart: Style.space(24)
  readonly property int iconSize: Style.space(16)
  readonly property int wordsStart: Style.space(28)
  readonly property int wordsAfterIcon: Style.space(46)
  readonly property int rowEnd: Style.space(10)
  readonly property int moreHeight: Style.space(20)
  readonly property real glide: Style.space(400)
  readonly property real faint: 0.45

  // Nothing to show: no entry at the first level but separators and those
  // left out, and no Quit, or not yet. From the entries, not the rows'
  // height, which follows the card's own visibility.
  readonly property bool empty: here === null && !canQuit
    && !levelEntries.some((one, i) => one && !one.isSeparator && leftOut[i] !== true)

  signal chosen()

  // The menu of <source>, from its first level. The levels go first: the
  // old item's entries go with it, and the listers hold some of them.
  function load(source) {
    rewind()
    item = source
    askQuit()
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

  // Asks nova-tray-quit whether the app behind the icon can be quit: no Quit
  // row until it says so. An answer to an earlier question, about an icon
  // the card may no longer show, is not heard.
  function askQuit() {
    canQuit = false
    quitName = ""
    asked += 1
    if (!item) return
    quitAsker.createObject(card, { number: asked, command: ["nova-tray-quit", "check", String(item.id || ""), String(item.title || "")] })
  }

  function heard(number, can, said) {
    if (number !== asked) return
    canQuit = can
    quitName = can ? String(said || "").split("\n")[0].trim() : ""
  }

  // Ends the app, at once, as the app's own Exit would, and closes the card.
  // nova-tray-quit asks it to end and makes sure it has after a grace; it
  // finds the app again by itself, so a click on an icon whose app went
  // meanwhile ends nothing.
  function quit() {
    if (!canQuit || !item) return
    Quickshell.execDetached(["nova-tray-quit", "quit", String(item.id || ""), String(item.title || "")])
    chosen()
  }

  open: wanted && !empty
  padding: Style.space(8)
  wantWidth: Style.space(232)
  wantHeight: headingHeight + list.implicitHeight + footerHeight

  // The card fades out over 140 ms, still visible: it goes back to the first
  // level once it has gone, as a submenu swapped for that mid-fade would
  // flash and move.
  onVisibleChanged: if (!visible) rewind()

  // Not drawn, so kept out of the card's content, which takes only items.
  readonly property QsMenuOpener firstLevel: QsMenuOpener {
    menu: card.item ? card.item.menu : null
  }

  // The first level's entries, and what lists a submenu's (its `children`):
  // the app's menu over the bus, or a test's stand-in.
  property var entries: firstLevel.children
  property Component listerKind: Component {
    QsMenuOpener {}
  }

  // One question to nova-tray-quit: the name on its first line when it can
  // quit the app, which it says by ending well. One that cannot start is
  // never heard to exit, only to stop running (docs/ARCHITECTURE.md), and
  // goes all the same: a no, heard once.
  readonly property Component quitAsker: Component {
    Process {
      id: asker
      property int number: 0
      property bool done: false
      running: true
      stdout: StdioCollector { id: said }
      Component.onCompleted: card.asking++
      onExited: code => asker.end(code === 0)
      onRunningChanged: if (!running) asker.end(false)

      function end(can) {
        if (done) return
        done = true
        card.asking--
        card.heard(asker.number, can, said.text)
        asker.destroy()
      }
    }
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
        implicitHeight: card.rowHeight

        Lit { on: back.containsMouse }

        Words {
          width: card.tickWidth
          horizontalAlignment: Text.AlignHCenter
          text: "‹"
        }

        Words {
          anchors.leftMargin: card.wordsStart
          anchors.right: parent.right
          anchors.rightMargin: card.rowEnd
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
        implicitHeight: card.lineHeight

        Line {}
      }
    }

    // The rows, with a sign over each end that has more out of sight.
    Item {
      width: frame.width
      height: frame.height - card.headingHeight - card.footerHeight

      Flickable {
        id: rows
        anchors.fill: parent
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
            model: card.levelModel

            Entry {}
          }
        }
      }

      More {
        anchors.top: parent.top
        shown: card.moreAbove
        glyph: ""
        toward: 0
      }

      More {
        anchors.bottom: parent.bottom
        shown: card.moreBelow
        glyph: ""
        toward: Math.max(0, rows.contentHeight - rows.height)
      }
    }

    // On the first level, under the app's entries: Quit, set apart by a line
    // when the app has entries of its own.
    Column {
      id: footer
      width: frame.width
      visible: card.here === null && card.canQuit

      Item {
        width: footer.width
        implicitHeight: list.implicitHeight > 0 ? card.lineHeight : 0
        visible: list.implicitHeight > 0

        Line {}
      }

      Item {
        width: footer.width
        implicitHeight: card.rowHeight

        Lit { on: quitter.containsMouse }

        // In line with the app's words above it; on its own, at the row's
        // margin, as there is no tick to leave room for.
        Words {
          anchors.leftMargin: list.implicitHeight > 0 ? card.wordsStart : card.rowEnd
          anchors.right: parent.right
          anchors.rightMargin: card.rowEnd
          text: card.quitName !== "" ? "Quit " + card.quitName : "Quit"
          elide: Text.ElideRight
        }

        MouseArea {
          id: quitter
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (!card.steadying) card.quit()
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

    visible: card.leftOut[index] !== true
    width: list.width
    implicitHeight: line ? card.lineHeight : card.rowHeight
    opacity: modelData.enabled ? 1 : card.faint

    Line { visible: entry.line }

    Item {
      anchors.fill: parent
      visible: !entry.line

      Lit { on: pointer.containsMouse && entry.modelData.enabled }

      Words {
        visible: entry.modelData.buttonType !== QsMenuButtonType.None
        width: card.tickWidth
        horizontalAlignment: Text.AlignHCenter
        text: entry.modelData.checkState === Qt.Checked ? "" : ""
      }

      Image {
        id: picture
        visible: String(entry.modelData.icon || "") !== ""
        anchors.left: parent.left
        anchors.leftMargin: card.iconStart
        anchors.verticalCenter: parent.verticalCenter
        width: card.iconSize
        height: card.iconSize
        // At the screen's pixels: at the logical size a PNG blurs on HiDPI.
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        fillMode: Image.PreserveAspectFit
        source: entry.modelData.icon
      }

      Words {
        anchors.leftMargin: picture.visible ? card.wordsAfterIcon : card.wordsStart
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
        anchors.rightMargin: card.rowEnd
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

  // The sign at an end of the rows that has more out of sight: a chevron in
  // the words' own ink, not faint, on the card's own fill, over the row it
  // would cut. Pointed at, the rows
  // glide on to <toward> until the end comes or the pointer leaves; the
  // wheel and the scroll bar scroll them too.
  component More: Rectangle {
    id: more

    property bool shown: false
    property string glyph
    property real toward: 0

    width: parent.width
    height: card.moreHeight
    visible: shown
    color: Commons.Color.popups.background

    Words {
      anchors.left: undefined
      anchors.horizontalCenter: parent.horizontalCenter
      text: more.glyph
      font.bold: true
    }

    MouseArea {
      id: hand
      anchors.fill: parent
      hoverEnabled: true
    }

    NumberAnimation {
      target: rows
      property: "contentY"
      to: more.toward
      duration: Math.max(1, Math.abs(more.toward - rows.contentY) / card.glide * 1000)
      running: more.shown && hand.containsMouse
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
    anchors.leftMargin: card.rowEnd
    anchors.right: parent.right
    anchors.rightMargin: card.rowEnd
    anchors.verticalCenter: parent.verticalCenter
    height: 1
    color: Commons.Color.popups.border
    opacity: card.faint
  }
}
