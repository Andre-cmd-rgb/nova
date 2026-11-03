import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "PopupFit.js" as Fit

// A panel that opens from a bar widget and works from the keyboard as well
// as the pointer, opened by a click or by a key binding (Super+Ctrl+W).
//
// It is a layer-shell surface over the whole screen with the card inside,
// not a popup of the bar: a popup gets keys only once a click or the
// pointer has led the focus through the bar, so a panel opened from the
// keyboard would not hear them. The surface takes the keyboard Exclusive
// for a moment as it opens, then OnDemand. Exclusive alone would also take
// the focus, but Hyprland then sends it every pointer event on every
// monitor, and a click on another monitor could not close the panel.
//
// Its properties are PopupCard's, but for <triggerMode> and
// <containsMouse>: anchorItem, owner, bar, open, padding, margin,
// contentWidth and contentHeight, centerOnBar, and the content.
PanelWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property var borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
  property bool centerOnBar: false
  property bool open: false
  // From the bar's edge to the card.
  property int gap: Style.gapsOut
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: false

  // The item to take the keyboard focus as the panel opens, mostly the
  // PanelKeyCatcher round its content. The surface has the keyboard from
  // the compositor; Qt still needs an item with the focus for Keys to see
  // anything. It is given the focus once the panel has been laid out.
  property Item focusTarget: null

  default property alias contentItem: holder.children

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"

  // The bar's strip, from the screen's edge: the bar, and the gap.
  readonly property real _barStripSize: {
    if (!bar) return 0
    var actual = barPos === "top" || barPos === "bottom" ? barH : barW
    return Math.max(bar.barSize, actual) + gap
  }

  // Where the widget is in the bar's content. The watcher follows every
  // move and resize between the two, which mapToItem by itself would not.
  readonly property point anchorScreenPos: {
    anchorWatcher.transform
    if (!anchorItem || !anchorWindow) return Qt.point(0, 0)
    return anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
  }
  readonly property real anchorW: anchorItem ? anchorItem.width : 0
  readonly property real anchorH: anchorItem ? anchorItem.height : 0
  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  // The room the screen leaves the card, beside the bar and its gap with
  // <margin> on the far side, or <margin> on both; 0 before the screen is
  // known.
  readonly property real availableCardWidth: screenW > 0
    ? Math.max(120, screenW - (barPos === "left" || barPos === "right" ? barW + gap + margin : margin * 2))
    : 0
  readonly property real availableCardHeight: screenH > 0
    ? Math.max(120, screenH - (barPos === "top" || barPos === "bottom" ? barH + gap + margin : margin * 2))
    : 0
  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)
  readonly property real barW: anchorWindow ? anchorWindow.width : screenW
  readonly property real barH: anchorWindow ? anchorWindow.height : 0

  // The card's corner on the screen. Away from the bar it is measured from
  // the bar window's edge, which is the screen's edge plus the bar: the
  // widget's own position across the bar has the bar's inner layout in it
  // (the centring of its row). Along the bar the widget's position is
  // right, and the card is centred on the widget. Either way the card stays
  // <margin> inside the screen.
  readonly property point cardOrigin: {
    if (!anchorItem || !bar) return Qt.point(margin, margin)
    var x = 0
    var y = 0
    var across = barPos === "top" || barPos === "bottom"
    if (centerOnBar && across) {
      x = screenW / 2 - contentWidth / 2
      y = barPos === "bottom" ? screenH - barH - contentHeight - gap : barH + gap
    } else if (centerOnBar) {
      x = barPos === "left" ? barW + gap : screenW - barW - contentWidth - gap
      y = screenH / 2 - contentHeight / 2
    } else if (barPos === "bottom") {
      x = anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = screenH - barH - contentHeight - gap
    } else if (barPos === "left") {
      x = barW + gap
      y = anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else if (barPos === "right") {
      x = screenW - barW - contentWidth - gap
      y = anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else {
      x = anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = barH + gap
    }
    x = Math.max(margin, Math.min(x, screenW - contentWidth - margin))
    y = Math.max(margin, Math.min(y, screenH - contentHeight - margin))
    return Qt.point(Math.round(x), Math.round(y))
  }

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  function beginFocusPrime() {
    if (open && backingWindowVisible) primeTimer.restart()
  }

  // As PopupCard's.
  function fittedContentWidth(width, cap) {
    return Fit.fit(Math.max(1, Number(width) || 1), availableCardWidth, cap)
  }

  function fittedContentHeight(implicitHeight, cap) {
    return Fit.fit(Math.max(verticalContentInset, (Number(implicitHeight) || 0) + verticalContentInset), availableCardHeight, cap)
  }

  function cappedContentHeight(height) {
    return Fit.fit(Math.max(padding * 2, Number(height) || padding * 2), availableCardHeight)
  }

  screen: anchorWindow ? anchorWindow.screen : null
  // Mapped while the card fades out, and while another panel takes its place.
  visible: open || card.opacity > 0 || popoutSwitching
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "nova-keyboard-panel"
  WlrLayershell.layer: WlrLayer.Overlay
  // The keyboard follows <open>, not <visible>: the surface stays mapped for
  // the fade, but must let the keyboard and the pointer go the moment the
  // panel closes, or they would be held for its 140 ms. Each opening takes
  // it Exclusive first, then OnDemand: Hyprland gives OnDemand the focus when
  // a surface maps, not when a surface still mapped from its fade asks
  // again, and Exclusive also takes it from an app that holds the pointer.
  // OnDemand then lets the pointer reach the other monitors' surfaces.
  WlrLayershell.keyboardFocus: !open ? WlrKeyboardFocus.None
    : focusPrimed ? WlrKeyboardFocus.OnDemand
    : WlrKeyboardFocus.Exclusive

  onBackingWindowVisibleChanged: beginFocusPrime()

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  // The whole screen takes clicks: one on the bar's strip is passed to the
  // bar's button under it, any other closes the panel (dismissArea).
  mask: Region {
    width: root.screenW
    height: root.screenH
  }

  TransformWatcher {
    id: anchorWatcher
    a: anchorWindow ? anchorWindow.contentItem : null
    b: anchorItem
  }

  // The bar shows one panel at a time; the hand-over goes with <open>, not
  // <visible>, which lags behind through the fade and made the hand-over to
  // the next panel race. Opening in another's place shows the card at once
  // and fades only its content (popoutSwitching, for 150 ms); closing for
  // another skips the fade (popoutSwitchClosing, for one tick).
  onOpenChanged: {
    if (open) {
      focusPrimed = false
      beginFocusPrime()
      if (focusTarget) {
        Qt.callLater(function() {
          if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
        })
      }
    } else {
      primeTimer.stop()
      focusPrimed = false
    }
    if (!bar) return
    if (open) {
      popoutSwitchClosing = false
      popoutSwitching = bar.activePopout && bar.activePopout !== coordinatorKey
      bar.requestPopout(coordinatorKey)
      if (popoutSwitching) switchTimer.restart()
    } else {
      popoutSwitchClosing = !!(owner && owner.popoutSwitchClosing)
      popoutSwitching = false
      if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
      if (popoutSwitchClosing) closeSwitchTimer.restart()
    }
  }

  // Long enough for a few Qt and Wayland commits after the surface shows,
  // short enough that the Exclusive moment goes unnoticed; a panel closed
  // and summoned again at once is covered by it.
  Timer {
    id: primeTimer
    interval: 75
    onTriggered: {
      if (root.open) root.focusPrimed = true
    }
  }

  Timer {
    id: switchTimer
    interval: 150
    onTriggered: root.popoutSwitching = false
  }

  Timer {
    id: closeSwitchTimer
    interval: 1
    onTriggered: root.popoutSwitchClosing = false
  }

  // A click on the screen outside the card. On the bar's strip it goes to
  // the bar's button under it, so another panel's icon opens that panel in
  // one click; anywhere else it closes this one. Off while the card fades,
  // so the clicks meant for the windows below are theirs.
  MouseArea {
    id: dismissArea

    property bool hoveringBar: false

    function inBarRegion(px, py) {
      switch (root.barPos) {
      case "bottom": return py >= root.screenH - root._barStripSize
      case "left": return px <= root._barStripSize
      case "right": return px >= root.screenW - root._barStripSize
      }
      return py <= root._barStripSize
    }

    // A point on the screen in the bar window's coordinates.
    function barPoint(px, py) {
      if (root.barPos === "bottom") return Qt.point(px, py - (root.screenH - root.barH))
      if (root.barPos === "right") return Qt.point(px - (root.screenW - root.barW), py)
      return Qt.point(px, py)
    }

    // The bar's button at <px>, <py>: the last registered of those shown
    // there, on this panel's bar.
    function pressTargetAt(px, py) {
      if (!root.anchorWindow || !root.anchorWindow.contentItem || !root.bar || !root.bar.clickTargets) return null
      var p = barPoint(px, py)
      var targets = root.bar.clickTargets
      for (var i = targets.length - 1; i >= 0; i--) {
        var target = targets[i]
        if (!target || !target.triggerPress || target.visible === false || target.opacity === 0 || !target.mapToItem) continue
        if (root.bar.targetBelongsToWindow && !root.bar.targetBelongsToWindow(target, root.anchorWindow)) continue
        var at = root.anchorWindow.itemPosition(target)
        if (p.x >= at.x && p.x <= at.x + target.width && p.y >= at.y && p.y <= at.y + target.height) return target
      }
      return null
    }

    function forwardBarClick(px, py, button) {
      if (button !== Qt.LeftButton && button !== Qt.RightButton && button !== Qt.MiddleButton) return false
      var target = pressTargetAt(px, py)
      if (!target) return false
      target.triggerPress(button)
      return true
    }

    anchors.fill: parent
    enabled: root.open
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
    cursorShape: hoveringBar ? Qt.PointingHandCursor : Qt.ArrowCursor

    onPositionChanged: function(mouse) { hoveringBar = inBarRegion(mouse.x, mouse.y) }
    onExited: hoveringBar = false
    // While the keyboard is still Exclusive, Hyprland can send here a click
    // from another monitor, its coordinates moved over; it is never taken as
    // one on this monitor's bar.
    onClicked: function(mouse) {
      if (root.focusPrimed && inBarRegion(mouse.x, mouse.y) && forwardBarClick(mouse.x, mouse.y, mouse.button)) return
      root.close()
    }
  }

  // The surface covers only its own monitor, and the compositor looks for
  // the window under the pointer on the pointer's monitor alone, so a click
  // on another monitor never reaches dismissArea. While the panel is open (not while it
  // fades), every other monitor has a clear surface that closes it on a
  // press. They never take the keyboard, or the pointer crossing onto their
  // monitor would take it from the panel.
  Variants {
    model: root.open ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        // By the output's name: with the panel's own screen not known yet,
        // a twin could otherwise cover the panel's own monitor.
        visible: root.open && !!root.screen && modelData.name !== root.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "nova-keyboard-panel-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }
    }
  }

  BorderSurface {
    id: card
    x: root.cardOrigin.x
    y: root.cardOrigin.y
    width: root.contentWidth
    height: root.contentHeight
    radius: Style.cornerRadius
    padding: root.padding
    color: Commons.Color.popups.background
    borderSpec: root.borderSpec
    opacity: root.open || root.popoutSwitching ? 1.0 : 0

    Behavior on opacity {
      enabled: !root.popoutSwitching && !root.popoutSwitchClosing
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    // A click on the card is not one outside it.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    Item {
      id: holder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      opacity: !root.popoutSwitching || root.open ? 1.0 : 0

      Behavior on opacity {
        enabled: root.popoutSwitching
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }
  }
}
