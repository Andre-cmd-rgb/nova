import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Popups.js" as Popups

// Where a bar panel opens: a card off its bar widget, <widget>, that works
// from the keyboard as well as the pointer, opened by a click or by a key
// binding (Super+Ctrl+W). <host> is the widget's panel (its bar, its
// <opened>, its close()); the card is open while the host is, unless <open>
// is bound to something else. <wantWidth> and <wantHeight> are what the
// content would like, which the card fits to the screen, the height to
// <tallest> as well when that is set. <centred> puts the card in the middle
// of the bar rather than at the widget. <keys> is the item to have the
// keyboard while the card is open, mostly the PanelKeys round the content:
// the compositor gives the surface the keyboard, and Qt needs an item with
// the focus to hand the keys to.
//
// It is a layer-shell surface over the whole screen with the card on it,
// not a popup of the bar: a popup hears keys only once a click or the pointer
// has led the focus through the bar, so one opened from the keyboard would
// hear none. Each opening takes the keyboard Exclusive for a moment, then
// OnDemand: Exclusive alone would keep the focus, but Hyprland would also
// send this surface every pointer event on every monitor, and a click on
// another monitor could not close the card.
PanelWindow {
  id: surface

  required property Item host
  required property Item widget
  property bool open: host && host.opened === true
  property bool centred: false
  property Item keys: null
  property real wantWidth: Style.space(280)
  property real wantHeight: 0
  property real tallest: 0

  default property alias content: card.content

  readonly property QtObject bar: host ? host.bar : null

  // Where things are, on this screen.
  readonly property var _barWindow: widget ? widget.QsWindow.window : null
  readonly property size _screen: screen ? Qt.size(screen.width, screen.height) : Qt.size(0, 0)
  // The bar's window, along the top of the screen.
  readonly property rect _barRect: Qt.rect(0, 0, _barWindow ? _barWindow.width : _screen.width, _barWindow ? _barWindow.height : 0)
  // How deep a click from the top of the screen still lands on the bar: the
  // bar's own depth, or its window's if deeper, and the gap past it.
  readonly property real _barDepth: bar ? Math.max(bar.thickness, _barRect.height) + Style.gapsOut : 0
  // The widget's place in the bar's window; the watcher sees it move.
  readonly property point _widgetAt: {
    widgetMoves.transform
    return widget && _barWindow ? widget.mapToItem(_barWindow.contentItem, 0, 0) : Qt.point(0, 0)
  }

  readonly property real _cardWidth: Popups.cardWidth(wantWidth, Popups.room(_screen.width, Style.gapsOut, Style.gapsOut))
  readonly property real _cardHeight: Popups.cardHeight(wantHeight, card.verticalInset,
    Popups.room(_screen.height, _barRect.height + Style.gapsOut, Style.gapsOut), tallest)

  // The card's corner. Away from the bar it starts a gap past the bar's
  // window, whatever the widget's own place across the bar (its row's
  // centring is in that). Along the bar it is centred on the widget, or on
  // the screen when <centred>. It keeps a gap from every screen edge.
  readonly property point _cardAt: {
    const gap = Style.gapsOut
    if (!widget || !bar) return Qt.point(gap, gap)
    const w = _cardWidth, h = _cardHeight
    const x = (centred ? _screen.width / 2 : _widgetAt.x + widget.width / 2) - w / 2
    const y = _barRect.bottom + gap
    return Qt.point(Math.round(Popups.within(x, w, _screen.width, gap)), Math.round(Popups.within(y, h, _screen.height, gap)))
  }

  // The keyboard's moment of Exclusive is over.
  property bool _settled: false
  // Opened in another panel's place: for 150 ms the card is there at once,
  // and only its content fades in.
  property bool _takingOver: false
  // Closed for another to open in its place: for a tick it goes at once.
  property bool _handingOver: false

  function close() {
    Popups.dismiss(surface)
  }

  function _onBar(x, y) {
    return y <= _barDepth
  }

  // Hands a click at <x>, <y> to the bar button under it on this panel's
  // bar, the topmost shown one; false when there is none to take it.
  function _clickBar(x, y, button) {
    if (button !== Qt.LeftButton && button !== Qt.RightButton && button !== Qt.MiddleButton) return false
    const win = _barWindow
    if (!win || !win.contentItem || !bar) return false
    const spotX = x - _barRect.x, spotY = y - _barRect.y
    const under = bar.buttons.filter(b => b.click && b.visible !== false && b.opacity !== 0 && b.mapToItem && bar.inWindow(b, win))
      .filter(b => {
        const at = win.itemPosition(b)
        return spotX >= at.x && spotX <= at.x + b.width && spotY >= at.y && spotY <= at.y + b.height
      })
    if (under.length === 0) return false
    under[under.length - 1].click(button)
    return true
  }

  screen: _barWindow ? _barWindow.screen : null
  // Up while open, while the card fades, and while it takes another's place.
  visible: open || card.opacity > 0 || _takingOver
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  anchors { left: true; right: true; top: true; bottom: true }
  mask: Region { width: surface._screen.width; height: surface._screen.height }

  WlrLayershell.namespace: "nova-keyboard-panel"
  WlrLayershell.layer: WlrLayer.Overlay
  // The keyboard goes with <open>, not <visible>: the surface stays up for
  // the fade, but must let go of the keyboard and the pointer the moment the
  // card closes. Exclusive first, then OnDemand: Hyprland hands an OnDemand
  // surface the focus when it maps, not when one still up from its fade asks
  // again, and Exclusive also takes it from an app holding the pointer.
  WlrLayershell.keyboardFocus: !open ? WlrKeyboardFocus.None : _settled ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive

  // The bar has one panel open at a time. The hand-over follows <open>;
  // following <visible>, which lags through the fade, it raced the next one.
  onOpenChanged: {
    if (open && keys) Qt.callLater(() => { if (surface.open && surface.keys) surface.keys.forceActiveFocus() })
    if (!open) _settled = false
    if (!bar) return
    const key = host || surface
    _handingOver = !open && !!host && host.handingOver === true
    _takingOver = open && !!bar.popup && bar.popup !== key
    bar.claimPopup(key, open)
  }

  TransformWatcher {
    id: widgetMoves
    a: surface._barWindow ? surface._barWindow.contentItem : null
    b: surface.widget
  }

  // Exclusive for 75 ms from the surface showing: a few Qt and Wayland
  // commits, too short to notice. Closing and summoning again at once, or
  // summoning while the fade still shows the surface, starts it again.
  Timer {
    interval: 75
    running: surface.open && surface.backingWindowVisible && !surface._settled
    onTriggered: surface._settled = true
  }

  Timer {
    interval: 150
    running: surface._takingOver
    onTriggered: surface._takingOver = false
  }

  Timer {
    interval: 1
    running: surface._handingOver
    onTriggered: surface._handingOver = false
  }

  // A click outside the card: on the bar's strip it is the bar's button's
  // under it, so another panel's icon opens its panel in one click; anywhere
  // else it closes the card. Off through the fade, so that clicks meant for
  // the windows below reach them.
  MouseArea {
    property bool overBar: false

    anchors.fill: parent
    enabled: surface.open
    hoverEnabled: true
    acceptedButtons: Qt.AllButtons
    cursorShape: overBar ? Qt.PointingHandCursor : Qt.ArrowCursor

    onPositionChanged: mouse => overBar = surface._onBar(mouse.x, mouse.y)
    onExited: overBar = false
    // While the keyboard is still Exclusive, Hyprland may send here a click
    // from another monitor, moved over; it is never one on this bar.
    onClicked: mouse => {
      if (!(surface._settled && surface._onBar(mouse.x, mouse.y) && surface._clickBar(mouse.x, mouse.y, mouse.button)))
        surface.close()
    }
  }

  // Clicks on the card are the card's.
  MouseArea {
    anchors.fill: card
    acceptedButtons: Qt.AllButtons
  }

  // The compositor looks for the surface under the pointer on the pointer's
  // own monitor, so a click on another monitor would never reach this one.
  // While the card is open (not through its fade), every other monitor gets
  // a clear surface that closes it on a press. None of them takes the
  // keyboard, or the pointer crossing to its monitor would take it from the
  // card.
  Variants {
    model: surface.open ? Quickshell.screens : []

    PanelWindow {
      required property var modelData

      screen: modelData
      // Told apart by the output's name: before the card's own screen is
      // known, one of these could otherwise cover the card's monitor.
      visible: surface.open && !!surface.screen && modelData.name !== surface.screen.name
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      anchors { left: true; right: true; top: true; bottom: true }
      WlrLayershell.namespace: "nova-panel-elsewhere"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: surface.close()
      }
    }
  }

  PopupFace {
    id: card
    x: surface._cardAt.x
    y: surface._cardAt.y
    width: surface._cardWidth
    height: surface._cardHeight
    shown: surface.open || surface._takingOver
    fades: !surface._takingOver && !surface._handingOver
    contentShown: surface.open || !surface._takingOver
    contentFades: surface._takingOver
  }
}
