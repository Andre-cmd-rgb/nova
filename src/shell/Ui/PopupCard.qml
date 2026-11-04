import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "Popups.js" as Popups

// A card that pops up from a bar widget: on the side of the bar away from
// the screen's edge, a gap off the widget and centred on it, and never
// nearer the bar's ends than that gap. It is a popup of the bar's window,
// so it hears keys only once the pointer has been in it; KeyboardPanel is
// the one for a panel opened from the keyboard.
//
// The bar shows one popup at a time: opening asks the bar for the place,
// with <owner> (or the card itself) as its key, and closing hands it back.
// A click anywhere but the card and the bar closes it.
PopupWindow {
  id: popup

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property int padding: Style.spacing.popupPadding
  property color borderColor: Commons.Color.popups.border

  default property alias contentItem: card.content

  // The bar's window, which the widget is in, and the screen it is on.
  readonly property var _barWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property var _screen: _barWindow ? _barWindow.screen : null

  // The room for the card along each of the screen's sides: the screen,
  // less the bar where it lies across that side, and a gap at either end.
  function _room(screenLength, barDepth) {
    return Popups.room(screenLength, barDepth + Style.gapsOut, Style.gapsOut)
  }

  // A width for the card, no more than the room for it nor <cap>.
  function fittedContentWidth(width, cap) {
    const across = bar && (bar.position === "left" || bar.position === "right")
    return Popups.cardWidth(width, _room(_screen ? _screen.width : 0, across ? _barWindow?.width ?? 0 : 0), cap)
  }

  // A height for the card round content <implicitHeight> high, no more
  // than the room for it nor <cap>.
  function fittedContentHeight(implicitHeight, cap) {
    const across = bar && (bar.position === "top" || bar.position === "bottom")
    return Popups.cardHeight(implicitHeight, card.verticalInset, _room(_screen ? _screen.height : 0, across ? _barWindow?.height ?? 0 : 0), cap)
  }

  function close() {
    Popups.dismiss(popup)
  }

  // Mapped through the fade out.
  visible: open || card.opacity > 0
  color: "transparent"
  implicitWidth: contentWidth
  implicitHeight: contentHeight

  onOpenChanged: Popups.claim(bar, owner || popup, open)

  // While Hyprland's focus grab holds, input goes to the card and the bar
  // alone; a click anywhere else ends it, and the card closes.
  HyprlandFocusGrab {
    active: popup.open
    windows: popup._barWindow ? [popup, popup._barWindow] : [popup]
    onCleared: popup.close()
  }

  anchor {
    id: placement
    window: popup._barWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    // The card's corner in the bar window's coordinates.
    onAnchoring: {
      const widget = popup.anchorItem
      const host = popup._barWindow
      if (!widget || !popup.bar || !host) return
      const side = popup.bar.position
      const gap = Style.gapsOut
      const size = Qt.size(popup.implicitWidth, popup.implicitHeight)
      if (side === "top" || side === "bottom") {
        const corner = host.contentItem.mapFromItem(widget, widget.width / 2 - size.width / 2,
          side === "bottom" ? -size.height - gap : widget.height + gap)
        placement.rect.x = Math.round(Popups.within(corner.x, size.width, host.width, gap))
        placement.rect.y = Math.round(corner.y)
      } else {
        const corner = host.contentItem.mapFromItem(widget, side === "left" ? widget.width + gap : -size.width - gap,
          widget.height / 2 - size.height / 2)
        placement.rect.x = Math.round(corner.x)
        placement.rect.y = Math.round(Popups.within(corner.y, size.height, host.height, gap))
      }
    }
  }

  PopupFace {
    id: card
    anchors.fill: parent
    padding: popup.padding
    edgeColor: popup.borderColor
    shown: popup.open
  }
}
