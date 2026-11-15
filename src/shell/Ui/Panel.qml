import QtQuick
import qs.Commons as Commons

// A bar widget with a panel of its own: audio, network, the clock. It keeps
// whether the panel is <opened>; the plugin brings the button, the card
// (a PanelSurface) and the keys. A plugin with more to do as its panel opens
// or closes writes open() or close() of its own, and sets <opened> in it.
BarWidget {
  id: widget

  property bool opened: false
  // True while the panel closes for another to open in its place, so that
  // its card goes at once rather than fading.
  property bool handingOver: false

  readonly property color textColour: bar ? bar.textColour : Commons.Color.foreground

  function open() { opened = true }
  function close() { opened = false }
  function toggle() { opened ? close() : open() }

  function handOver() {
    handingOver = true
    close()
    Qt.callLater(() => widget.handingOver = false)
  }

  // On to the panel beside this one on the bar, in <direction>.
  function switchPanel(direction) {
    return !!bar && bar.nextPanel(widget, direction)
  }
}
