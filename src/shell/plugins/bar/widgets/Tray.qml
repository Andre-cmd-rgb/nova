import QtQuick
import Quickshell.Services.SystemTray
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "tray"
import "tray/TrayList.js" as TrayList

// The system tray: the icon of every app that asks to be seen, in a row, in
// the order of their ids. A click starts the app, a middle click does its
// second action, a right click opens its menu (TrayMenu), which ends with
// Hide from Menu Bar. The widget's `hidden` setting lists the ids hidden,
// and `names` what each is called; Settings → Menu Bar brings them back.
BarWidget {
  id: tray
  widgetId: "nova.tray"

  readonly property color ink: bar ? bar.foreground : Commons.Color.foreground
  readonly property string face: bar ? bar.fontFamily : Style.font.family

  // The ids hidden, and the icons that ask to be seen (a passive one does
  // not) and are not.
  readonly property var hidden: TrayList.list(settings.hidden)
  readonly property var icons: TrayList.shown(SystemTray.items.values.filter(item => item.status !== Status.Passive), hidden)

  // Writes the ids hidden, and the app's name, into the widget's entry in
  // shell.json, which hands them back through <settings>.
  function hide(item) {
    var name = widgetId || "nova.tray"
    var id = String(item && item.id || "")
    if (typeof bar?.shell?.updateEntryInline === "function")
      bar.shell.updateEntryInline(name, Object.assign({}, settings, { id: name, hidden: TrayList.hide(hidden, id), names: TrayList.named(settings.names, id, item) }))
  }

  // The icon whose menu is open, and the menu's card; the card is the tray's
  // own, so the bar does not close it for another.
  property Item menuTile: null
  property bool menuOpen: false

  // The bar's way to close the tray's card, and the card's own.
  function close() {
    menuOpen = false
  }

  // A menu open for another icon goes first, giving the bar back the tray's
  // place, which the new one then takes.
  function openMenu(tile) {
    menuOpen = false
    menu.load(tile.modelData)
    menuTile = tile
    menuOpen = true
  }

  TrayMenu {
    id: menu
    widget: tray.menuTile || tray
    host: tray
    open: tray.menuOpen
    ink: tray.ink
    face: tray.face
    onChosen: tray.close()
    onHideRequested: {
      tray.hide(menu.item)
      tray.close()
    }
  }

  // ----- the bar -----

  readonly property int slot: Style.bar.iconSlot

  visible: icons.length > 0
  implicitWidth: row.implicitWidth
  implicitHeight: thickness

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter

    Repeater {
      model: tray.icons

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
    readonly property bool pointedAt: visible && opacity > 0 && hand.containsMouse

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

      onEntered: tray.bar?.tip.ask(tile, tile.modelData.tooltipTitle || tile.modelData.title || tile.modelData.id || "")
      onExited: tray.bar?.tip.withdraw(tile)
      // The tooltip goes on a press, as on the bar's buttons: left up, it
      // would sit over the menu.
      onPressed: mouse => {
        tray.bar?.tip.withdraw(tile)
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
