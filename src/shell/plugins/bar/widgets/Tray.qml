import QtQuick
import Quickshell.Services.SystemTray
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "tray"
import "tray/Shelves.js" as Shelves

// The system tray. An icon pinned stays on the bar; the rest wait in a
// drawer behind a chevron, which slides open while the pointer is on it. The
// chevron's right click lists every icon, to pin or hide; an icon's opens
// its menu (TrayMenu).
BarWidget {
  id: tray
  moduleName: "nova.tray"

  readonly property color ink: bar ? bar.foreground : Commons.Color.foreground
  readonly property string face: bar ? bar.fontFamily : Style.font.family

  // The widget's settings: the ids pinned, and those hidden.
  readonly property var pinned: Shelves.list(settings.pinned)
  readonly property var hidden: Shelves.list(settings.hidden)

  // The icons that ask to be seen (a passive one does not), and those of
  // them on the bar and in the drawer.
  readonly property var icons: SystemTray.items.values.filter(item => item.status !== Status.Passive)
  readonly property var onBar: icons.filter(item => shelfOf(item) === "pinned")
  readonly property var inDrawer: icons.filter(item => shelfOf(item) === "drawer")

  function shelfOf(item) {
    return Shelves.shelf(String(item.id || ""), pinned, hidden)
  }

  // Writes the two lists back to the widget's entry in shell.json, which
  // hands them back through <settings>.
  function keep(lists) {
    var name = moduleName || "nova.tray"
    if (typeof bar?.shell?.updateEntryInline === "function")
      bar.shell.updateEntryInline(name, { id: name, pinned: lists.pinned, hidden: lists.hidden })
  }

  // ----- the cards -----

  // The card open: "pins", the list of icons, "menu", an icon's menu, or
  // none. One at a time, as on the rest of the bar: both are the tray's,
  // so the bar would not close one for the other.
  property string card: ""
  // The icon whose menu is open.
  property Item menuTile: null

  // The bar's way to close the tray's card, and the cards' own.
  function close() {
    card = ""
  }

  // The card that was open goes first, giving the bar back the tray's place,
  // which the new one then takes.
  function show(which) {
    if (card !== which) card = ""
    card = which
  }

  function openMenu(tile) {
    // An icon with no menu has none to open: Quickshell shows only a menu
    // an app hands over.
    if (!tile.modelData.menu) return
    menu.load(tile.modelData)
    menuTile = tile
    show("menu")
  }

  TrayPins {
    anchorItem: tray
    owner: tray
    bar: tray.bar
    open: tray.card === "pins"
    icons: tray.icons
    pinned: tray.pinned
    hidden: tray.hidden
    ink: tray.ink
    face: tray.face
    onFlip: (onto, id) => tray.keep(Shelves.flipped({ pinned: tray.pinned, hidden: tray.hidden }, onto, id))
  }

  TrayMenu {
    id: menu
    anchorItem: tray.menuTile || tray
    owner: tray
    bar: tray.bar
    open: tray.card === "menu"
    ink: tray.ink
    face: tray.face
    onChosen: tray.close()
  }

  // ----- the bar -----

  // Lengths along the bar. An icon takes a slot; the drawer, its icons'
  // slots and the chevron's, the chevron alone once every icon is pinned,
  // and nothing while the tray has no icon at all.
  readonly property int slot: Style.bar.iconSlot
  readonly property int drawerRoom: inDrawer.length * slot
  readonly property int drawerLength: icons.length > 0 ? (vertical ? chevron.implicitHeight : chevron.implicitWidth) + drawerRoom : 0
  readonly property int frontLength: vertical ? front.implicitHeight : front.implicitWidth

  // How far the drawer is open, 0 to 1, over 600 ms; how much of its room
  // stays shut, which is where the chevron sits.
  property bool reaching: false
  property real opening: reaching ? 1 : 0
  readonly property real shut: drawerRoom - drawerRoom * opening

  Behavior on opening {
    NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
  }

  visible: onBar.length > 0 || inDrawer.length > 0
  implicitWidth: vertical ? barSize : drawerLength + frontLength
  implicitHeight: vertical ? drawerLength + frontLength : barSize

  // The chevron, then the drawer it slides back over as it opens.
  Item {
    id: drawer
    visible: tray.icons.length > 0
    width: tray.vertical ? tray.barSize : tray.drawerLength
    height: tray.vertical ? tray.drawerLength : tray.barSize

    // The room a shut drawer keeps is not the tray's: the pointer there
    // does not open it. Only the chevron and what it has uncovered count.
    containmentMask: QtObject {
      function contains(point: point): bool {
        var across = tray.vertical ? point.x : point.y
        var along = tray.vertical ? point.y : point.x
        return across >= 0 && across <= tray.barSize && along >= tray.shut && along <= tray.drawerLength
      }
    }

    HoverHandler {
      onHoveredChanged: tray.reaching = hovered
    }

    BarIconButton {
      id: chevron
      bar: tray.bar
      width: implicitWidth
      height: implicitHeight
      x: tray.vertical ? 0 : tray.shut
      y: tray.vertical ? tray.shut : 0
      text: "\uf053"
      textRotation: tray.vertical ? 90 : 0
      onPressed: button => {
        if (button === Qt.RightButton) tray.show(tray.card === "pins" ? "" : "pins")
      }
    }

    // The drawer's icons, cut to its room and moved with the chevron.
    Item {
      x: tray.vertical ? 0 : chevron.width
      y: tray.vertical ? chevron.height : 0
      width: tray.vertical ? tray.barSize : tray.drawerRoom
      height: tray.vertical ? tray.drawerRoom : tray.barSize
      clip: true

      Shelf {
        icons: tray.inDrawer
        lead: tray.shut
        layer.enabled: true
      }
    }
  }

  Shelf {
    id: front
    icons: tray.onBar
    lead: tray.drawerLength
  }

  // Icons in a line along the bar, <lead> from the start of the item it
  // is in and centred across it.
  component Shelf: Grid {
    id: shelf

    property var icons: []
    property real lead: 0

    rows: tray.vertical ? -1 : 1
    columns: tray.vertical ? 1 : -1
    anchors.left: tray.vertical ? undefined : parent.left
    anchors.leftMargin: lead
    anchors.verticalCenter: tray.vertical ? undefined : parent.verticalCenter
    anchors.top: tray.vertical ? parent.top : undefined
    anchors.topMargin: lead
    anchors.horizontalCenter: tray.vertical ? parent.horizontalCenter : undefined

    Repeater {
      model: shelf.icons

      Tile {}
    }
  }

  // One icon. A click starts its app, or opens its menu when the icon is
  // only a menu; a middle click does its second action, the wheel scrolls
  // it, a right click opens its menu.
  component Tile: Item {
    id: tile

    required property var modelData
    // Read by the bar, which shows the tooltip while it holds.
    readonly property bool tooltipHovered: visible && opacity > 0 && hand.containsMouse

    implicitWidth: tray.slot
    implicitHeight: tray.slot

    TrayGlyph {
      anchors.centerIn: parent
      width: Style.space(12)
      height: Style.space(12)
      source: tile.modelData.icon
      tint: tray.ink
    }

    MouseArea {
      id: hand
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onEntered: tray.bar?.showTooltip(tile, tile.modelData.tooltipTitle || tile.modelData.title || tile.modelData.id || "")
      onExited: tray.bar?.hideTooltip(tile)
      // The tooltip goes on a press, as on the bar's buttons: left up, it
      // would sit over the menu.
      onPressed: mouse => {
        tray.bar?.hideTooltip(tile)
        if (mouse.button === Qt.RightButton) tray.openMenu(tile)
      }
      onClicked: mouse => {
        if (mouse.button === Qt.MiddleButton) tile.modelData.secondaryActivate()
        else if (mouse.button === Qt.LeftButton && tile.modelData.onlyMenu) tray.openMenu(tile)
        else if (mouse.button === Qt.LeftButton) tile.modelData.activate()
      }
      onWheel: wheel => tile.modelData.scroll(wheel.angleDelta.y, false)
    }
  }
}
