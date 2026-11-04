import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Popups.js" as Popups

// A panel that opens from a bar widget and works from the keyboard as well
// as the pointer, opened by a click or by a key binding (Super+Ctrl+W). Its
// card is PopupCard's: <anchorItem>, <owner>, <bar>, <open>,
// <contentWidth> and <contentHeight> as there, and <centerOnBar> to centre
// it on the screen rather than on the widget.
//
// It is a layer-shell surface over its whole screen with the card inside,
// not a popup of the bar: a popup hears keys only once a click or the
// pointer has led the focus through the bar, so a panel opened from the
// keyboard would hear none. The surface takes the keyboard Exclusive for a
// moment as it opens, then OnDemand. Exclusive alone would also take the
// focus, but Hyprland then sends it every pointer event on every monitor,
// and a click on another monitor could not close the panel.
PanelWindow {
  id: panel

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property bool centerOnBar: false

  // The item to take the keyboard focus as the panel opens, mostly the
  // PanelKeyCatcher round its content. The surface has the keyboard from
  // the compositor; Qt still needs an item with the focus for Keys to see
  // anything. It is given the focus once the panel has been laid out.
  property Item focusTarget: null

  default property alias contentItem: card.content

  // The opening's Exclusive moment is over.
  property bool _settled: false
  // This panel opened in another's place: for 150 ms the card shows at once
  // and only its content fades in.
  property bool _takingOver: false
  // This panel closed for another to open in its place: for a tick the card
  // goes at once, unfaded.
  property bool _handingOver: false

  readonly property var _barWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string _side: bar ? bar.position : "top"
  readonly property bool _across: _side === "top" || _side === "bottom"
  readonly property real _screenWidth: screen ? screen.width : 0
  readonly property real _screenHeight: screen ? screen.height : 0
  // The bar's window on the screen, against the screen's edge.
  readonly property rect _barRect: {
    const w = _barWindow ? _barWindow.width : _screenWidth
    const h = _barWindow ? _barWindow.height : 0
    return Qt.rect(_side === "right" ? _screenWidth - w : 0, _side === "bottom" ? _screenHeight - h : 0, w, h)
  }
  // How far in from the screen's edge a click is still one on the bar: as
  // deep as the bar, at least as deep as it is set to be, and the gap.
  readonly property real _barStrip: bar ? Math.max(bar.barSize, _across ? _barRect.height : _barRect.width) + Style.gapsOut : 0

  // The widget's corner in the bar's content. The watcher follows every
  // move and resize between the two, which mapToItem by itself would not.
  readonly property point _widgetAt: {
    widgetMoves.transform
    return anchorItem && _barWindow ? anchorItem.mapToItem(_barWindow.contentItem, 0, 0) : Qt.point(0, 0)
  }

  // The card's corner on the screen. Away from the bar it is a gap past
  // the bar's window, not past the widget, whose place across the bar has
  // the bar's own layout in it (the centring of its row). Along the bar it
  // is centred on the widget, or on the screen with <centerOnBar>. Either
  // way it stays a gap inside the screen.
  readonly property point _cardAt: {
    const gap = Style.gapsOut
    if (!anchorItem || !bar) return Qt.point(gap, gap)
    const w = contentWidth
    const h = contentHeight
    const middle = _across
      ? (centerOnBar ? _screenWidth / 2 : _widgetAt.x + anchorItem.width / 2)
      : (centerOnBar ? _screenHeight / 2 : _widgetAt.y + anchorItem.height / 2)
    const away = _across
      ? (_side === "bottom" ? _barRect.y - h - gap : _barRect.bottom + gap)
      : (_side === "right" ? _barRect.x - w - gap : _barRect.right + gap)
    const x = _across ? middle - w / 2 : away
    const y = _across ? away : middle - h / 2
    return Qt.point(Math.round(Popups.within(x, w, _screenWidth, gap)), Math.round(Popups.within(y, h, _screenHeight, gap)))
  }

  function close() {
    Popups.dismiss(panel)
  }

  // As PopupCard's: the room is the screen less the bar and a gap on its
  // side, and a gap at the far end.
  function fittedContentWidth(width, cap) {
    const near = _across ? Style.gapsOut : _barRect.width + Style.gapsOut
    return Popups.cardWidth(width, Popups.room(_screenWidth, near, Style.gapsOut), cap)
  }

  function fittedContentHeight(implicitHeight, cap) {
    const near = _across ? _barRect.height + Style.gapsOut : Style.gapsOut
    return Popups.cardHeight(implicitHeight, card.verticalInset, Popups.room(_screenHeight, near, Style.gapsOut), cap)
  }

  // Whether <x>, <y> on the screen is on the bar's strip.
  function _onBar(x, y) {
    const inFrom = _side === "bottom" ? _screenHeight - y : _side === "left" ? x : _side === "right" ? _screenWidth - x : y
    return inFrom <= _barStrip
  }

  // Hands a press of <button> at <x>, <y> on the screen to the bar's
  // button there: of the shown ones there on this panel's bar, the one
  // listed last. False when no button takes it.
  function _pressOnBar(x, y, button) {
    if ([Qt.LeftButton, Qt.RightButton, Qt.MiddleButton].indexOf(button) < 0) return false
    const host = _barWindow
    if (!host?.contentItem || !bar?.clickTargets) return false
    const spot = Qt.point(x - _barRect.x, y - _barRect.y)
    const listed = bar.clickTargets
    for (let i = listed.length - 1; i >= 0; i--) {
      const b = listed[i]
      if (!b || !b.triggerPress || b.visible === false || b.opacity === 0 || !b.mapToItem) continue
      if (bar.targetBelongsToWindow && !bar.targetBelongsToWindow(b, host)) continue
      const at = host.itemPosition(b)
      const under = spot.x >= at.x && spot.x <= at.x + b.width && spot.y >= at.y && spot.y <= at.y + b.height
      if (!under) continue
      b.triggerPress(button)
      return true
    }
    return false
  }

  screen: _barWindow ? _barWindow.screen : null
  // Mapped while the card fades out, and while this panel takes another's
  // place.
  visible: open || card.opacity > 0 || _takingOver
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
    : _settled ? WlrKeyboardFocus.OnDemand
    : WlrKeyboardFocus.Exclusive

  anchors {
    top: true
    right: true
    bottom: true
    left: true
  }

  // The whole screen takes clicks: one on the bar's strip is passed to the
  // bar's button under it, any other closes the panel.
  mask: Region {
    width: panel._screenWidth
    height: panel._screenHeight
  }

  // The bar shows one panel at a time; the hand-over goes with <open>, not
  // <visible>, which lags behind through the fade and made the hand-over to
  // the next panel race.
  onOpenChanged: {
    if (!open) _settled = false
    else if (focusTarget) Qt.callLater(() => { if (panel.open && panel.focusTarget) panel.focusTarget.forceActiveFocus() })
    if (!bar) return
    const key = owner || panel
    _handingOver = !open && !!owner?.popoutSwitchClosing
    _takingOver = open && !!bar.activePopout && bar.activePopout !== key
    Popups.claim(bar, key, open)
  }

  TransformWatcher {
    id: widgetMoves
    a: panel._barWindow ? panel._barWindow.contentItem : null
    b: panel.anchorItem
  }

  // Exclusive from when the surface shows, for 75 ms: long enough for a few
  // Qt and Wayland commits, short enough to go unnoticed. A panel closed and
  // summoned again at once is covered by it, as is one whose surface was
  // still mapped from its fade.
  Timer {
    interval: 75
    running: panel.open && panel.backingWindowVisible && !panel._settled
    onTriggered: panel._settled = true
  }

  Timer {
    interval: 150
    running: panel._takingOver
    onTriggered: panel._takingOver = false
  }

  Timer {
    interval: 1
    running: panel._handingOver
    onTriggered: panel._handingOver = false
  }

  // A click on the screen outside the card. On the bar's strip it goes to
  // the bar's button under it, so another panel's icon opens that panel in
  // one click; anywhere else it closes this one. Off while the card fades,
  // so the clicks meant for the windows below are theirs.
  MouseArea {
    property bool overBar: false

    anchors.fill: parent
    enabled: panel.open
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
    cursorShape: overBar ? Qt.PointingHandCursor : Qt.ArrowCursor

    onPositionChanged: mouse => overBar = panel._onBar(mouse.x, mouse.y)
    onExited: overBar = false
    // While the keyboard is still Exclusive, Hyprland can send here a click
    // from another monitor, its coordinates moved over; it is never taken as
    // one on this monitor's bar.
    onClicked: mouse => {
      const forBar = panel._settled && panel._onBar(mouse.x, mouse.y)
      if (!forBar || !panel._pressOnBar(mouse.x, mouse.y, mouse.button)) panel.close()
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
  // while it fades), each other monitor has a clear surface that closes it
  // on a press. They never take the keyboard, or the pointer crossing onto
  // their monitor would take it from the panel.
  Variants {
    model: panel.open ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        // By the output's name: with the panel's own screen not known yet,
        // a twin could otherwise cover the panel's own monitor.
        visible: panel.open && !!panel.screen && modelData.name !== panel.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "nova-keyboard-panel-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          right: true
          bottom: true
          left: true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: panel.close()
        }
      }
    }
  }

  PopupFace {
    id: card
    x: panel._cardAt.x
    y: panel._cardAt.y
    width: panel.contentWidth
    height: panel.contentHeight
    shown: panel.open || panel._takingOver
    fades: !panel._takingOver && !panel._handingOver
    contentShown: panel.open || !panel._takingOver
    contentFades: panel._takingOver
  }
}
