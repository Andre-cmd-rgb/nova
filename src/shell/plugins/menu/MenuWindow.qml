import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "MenuModel.js" as MenuModel

// The menu's window, a layer over every other with the keys to itself: the
// screen shaded, and on it a card with what is shown at its head (the
// search, the menu's title or the chooser's prompt) over its rows. A click
// on the shade closes the menu.
PanelWindow {
  id: window

  required property var menu
  readonly property MenuLook look: MenuLook {}
  readonly property alias card: card
  readonly property alias question: question

  visible: menu.opened && menu.ready
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "nova-menu"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  // The card opens centred. The first key typed, or a menu walked into,
  // pins its top where it is: from then on it grows and shrinks downward
  // instead of jumping to a new centre each time, and the rows' height then
  // is the most they grow to. Hidden, or a menu or a chooser opened anew,
  // it is free again.
  property int pinnedTop: -1
  property int rowsCap: -1
  readonly property int top: pinnedTop >= 0 ? pinnedTop : Math.max(Style.gapsOut, Math.round((height - cardHeight) / 2))

  function pin() {
    if (!visible || pinnedTop >= 0) return
    pinnedTop = top
    rowsCap = rowsHeight
  }

  function unpin() {
    pinnedTop = -1
    rowsCap = -1
  }

  onVisibleChanged: if (!visible) unpin()

  // Screen Recording's and Font's rows are long, and get a wider card.
  readonly property var wideMenus: ["capture.screenrecord", "style.font"]
  readonly property int cardWidth: Math.min(Style.space(menu.choosing ? menu.chooser.width : wideMenus.includes(menu.here) ? 520 : 300), width - Style.gapsOut * 2)
  readonly property int rowsHeight: MenuModel.listHeight(menu.rows, roomForRows(), look.rows)
  readonly property int cardHeight: Math.min(look.padding * 2 + look.headerHeight + look.headerGap + rowsHeight, height - Style.gapsOut * 2)

  // The room the rows have before the card runs off the screen, from its
  // pinned top when it has one. Not from <top>: the centred top comes from
  // the card's height, which this decides. The menu the card opened on sets
  // the most it grows to, as a longer menu walked into scrolls instead; a
  // card past 70% of the screen reads as a page, not a menu; and a chooser
  // may ask for less.
  function roomForRows() {
    let room = height - (pinnedTop >= 0 ? pinnedTop : Style.gapsOut) - Style.gapsOut - look.padding * 2 - look.headerHeight - look.headerGap
    if (rowsCap >= 0) room = Math.min(room, rowsCap)
    room = Math.min(room, Math.round(height * 0.7))
    if (menu.choosing && menu.chooser.maxHeight > 0) room = Math.min(room, Style.space(menu.chooser.maxHeight))
    return room
  }

  // The list takes <rows> from its top. Rows put back into a list still
  // scrolled are laid out from where it was scrolled to, and its origin
  // would move that far on with each new list.
  function show(rows) {
    shown.clear()
    list.contentY = list.originY
    if (rows.length > 0) shown.append(rows)
  }

  // Scrolls the cursor's row into view with the next row's peek past it,
  // the way it moves: a row flush with the edge would hide the one beyond,
  // and the fold that says there is more.
  function reveal() {
    const at = menu.cursor
    if (shown.count === 0) return
    list.positionViewAtIndex(at, ListView.Contain)
    const lit = list.itemAtIndex(at)
    if (!lit) return
    const margin = look.peek + look.rowGap
    const lowest = Math.max(list.originY, list.originY + list.contentHeight - list.height)
    const pastBottom = lit.y + lit.height + margin - (list.contentY + list.height)
    if (at < shown.count - 1 && pastBottom > 0) list.contentY = Math.min(list.contentY + pastBottom, lowest)
    const pastTop = list.contentY - (lit.y - margin)
    if (at > 0 && pastTop > 0) list.contentY = Math.max(list.contentY - pastTop, list.originY)
  }

  function takeKeys() {
    card.forceActiveFocus()
  }

  ListModel { id: shown }

  Rectangle {
    anchors.fill: parent
    color: window.look.shade
  }

  MouseArea {
    anchors.fill: parent
    onClicked: window.menu.dismiss()
  }

  BorderSurface {
    id: card
    width: window.cardWidth
    height: Math.min(window.cardHeight, window.height - Style.gapsOut - window.top)
    radius: window.look.radius
    anchors.horizontalCenter: parent.horizontalCenter
    y: window.top
    color: window.look.paper
    borderSpec: window.look.frame
    padding: window.look.padding
    focus: true
    Keys.onPressed: function(event) {
      if (window.menu.press(event)) event.accepted = true
    }

    // A click on the card is not one on the shade.
    MouseArea { anchors.fill: parent; onClicked: {} }

    Column {
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      spacing: window.look.headerGap

      // What is typed, or the chooser's prompt or the menu's title.
      Item {
        width: parent.width
        height: window.look.headerHeight

        Text {
          width: parent.width
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: window.menu.typed || (window.menu.choosing ? window.menu.chooser.prompt : window.menu.title) + "…"
          color: window.look.ink
          opacity: window.menu.typed ? 1 : 0.58
          font.family: window.look.font
          font.pixelSize: Style.font.heading
          elide: Text.ElideRight
        }
      }

      Item {
        width: parent.width
        height: window.rowsHeight

        ListView {
          id: list
          // How far the rows go on past each edge.
          readonly property real pastTop: contentHeight > height ? contentY - originY : 0
          readonly property real pastBottom: contentHeight > height ? originY + contentHeight - height - contentY : 0
          anchors.fill: parent
          model: shown
          clip: true
          spacing: window.look.rowGap
          boundsBehavior: Flickable.StopAtBounds

          // A search's rows deeper than the menu, under a line.
          section.property: "section"
          section.criteria: ViewSection.FullString
          section.delegate: Item {
            required property string section
            width: ListView.view.width
            height: section === "deeper" ? window.look.dividerHeight : 0
            visible: section === "deeper"

            Rectangle {
              x: Style.space(4)
              y: (parent.height - height) / 2
              width: parent.width - x * 2
              height: Style.spacing.hairline
              color: Util.alpha(window.look.ink, 0.2)
            }
          }

          delegate: MenuRow {
            menu: window.menu
            look: window.look
          }
        }

        // The touchpad scrolls the list as GTK does.
        TouchpadScroll {
          anchors.fill: list
          flickable: list
        }

        // At rest the row cut short marks the fold; these follow the scroll,
        // so a jump from the last row to the first lands faded already.
        EdgeFade { paper: window.look.paper; past: list.pastTop; atTop: true }
        EdgeFade { paper: window.look.paper; past: list.pastBottom; atTop: false }

        Column {
          anchors.centerIn: parent
          spacing: Style.space(8)
          visible: shown.count === 0

          Text {
            width: Style.space(320)
            textFormat: Text.PlainText
            text: "󰈉"
            color: window.look.cursorInk
            opacity: 0.8
            font.family: window.look.font
            font.pixelSize: Style.font.displayLarge
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: Style.space(320)
            textFormat: Text.PlainText
            text: window.menu.typed ? "No matches for “" + window.menu.typed + "”" : "Nothing here yet"
            color: window.look.ink
            opacity: 0.7
            font.family: window.look.font
            font.pixelSize: Style.font.title
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }

    // Delete on an app asks this; while it is up it has the keys.
    ConfirmDialog {
      id: question
      anchors.fill: parent
      opened: window.menu.asking !== null
      message: "Do you want to uninstall " + (window.menu.asking ? window.menu.asking.label : "") + "?"
      confirmText: "Uninstall"
      background: window.look.paper
      foreground: window.look.ink
      scrim: window.look.shade
      selectedBackground: window.look.cursorPaper
      selectedText: window.look.cursorInk
      fontFamily: window.look.font
      cornerRadius: window.look.radius
      onCanceled: window.menu.keep()
      onConfirmed: window.menu.uninstall()
    }
  }

  // A fade at an edge the list has rows hidden past, as strong as how far
  // they go on, up to its own height.
  component EdgeFade: Rectangle {
    id: fade
    required property color paper
    required property real past
    required property bool atTop
    readonly property color clear: Util.alpha(paper, 0)
    width: parent.width
    height: Math.min(Style.space(28), parent.height / 2)
    y: atTop ? 0 : parent.height - height
    opacity: Math.max(0, Math.min(1, past / height))
    visible: opacity > 0
    gradient: Gradient {
      GradientStop { position: 0; color: fade.atTop ? fade.paper : fade.clear }
      GradientStop { position: 1; color: fade.atTop ? fade.clear : fade.paper }
    }
  }
}
