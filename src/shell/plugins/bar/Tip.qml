import QtQuick

// The bar's one tooltip. A widget asks for it as the pointer comes onto
// the widget; the ask is taken a turn later if the pointer is still there,
// and the tooltip shows once the pointer has stayed 400 ms. It goes when
// the pointer leaves, and with a widget that hides or moves from under the
// pointer, which sends no leave. The bar window the widget is in draws it
// (ScreenBar).
//
// The pointer is on a widget while the widget says so (tooltipHovered).
Item {
  id: tip

  // The widget it is for and its words, once the ask is taken; whether it
  // shows yet.
  property var target: null
  property string text: ""
  property bool shown: false
  // An ask not taken yet, { widget, words }.
  property var asking: null

  visible: false

  function pointerOn(widget) {
    return !!widget && widget.visible !== false && widget.opacity !== 0 && widget.tooltipHovered === true
  }

  function reset() {
    rest.stop()
    asking = null
    target = null
    text = ""
    shown = false
  }

  function ask(widget, words) {
    reset()
    if (!pointerOn(widget) || !words) return
    var request = { widget: widget, words: words }
    asking = request
    Qt.callLater(function() {
      // Another ask, or a leave, came first.
      if (tip.asking !== request) return
      if (!tip.pointerOn(widget)) {
        tip.reset()
        return
      }
      tip.asking = null
      tip.target = widget
      tip.text = words
      rest.restart()
    })
  }

  // The pointer left <widget>: its tooltip goes, shown or asked for.
  function withdraw(widget) {
    var asked = asking ? asking.widget : null
    if (widget === target || widget === asked) reset()
  }

  Timer {
    id: rest
    interval: 400
    onTriggered: {
      if (tip.pointerOn(tip.target)) tip.shown = true
      else tip.reset()
    }
  }

  // A widget that hides or moves away under the pointer sends no leave.
  Timer {
    interval: 100
    running: tip.shown
    repeat: true
    onTriggered: if (!tip.pointerOn(tip.target)) tip.withdraw(tip.target)
  }
}
