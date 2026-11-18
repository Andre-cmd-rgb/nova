import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "Popups.js" as Popups

// A card that pops out of a bar widget, <widget>, as a popup of the bar's
// own window: below the widget, a gap off it and centred on it, kept that
// gap from the bar's ends. Being a popup it
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

  function close() {
    Popups.dismiss(popup)
  }

  // Mapped through the fade out.
  visible: open || card.opacity > 0
  color: "transparent"
  // The room along each side: the screen, less the bar across its top, less
  // a gap at each end.
  implicitWidth: Popups.cardWidth(wantWidth, Popups.room(_screen ? _screen.width : 0, Style.gapsOut, Style.gapsOut))
  implicitHeight: Popups.cardHeight(wantHeight, card.verticalInset, Popups.room(_screen ? _screen.height : 0, (_barWindow?.height ?? 0) + Style.gapsOut, Style.gapsOut), tallest)

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
      // Centred on the widget, a gap below it; then kept a gap inside the
      // bar window's length.
      const corner = win.contentItem.mapFromItem(w, w.width / 2 - cw / 2, w.height + gap)
      place.rect.x = Math.round(Popups.within(corner.x, cw, win.width, gap))
      place.rect.y = Math.round(corner.y)
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
