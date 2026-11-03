import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "Popups.js" as Popups

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
// Its properties are PopupCard's: anchorItem, owner, bar, open, padding,
// margin, contentWidth and contentHeight, centerOnBar, and the content.
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
  // Set while this panel opens in another's place (for 150 ms), and while it
  // closes for another to open (for one tick): the card then shows at once,
  // and only its content fades in.
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  // Whether the opening's Exclusive moment is over.
  property bool focusPrimed: false

  // The item to take the keyboard focus as the panel opens, mostly the
  // PanelKeyCatcher round its content. The surface has the keyboard from
  // the compositor; Qt still needs an item with the focus for Keys to see
  // anything. It is given the focus once the panel has been laid out.
  property Item focusTarget: null

  default property alias contentItem: card.content

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"
  // The bar lies across the screen, along its top or bottom edge.
  readonly property bool _barAcross: barPos === "top" || barPos === "bottom"

  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real barW: anchorWindow ? anchorWindow.width : screenW
  readonly property real barH: anchorWindow ? anchorWindow.height : 0
  // The bar's window on the screen, against the screen's edge.
  readonly property rect _barRect: Qt.rect(barPos === "right" ? screenW - barW : 0, barPos === "bottom" ? screenH - barH : 0, barW, barH)
  // How far from the screen's edge a click still counts as one on the bar:
  // the bar, at least as deep as it is set to be, and the gap.
  readonly property real _barStripSize: bar ? Math.max(bar.barSize, _barAcross ? barH : barW) + gap : 0

  // The widget's corner in the bar's content. The watcher follows every
  // move and resize between the two, which mapToItem by itself would not.
  readonly property point anchorScreenPos: {
    anchorWatcher.transform
    return anchorItem && anchorWindow ? anchorItem.mapToItem(anchorWindow.contentItem, 0, 0) : Qt.point(0, 0)
  }

  // The room for the card: beside the bar and its gap with <margin> on the
  // far side, or <margin> at both ends; 0 before the screen is known.
  readonly property real availableCardWidth: Popups.room(screenW, _barAcross ? margin : barW + gap, margin)
  readonly property real availableCardHeight: Popups.room(screenH, _barAcross ? barH + gap : margin, margin)
  readonly property real verticalContentInset: padding * 2 + card.borderTop + card.borderBottom

  // The card's corner on the screen. Off the bar it is <gap> past the bar's
  // window, not past the widget, whose place across the bar has the bar's
  // inner layout in it (the centring of its row). Along the bar it is
  // centred on the widget, or on the screen with <centerOnBar>. Either way
  // it stays <margin> inside the screen.
  readonly property point cardOrigin: {
    if (!anchorItem || !bar) return Qt.point(margin, margin)
    const w = contentWidth
    const h = contentHeight
    let x
    let y
    if (_barAcross) {
      x = (centerOnBar ? screenW / 2 : anchorScreenPos.x + anchorItem.width / 2) - w / 2
      y = barPos === "bottom" ? _barRect.y - h - gap : _barRect.bottom + gap
    } else {
      x = barPos === "right" ? _barRect.x - w - gap : _barRect.right + gap
      y = (centerOnBar ? screenH / 2 : anchorScreenPos.y + anchorItem.height / 2) - h / 2
    }
    return Qt.point(Math.round(Popups.within(x, w, screenW, margin)), Math.round(Popups.within(y, h, screenH, margin)))
  }

  function close() {
    Popups.dismiss(root)
  }

  // As PopupCard's.
  function fittedContentWidth(width, cap) {
    return Popups.cardWidth(width, availableCardWidth, cap)
  }

  function fittedContentHeight(implicitHeight, cap) {
    return Popups.cardHeight(implicitHeight, verticalContentInset, availableCardHeight, cap)
  }

  // Whether <px>, <py> on the screen lies on the bar's strip.
  function _onBarStrip(px, py) {
    const depth = { bottom: screenH - py, left: px, right: screenW - px }[barPos] ?? py
    return depth <= _barStripSize
  }

  // <px>, <py> on the screen, in the bar window's coordinates.
  function _toBar(px, py) {
    return Qt.point(px - _barRect.x, py - _barRect.y)
  }

  // The bar's button at <spot> in the bar's window: of the shown ones there
  // on this panel's bar, the last registered.
  function _barButtonAt(spot) {
    const window = anchorWindow
    if (!window?.contentItem || !bar?.clickTargets) return null
    const pressable = b => b && b.triggerPress && b.visible !== false && b.opacity !== 0 && b.mapToItem
    const onThisBar = b => !bar.targetBelongsToWindow || bar.targetBelongsToWindow(b, window)
    const under = b => {
      const at = window.itemPosition(b)
      return spot.x >= at.x && spot.x <= at.x + b.width && spot.y >= at.y && spot.y <= at.y + b.height
    }
    return bar.clickTargets.slice().reverse().find(b => pressable(b) && onThisBar(b) && under(b)) ?? null
  }

  // Hands a click at <px>, <py> on the screen to the bar's button there;
  // false when it is not a click a button takes, or no button is there.
  function _passToBar(px, py, button) {
    if (button !== Qt.LeftButton && button !== Qt.RightButton && button !== Qt.MiddleButton) return false
    const target = _barButtonAt(_toBar(px, py))
    target?.triggerPress(button)
    return !!target
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

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  // The whole screen takes clicks: one on the bar's strip is passed to the
  // bar's button under it, any other closes the panel.
  mask: Region {
    width: root.screenW
    height: root.screenH
  }

  TransformWatcher {
    id: anchorWatcher
    a: root.anchorWindow ? root.anchorWindow.contentItem : null
    b: root.anchorItem
  }

  // The bar shows one panel at a time; the hand-over goes with <open>, not
  // <visible>, which lags behind through the fade and made the hand-over to
  // the next panel race.
  onOpenChanged: {
    if (!open) focusPrimed = false
    else if (focusTarget) Qt.callLater(() => { if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus() })
    if (!bar) return
    popoutSwitchClosing = !open && !!owner?.popoutSwitchClosing
    popoutSwitching = open && !!bar.activePopout && bar.activePopout !== coordinatorKey
    Popups.claim(bar, coordinatorKey, open)
  }

  // Exclusive from when the surface shows for 75 ms: long enough for a few
  // Qt and Wayland commits, short enough to go unnoticed. A panel closed and
  // summoned again at once is covered by it, as is one whose surface was
  // still mapped from its fade.
  Timer {
    interval: 75
    running: root.open && root.backingWindowVisible && !root.focusPrimed
    onTriggered: root.focusPrimed = true
  }

  Timer {
    interval: 150
    running: root.popoutSwitching
    onTriggered: root.popoutSwitching = false
  }

  Timer {
    interval: 1
    running: root.popoutSwitchClosing
    onTriggered: root.popoutSwitchClosing = false
  }

  // A click on the screen outside the card. On the bar's strip it goes to
  // the bar's button under it, so another panel's icon opens that panel in
  // one click; anywhere else it closes this one. Off while the card fades,
  // so the clicks meant for the windows below are theirs.
  MouseArea {
    id: outside

    property bool overBar: false

    anchors.fill: parent
    enabled: root.open
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
    cursorShape: overBar ? Qt.PointingHandCursor : Qt.ArrowCursor

    onPositionChanged: mouse => overBar = root._onBarStrip(mouse.x, mouse.y)
    onExited: overBar = false
    // While the keyboard is still Exclusive, Hyprland can send here a click
    // from another monitor, its coordinates moved over; it is never taken as
    // one on this monitor's bar.
    onClicked: mouse => {
      const forBar = root.focusPrimed && root._onBarStrip(mouse.x, mouse.y)
      if (!forBar || !root._passToBar(mouse.x, mouse.y, mouse.button)) root.close()
    }
  }

  // A click on the card is not one outside it.
  MouseArea {
    anchors.fill: card
    acceptedButtons: Qt.AllButtons
  }

  // The surface covers only its own monitor, and the compositor looks for
  // the window under the pointer on the pointer's monitor alone, so a click
  // on another monitor never reaches this one. While the panel is open (not
  // while it fades), every other monitor has a clear surface that closes it
  // on a press. They never take the keyboard, or the pointer crossing onto
  // their monitor would take it from the panel.
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

  PopupFace {
    id: card
    x: root.cardOrigin.x
    y: root.cardOrigin.y
    width: root.contentWidth
    height: root.contentHeight
    padding: root.padding
    borderSpec: root.borderSpec
    shown: root.open || root.popoutSwitching
    fades: !root.popoutSwitching && !root.popoutSwitchClosing
    contentShown: root.open || !root.popoutSwitching
    contentFades: root.popoutSwitching
  }
}
