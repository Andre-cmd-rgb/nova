import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "PopupFit.js" as Fit

// A card that pops up from a bar widget, on the side of the bar away from
// the screen's edge and centred on the widget, or on the bar with
// <centerOnBar>, kept <margin> from the bar's ends. It is a popup of the
// bar's window, so it takes keys only once the pointer has been in it;
// KeyboardPanel is the one to use for a panel opened from the keyboard.
//
// The bar shows one popup at a time: opening asks the bar for the place,
// with <owner> (or the card itself) as its key, and closing hands it back.
// With <triggerMode> "click", a click anywhere outside the card and the bar
// closes it; with "hover", the widget opens and closes it as the pointer
// comes and goes, and the pointer can cross between the two.
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
  property bool centerOnBar: false
  property string triggerMode: "click"

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property var popupScreen: anchorWindow ? anchorWindow.screen : null
  readonly property bool containsMouse: cardHover.hovered
  readonly property real screenW: popupScreen ? popupScreen.width : 0
  readonly property real screenH: popupScreen ? popupScreen.height : 0
  readonly property real barW: anchorWindow ? anchorWindow.width : 0
  readonly property real barH: anchorWindow ? anchorWindow.height : 0
  // The room the screen leaves the card beside the bar, <margin> kept on
  // both sides; 0 before the screen is known.
  readonly property real availableCardWidth: screenW > 0
    ? Math.max(120, screenW - (bar && (bar.position === "left" || bar.position === "right") ? barW : 0) - margin * 2)
    : 0
  readonly property real availableCardHeight: screenH > 0
    ? Math.max(120, screenH - (bar && (bar.position === "top" || bar.position === "bottom") ? barH : 0) - margin * 2)
    : 0
  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

  default property alias contentItem: holder.children

  // A width for the card, no more than the room for it nor <cap>.
  function fittedContentWidth(width, cap) {
    return Fit.fit(Math.max(1, Number(width) || 1), availableCardWidth, cap)
  }

  // A height for the card round content <implicitHeight> high, no more
  // than the room for it nor <cap>.
  function fittedContentHeight(implicitHeight, cap) {
    return Fit.fit(Math.max(verticalContentInset, (Number(implicitHeight) || 0) + verticalContentInset), availableCardHeight, cap)
  }

  // <height>, at least the padding, no more than the room for it.
  function cappedContentHeight(height) {
    return Fit.fit(Math.max(padding * 2, Number(height) || padding * 2), availableCardHeight)
  }

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  visible: open || card.opacity > 0
  color: "transparent"
  implicitWidth: contentWidth
  implicitHeight: contentHeight

  onOpenChanged: {
    if (!bar) return
    if (open) bar.requestPopout(coordinatorKey)
    else if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
  }

  // Hyprland's focus grab sends the input to the card and the bar alone
  // while it holds; a click anywhere else ends it, and the card closes.
  HyprlandFocusGrab {
    active: root.open && root.triggerMode === "click"
    windows: root.anchorWindow ? [root, root.anchorWindow] : [root]
    onCleared: root.close()
  }

  anchor {
    id: placement
    window: anchorItem ? anchorItem.QsWindow.window : null
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    // The card's corner, in the bar window's coordinates.
    onAnchoring: {
      if (!root.anchorItem || !root.bar) return

      var target = root.anchorItem
      var side = root.bar.position
      var width = root.implicitWidth
      var height = root.implicitHeight
      var margin = root.margin

      // Beside the widget, away from the bar's edge: under it by default.
      var x = target.width / 2 - width / 2
      var y = target.height + margin
      if (side === "bottom") {
        y = -height - margin
      } else if (side === "left") {
        x = target.width + margin
        y = target.height / 2 - height / 2
      } else if (side === "right") {
        x = -width - margin
        y = target.height / 2 - height / 2
      }

      var window = target.QsWindow.window
      if (!window) return
      var across = side === "top" || side === "bottom"

      if (root.centerOnBar) {
        if (across) {
          x = Math.max(margin, Math.min(window.width / 2 - width / 2, window.width - width - margin))
          y = side === "bottom" ? -height - margin : window.height + margin
        } else {
          x = side === "left" ? window.width + margin : -width - margin
          y = Math.max(margin, Math.min(window.height / 2 - height / 2, window.height - height - margin))
        }
        placement.rect.x = Math.round(x)
        placement.rect.y = Math.round(y)
        return
      }

      // Along the bar, the card stays <margin> inside its ends.
      var point = window.contentItem.mapFromItem(target, x, y)
      if (across) point.x = Math.max(margin, Math.min(point.x, window.width - width - margin))
      else point.y = Math.max(margin, Math.min(point.y, window.height - height - margin))
      placement.rect.x = Math.round(point.x)
      placement.rect.y = Math.round(point.y)
    }
  }

  BorderSurface {
    id: card
    anchors.fill: parent
    radius: Style.cornerRadius
    padding: root.padding
    color: Commons.Color.popups.background
    borderSpec: root.borderSpec
    opacity: root.open ? 1.0 : 0

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Item {
      id: holder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
    }

    HoverHandler {
      id: cardHover
    }
  }
}
