import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "Popups.js" as Popups

// A card that pops up from a bar widget, on the side of the bar away from
// the screen's edge and centred on the widget, kept <margin> from the bar's
// ends. It is a popup of the
// bar's window, so it takes keys only once the pointer has been in it;
// KeyboardPanel is the one to use for a panel opened from the keyboard.
//
// The bar shows one popup at a time: opening asks the bar for the place,
// with <owner> (or the card itself) as its key, and closing hands it back.
// A click anywhere outside the card and the bar closes it.
PopupWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property color borderColor: Commons.Color.popups.border
  property var borderSpec: Border.localOrSurfaceSpec("popups", "border", borderColor, Commons.Color.popups.border, Math.max(1, Style.space(2)))
  property bool open: false

  default property alias contentItem: card.content

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string _side: bar ? bar.position : ""
  readonly property var _screen: anchorWindow ? anchorWindow.screen : null

  // The room for the card: the screen, but for the bar across it and
  // <margin> at each end.
  readonly property real availableCardWidth: Popups.room(_screen ? _screen.width : 0,
    (_side === "left" || _side === "right" ? anchorWindow?.width ?? 0 : 0) + margin, margin)
  readonly property real availableCardHeight: Popups.room(_screen ? _screen.height : 0,
    (_side === "top" || _side === "bottom" ? anchorWindow?.height ?? 0 : 0) + margin, margin)
  readonly property real verticalContentInset: padding * 2 + card.borderTop + card.borderBottom

  // A width for the card, no more than the room for it nor <cap>.
  function fittedContentWidth(width, cap) {
    return Popups.cardWidth(width, availableCardWidth, cap)
  }

  // A height for the card round content <implicitHeight> high, no more
  // than the room for it nor <cap>.
  function fittedContentHeight(implicitHeight, cap) {
    return Popups.cardHeight(implicitHeight, verticalContentInset, availableCardHeight, cap)
  }

  function close() {
    Popups.dismiss(root)
  }

  visible: open || card.opacity > 0
  color: "transparent"
  implicitWidth: contentWidth
  implicitHeight: contentHeight

  onOpenChanged: Popups.claim(bar, coordinatorKey, open)

  // Hyprland's focus grab sends the input to the card and the bar alone
  // while it holds; a click anywhere else ends it, and the card closes.
  HyprlandFocusGrab {
    active: root.open
    windows: root.anchorWindow ? [root, root.anchorWindow] : [root]
    onCleared: root.close()
  }

  anchor {
    id: placement
    window: root.anchorWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    // The card's corner, in the bar window's coordinates: <margin> off the
    // widget and centred on it, kept <margin> inside the bar's ends.
    onAnchoring: {
      const widget = root.anchorItem
      const barWindow = root.anchorWindow
      if (!widget || !root.bar || !barWindow) return
      const side = root.bar.position
      const across = side === "top" || side === "bottom"
      const w = root.implicitWidth
      const h = root.implicitHeight
      const m = root.margin
      let spot
      if (across) {
        spot = barWindow.contentItem.mapFromItem(widget, widget.width / 2 - w / 2, side === "bottom" ? -h - m : widget.height + m)
        spot.x = Popups.within(spot.x, w, barWindow.width, m)
      } else {
        spot = barWindow.contentItem.mapFromItem(widget, side === "left" ? widget.width + m : -w - m, widget.height / 2 - h / 2)
        spot.y = Popups.within(spot.y, h, barWindow.height, m)
      }
      placement.rect.x = Math.round(spot.x)
      placement.rect.y = Math.round(spot.y)
    }
  }

  PopupFace {
    id: card
    anchors.fill: parent
    padding: root.padding
    borderSpec: root.borderSpec
    shown: root.open
  }
}
