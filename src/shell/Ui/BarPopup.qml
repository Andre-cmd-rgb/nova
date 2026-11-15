import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "Popups.js" as Popups

// A card that pops out of a bar widget, <widget>, as a popup of the bar's
// own window: on the widget's far side from the screen's edge, a gap off it
// and centred on it, kept that gap from the bar's ends. Being a popup it
// hears the keyboard only once the pointer has been in it; a panel opened
// from the keyboard uses PanelSurface instead.
//
// <host> is the widget that holds it, and its key to the bar's one place for
// a popup: opening takes the place, closing gives it back, and close() goes
// through the host's own close() when it has one. A click anywhere but the
// card and the bar closes it. <wantWidth> and <wantHeight> are what the
// content would like, fitted to the screen (and the height to <tallest>
// when set); <edgeColor> stands in for the theme's popup border.
PopupWindow {
  id: popup

  required property Item widget
  required property Item host
  property bool open: false
  property real wantWidth: Style.space(280)
  property real wantHeight: 0
  property real tallest: 0
  property int padding: Style.spacing.popupPadding
  property color edgeColor: Commons.Color.popups.border

  default property alias content: card.content

  readonly property QtObject bar: host ? host.bar : null
  readonly property var _barWindow: widget ? widget.QsWindow.window : null
  readonly property var _screen: _barWindow ? _barWindow.screen : null
  readonly property string _edge: bar ? bar.position : "top"
  readonly property bool _lying: _edge === "top" || _edge === "bottom"

  function close() {
    Popups.dismiss(popup)
  }

  // Mapped through the fade out.
  visible: open || card.opacity > 0
  color: "transparent"
  // The room along each side: the screen, less the bar where it lies across
  // that side, less a gap at each end.
  implicitWidth: Popups.cardWidth(wantWidth, Popups.room(_screen ? _screen.width : 0, (_lying ? 0 : _barWindow?.width ?? 0) + Style.gapsOut, Style.gapsOut))
  implicitHeight: Popups.cardHeight(wantHeight, card.verticalInset, Popups.room(_screen ? _screen.height : 0, (_lying ? _barWindow?.height ?? 0 : 0) + Style.gapsOut, Style.gapsOut), tallest)

  // The bar has one card or panel open at a time.
  onOpenChanged: bar?.claimPopup(host || popup, open)

  // While Hyprland's focus grab holds, input goes to the card and the bar
  // alone; a click anywhere else clears it, and the card closes.
  HyprlandFocusGrab {
    active: popup.open
    windows: popup._barWindow ? [popup, popup._barWindow] : [popup]
    onCleared: popup.close()
  }

  // A one-pixel anchor at the card's corner, worked out in the bar window's
  // coordinates each time the popup is placed; the compositor slides it
  // back on screen should it stray.
  anchor {
    id: place
    window: popup._barWindow
    rect.width: 1
    rect.height: 1
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    adjustment: PopupAdjustment.Slide

    onAnchoring: {
      const w = popup.widget, win = popup._barWindow
      if (!w || !win || !popup.bar) return
      const gap = Style.gapsOut, cw = popup.implicitWidth, ch = popup.implicitHeight
      // Centred on the widget along the bar, a gap past it away from the
      // edge; then kept a gap inside the bar window's length.
      const along = popup._lying ? w.width / 2 - cw / 2 : w.height / 2 - ch / 2
      const away = { top: w.height + gap, bottom: -ch - gap, left: w.width + gap, right: -cw - gap }[popup._edge]
      const corner = win.contentItem.mapFromItem(w, popup._lying ? along : away, popup._lying ? away : along)
      place.rect.x = Math.round(popup._lying ? Popups.within(corner.x, cw, win.width, gap) : corner.x)
      place.rect.y = Math.round(popup._lying ? corner.y : Popups.within(corner.y, ch, win.height, gap))
    }
  }

  PopupFace {
    id: card
    anchors.fill: parent
    padding: popup.padding
    edgeColor: popup.edgeColor
    shown: popup.open
  }
}
